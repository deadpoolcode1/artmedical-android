#!/bin/bash
# =============================================================================
# build-sdcard-recovery.sh
# Produce an Art-Medical Android recovery SD-card image (.wic.zst) by taking
# Variscite's prebuilt Yocto recovery image and swapping in the Android
# partition images from this tree's most recent build.
#
# Flow:
#   1. Ensure base recovery image is present (download from Variscite CDN if not).
#   2. Decompress the base .wic.zst -> working .wic.
#   3. Loop-mount the rootfs partition.
#   4. Copy fresh .img/.bin files from out/target/product/dart_mx8mp/ into
#      /opt/images/Android/ and /opt/images/Android/lwb/ on the card.
#   5. Unmount, recompress with zstd, emit the final .wic.zst.
#
# Target board: VAR-SOM-MX8M-PLUS V1.x on Symphony-Board (default).
# Other variants can be produced by passing --variant, but note that the
# install_android.sh on the rescue card routes all V1.x SoMs to the
# /opt/images/Android/lwb/ subdirectory, so we always populate it too.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# sdcard/ lives two levels deep inside android_build/artmedical-android/sdcard/
ANDROID_BUILD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR_DEFAULT="$ANDROID_BUILD_DIR/out/target/product/dart_mx8mp"
BASE_DIR_DEFAULT="$SCRIPT_DIR/base"
BASE_URL="https://variscite-public.nyc3.cdn.digitaloceanspaces.com/DART-MX8M-PLUS/Software/mx8mp__yocto-scarthgap-6.6.52_2.2.0-v1.1__android-14.0.0_1.0.0-v1.1.wic.zst"
BASE_FILENAME="recovery.wic.zst"
MOUNT_DIRS=("/opt/images/Android" "/opt/images/Android/lwb")

# Defaults (overridable via flags/env)
VARIANT="${VARIANT:-imx8mp-var-som-1.x-symphony}"
OUT_DIR="${OUT_DIR:-$OUT_DIR_DEFAULT}"
BASE_DIR="${BASE_DIR:-$BASE_DIR_DEFAULT}"
OUTPUT=""
KEEP_WORKING=false
DO_DOWNLOAD=true

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# do_sudo: use SUDO_ASKPASS + -A when present (non-interactive contexts),
# otherwise fall back to plain sudo (prompts on tty as usual).
do_sudo() {
    if [ -n "${SUDO_ASKPASS:-}" ]; then
        sudo -A "$@"
    else
        sudo "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
    --variant <name>        Target SoM variant (default: $VARIANT)
                            e.g. imx8mp-var-som-1.x-symphony
                                 imx8mp-var-dart-1.x-dt8mcustomboard
    --output <path>         Output .wic.zst path
                            (default: $SCRIPT_DIR/artmedical-sdcard-<date>.wic.zst)
    --out-dir <path>        Android build output dir
                            (default: $OUT_DIR_DEFAULT)
    --base-dir <path>       Base image cache dir
                            (default: $BASE_DIR_DEFAULT)
    --no-download           Fail if base image is missing instead of downloading.
    --keep-working          Keep the intermediate decompressed .wic for debugging.
    -h, --help              Show this help.

Environment:
    VARIANT, OUT_DIR, BASE_DIR can also be set via environment variables.
    SUDO_ASKPASS can be set to a helper script for non-interactive sudo.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variant)        VARIANT="$2"; shift 2 ;;
            --output)         OUTPUT="$2"; shift 2 ;;
            --out-dir)        OUT_DIR="$2"; shift 2 ;;
            --base-dir)       BASE_DIR="$2"; shift 2 ;;
            --no-download)    DO_DOWNLOAD=false; shift ;;
            --keep-working)   KEEP_WORKING=true; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)                log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
    if [ -z "$OUTPUT" ]; then
        OUTPUT="$SCRIPT_DIR/artmedical-sdcard-$(date +%Y%m%d).wic.zst"
    fi
}

require_tools() {
    local missing=()
    for t in zstd losetup sfdisk mount umount curl; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing tools: ${missing[*]}"
        log_error "Install with: sudo apt install -y zstd util-linux coreutils curl"
        exit 1
    fi
}

require_build_output() {
    if [ ! -d "$OUT_DIR" ]; then
        log_error "Build output not found: $OUT_DIR"
        log_error "Run ./modular-tools.sh build first."
        exit 1
    fi
    for must in boot.img init_boot.img super.img vendor_boot.img \
                bootloader-imx8mp-var-dart-dual.img spl-imx8mp-var-dart-dual.bin \
                "dtbo-${VARIANT}.img" "vbmeta-${VARIANT}.img"; do
        if [ ! -f "$OUT_DIR/$must" ]; then
            log_error "Missing required build artifact: $OUT_DIR/$must"
            exit 1
        fi
    done
}

ensure_base_image() {
    local base_zst="$BASE_DIR/$BASE_FILENAME"
    if [ -f "$base_zst" ]; then
        log_ok "Base recovery image present: $base_zst ($(stat -c%s "$base_zst" | numfmt --to=iec))"
        return
    fi
    if ! $DO_DOWNLOAD; then
        log_error "Base image missing and --no-download was passed."
        log_error "Expected: $base_zst"
        exit 1
    fi
    log_info "Base image not cached; downloading from Variscite CDN..."
    log_info "URL: $BASE_URL"
    mkdir -p "$BASE_DIR"
    curl -fSL --retry 3 -C - -o "$base_zst" "$BASE_URL"
    log_ok "Downloaded: $(stat -c%s "$base_zst" | numfmt --to=iec)"
}

decompress_base() {
    local base_zst="$BASE_DIR/$BASE_FILENAME"
    local work_wic="$BASE_DIR/working.wic"
    log_info "Decompressing base image -> $work_wic"
    zstd -dqf "$base_zst" -o "$work_wic"
    log_ok "Working image: $(stat -c%s "$work_wic" | numfmt --to=iec)"
    echo "$work_wic"
}

get_rootfs_offset() {
    # Returns "offset sizelimit" (in bytes) of the single ext rootfs partition.
    local wic="$1"
    do_sudo sfdisk -J "$wic" | python3 -c "
import json, sys
d = json.load(sys.stdin)['partitiontable']
ss = d.get('sectorsize', 512)
p = max(d['partitions'], key=lambda p: p['size'])
print(p['start']*ss, p['size']*ss)
"
}

mount_rootfs() {
    local wic="$1"; local mnt="$2"
    read -r offset sizelimit < <(get_rootfs_offset "$wic")
    log_info "Mounting rootfs (offset=$offset size=$sizelimit) at $mnt"
    do_sudo mkdir -p "$mnt"
    do_sudo mount -o "loop,offset=$offset,sizelimit=$sizelimit" "$wic" "$mnt"
}

unmount_rootfs() {
    local mnt="$1"
    if mountpoint -q "$mnt"; then
        do_sudo umount "$mnt"
        log_ok "Unmounted $mnt"
    fi
    do_sudo rmdir "$mnt" 2>/dev/null || true
}

replace_images() {
    local mnt="$1"

    local primary_dir="$mnt/opt/images/Android"
    if [ ! -d "$primary_dir" ]; then
        log_error "Unexpected layout: $primary_dir does not exist on the card."
        exit 1
    fi

    local copied=0 skipped=0
    shopt -s nullglob
    for src in "$OUT_DIR"/*.img "$OUT_DIR"/*.bin; do
        local name
        name="$(basename "$src")"
        # Only refresh files the card already knows about (keeps layout sane,
        # avoids copying irrelevant artifacts like partition-table-*.img).
        if [ ! -f "$primary_dir/$name" ]; then
            skipped=$((skipped+1))
            continue
        fi
        for dst_subdir in "${MOUNT_DIRS[@]}"; do
            local dst_dir="$mnt$dst_subdir"
            if [ -d "$dst_dir" ] && [ -f "$dst_dir/$name" ]; then
                do_sudo cp -f "$src" "$dst_dir/$name"
            fi
        done
        copied=$((copied+1))
    done
    shopt -u nullglob

    log_ok "Copied $copied image(s) into ${MOUNT_DIRS[*]} (skipped $skipped not-on-card)"

    local variant_files=(
        "boot.img" "init_boot.img" "vendor_boot.img" "super.img"
        "bootloader-imx8mp-var-dart-dual.img" "spl-imx8mp-var-dart-dual.bin"
        "dtbo-${VARIANT}.img" "vbmeta-${VARIANT}.img"
    )
    local img_root="/opt/images/Android/lwb"
    for f in "${variant_files[@]}"; do
        if [ ! -f "$mnt$img_root/$f" ]; then
            log_warn "Expected on card but missing: $img_root/$f"
        fi
    done
    log_ok "Variant $VARIANT will install from $img_root/"
}

compress_output() {
    local wic="$1"; local out="$2"
    log_info "Compressing $wic -> $out (zstd -19, this takes a while)"
    zstd -T0 -19 -qf "$wic" -o "$out"
    log_ok "Final image: $out ($(stat -c%s "$out" | numfmt --to=iec))"
}

main() {
    parse_args "$@"
    require_tools
    require_build_output
    ensure_base_image

    local work_wic
    work_wic="$(decompress_base)"
    local mnt="/tmp/artmedical-sdcard-mount-$$"

    # shellcheck disable=SC2064
    trap "unmount_rootfs '$mnt' || true" EXIT
    mount_rootfs "$work_wic" "$mnt"

    replace_images "$mnt"

    unmount_rootfs "$mnt"
    trap - EXIT

    compress_output "$work_wic" "$OUTPUT"

    if ! $KEEP_WORKING; then
        rm -f "$work_wic"
    fi

    log_ok "Done. Ship $OUTPUT to the client."
    log_info "Client flashing procedure:"
    log_info "  zstd -d $(basename "$OUTPUT") -o artmedical-sdcard.wic"
    log_info "  sudo dd if=artmedical-sdcard.wic of=/dev/sdX bs=1M status=progress conv=fsync"
    log_info "Boot mode = SD card, power on, wait for install_android.sh to finish, power off, switch boot mode to eMMC."
}

main "$@"
