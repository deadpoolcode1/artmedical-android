#!/bin/bash
set -e

# =============================================================================
# Art-Medical Android 14 Build Tools (git-based)
# VAR-SOM-MX8M-PLUS V1.x on Symphony-Board with BCM WiFi
#
# The "art-medical" customization now lives as committed git revisions in
# each subrepo (device/variscite, vendor/variscite/kernel_imx, etc.) — not as
# a file-based patch series. This script reports git state truthfully and
# builds whatever is currently checked out. patches/ is kept only for
# customizations not yet committed (e.g. system/core cdc-wdm0).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_BUILD_DIR="$SCRIPT_DIR"
OUT="$ANDROID_BUILD_DIR/out/target/product/dart_mx8mp"
PATCHES_DIR="$SCRIPT_DIR/patches"
UUU_DIR="$SCRIPT_DIR/uuu"
APPLIED_FILE="$ANDROID_BUILD_DIR/.artmedical_applied"   # file-based patches we actively applied

# Remote deployment target (Tailscale). Override via env vars if needed.
REMOTE_DEPLOY_HOST="${REMOTE_DEPLOY_HOST:-100.92.195.81}"
REMOTE_DEPLOY_USER="${REMOTE_DEPLOY_USER:-tomer-password-is-1234}"
REMOTE_DEPLOY_DIR="${REMOTE_DEPLOY_DIR:-~/image}"

# Art-medical "fingerprint" commits per subrepo. status() checks each
# subrepo's recent git log for these subject keywords to confirm the tree
# carries the art-med customization. Add new fingerprint patterns here as
# new commits land.
#
# Format: <relative subrepo path>|<egrep alternation of subject keywords>
ARTMED_FINGERPRINTS=(
  "system/core|cdc-wdm0|Quectel"
  "device/variscite|Quectel EG25|UART device permissions|force AOT dexopt|FTDI FT232R|Symphony as default dtbo"
  "vendor/variscite/kernel_imx|disable unnecessary hardware|Disable NXP FEC|Keep all drivers for modem|modem-setup"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Setup
# =============================================================================

setup() {
    log_info "Installing required packages for Android 14 build..."
    sudo apt-get update
    sudo apt-get -y install gnupg flex bison gperf build-essential zip gcc-multilib g++-multilib
    sudo apt-get -y install libc6-dev-i386 lib32ncurses5-dev libncurses5-dev x11proto-core-dev libx11-dev lib32z-dev libz-dev libssl-dev
    sudo apt-get -y install ccache libgl1-mesa-dev libxml2-utils xsltproc unzip bc
    sudo apt-get -y install uuid uuid-dev zlib1g-dev liblz-dev liblzo2-2 liblzo2-dev lzop git curl lib32ncurses5-dev
    sudo apt-get -y install u-boot-tools mtd-utils device-tree-compiler gdisk m4 dwarves libgnutls28-dev
    sudo apt-get -y install libelf-dev cpio lz4
    sudo apt-get -y install swig libdw-dev ninja-build clang liblz4-tool libncurses5 make tar rsync
    sudo apt-get -y install android-sdk-libsparse-utils
    sudo apt-get -y install android-tools-adb android-tools-fastboot

    if [ ! -d "/usr/lib/jvm/temurin-8-jdk-amd64" ]; then
        log_info "Installing Adoptium Temurin JDK 8..."
        wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | sudo gpg --dearmor -o /usr/share/keyrings/adoptium.gpg 2>/dev/null || true
        echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/adoptium.list
        sudo apt-get update
        sudo apt-get -y install temurin-8-jdk
    fi

    sudo bash -c 'cat > /etc/udev/rules.d/51-android.rules << EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="1fc9", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="15a2", MODE="0666", GROUP="plugdev"
EOF'
    sudo udevadm control --reload-rules && sudo udevadm trigger
    log_ok "Setup complete!"
}

# =============================================================================
# Status — git-aware
# =============================================================================

_check_subrepo() {
    local subrepo="$1"
    local fingerprint="$2"
    local tree="$ANDROID_BUILD_DIR/$subrepo"

    if [ ! -d "$tree" ]; then
        printf "  %b[--]%b %-32s missing\n" "$YELLOW" "$NC" "$subrepo"
        return
    fi
    if [ ! -d "$tree/.git" ] && [ ! -f "$tree/.git" ]; then
        printf "  %b[--]%b %-32s not a git repo\n" "$YELLOW" "$NC" "$subrepo"
        return
    fi

    local head_short
    head_short=$(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo "?")
    local matching
    matching=$(git -C "$tree" log --oneline -50 2>/dev/null | grep -ciE "$fingerprint" || true)
    local dirty
    dirty=$(git -C "$tree" status --porcelain 2>/dev/null | wc -l)

    if [ "$matching" -gt 0 ]; then
        printf "  %b[OK]%b %-32s @ %s — %d art-med commit(s) in last 50\n" \
            "$GREEN" "$NC" "$subrepo" "$head_short" "$matching"
        # Show the matching commits
        git -C "$tree" log --oneline -50 2>/dev/null | grep -iE "$fingerprint" | sed 's/^/         /'
    else
        printf "  %b[--]%b %-32s @ %s — no art-med fingerprint commits found\n" \
            "$YELLOW" "$NC" "$subrepo" "$head_short"
    fi

    if [ "$dirty" -gt 0 ]; then
        printf "       %buncommitted: %d file(s)%b\n" "$YELLOW" "$dirty" "$NC"
        git -C "$tree" status --porcelain 2>/dev/null | sed 's/^/         /' | head -5
    fi
}

status() {
    echo ""
    echo "=========================================="
    echo "Art-Medical Android Build Status (git)"
    echo "=========================================="
    echo ""
    log_ok "Android source: $ANDROID_BUILD_DIR"
    echo ""
    echo "Subrepo customization fingerprints:"
    for entry in "${ARTMED_FINGERPRINTS[@]}"; do
        local subrepo="${entry%%|*}"
        local fp="${entry#*|}"
        _check_subrepo "$subrepo" "$fp"
    done

    # Patches/ leftovers
    if [ -d "$PATCHES_DIR" ]; then
        local pending
        pending=$(find "$PATCHES_DIR" -name "*.patch" 2>/dev/null | wc -l)
        if [ "$pending" -gt 0 ]; then
            echo ""
            echo "Leftover patch files in patches/ (file-based, not git-committed):"
            find "$PATCHES_DIR" -name "*.patch" 2>/dev/null | sed "s|$PATCHES_DIR/|  |"
            if [ -s "$APPLIED_FILE" ]; then
                echo ""
                echo "Currently applied via 'patch' command:"
                sed 's/^/  /' "$APPLIED_FILE"
            fi
        fi
    fi

    # Build output snapshot
    if [ -d "$OUT" ]; then
        echo ""
        echo "Build output: $OUT"
        local images=(
            "u-boot-imx8mp-var-dart-uuu.imx"
            "spl-imx8mp-var-dart-dual.bin"
            "bootloader-imx8mp-var-dart-dual.img"
            "partition-table-dual.img"
            "boot.img" "vendor_boot.img" "init_boot.img"
            "dtbo-imx8mp-var-som-1.x-symphony.img"
            "vbmeta-imx8mp-var-som-1.x-symphony.img"
            "super.img"
        )
        for img in "${images[@]}"; do
            if [ -f "$OUT/$img" ]; then
                printf "  %-50s %s  %s\n" \
                    "$img" \
                    "$(stat -c %s "$OUT/$img" | numfmt --to=iec)" \
                    "$(stat -c %y "$OUT/$img" | cut -d. -f1)"
            fi
        done
    fi
    echo ""
}

# =============================================================================
# Patch / unpatch — only for leftover file-based patches in patches/.
# Commits already in git are ignored (treated as the source-of-truth).
# =============================================================================

patch() {
    if [ ! -d "$PATCHES_DIR" ]; then
        log_info "No patches/ directory; nothing to apply. (git-based customization in subrepos already.)"
        return 0
    fi

    log_info "Applying any patch files in $PATCHES_DIR that aren't already in tree..."
    : > "$APPLIED_FILE"
    local applied=0 skipped=0 failed=0

    # Apply in deterministic alphabetical order.
    while IFS= read -r -d '' p; do
        local relpath="${p#$PATCHES_DIR/}"
        local target_dir="$ANDROID_BUILD_DIR/$(dirname "$relpath")"
        if [ ! -d "$target_dir" ]; then
            log_warn "Target dir missing: $(dirname "$relpath") — skipping $(basename "$p")"
            failed=$((failed+1))
            continue
        fi
        if git -C "$target_dir" apply --check "$p" 2>/dev/null; then
            git -C "$target_dir" apply "$p"
            echo "$relpath" >> "$APPLIED_FILE"
            log_ok "Applied: $(basename "$p") → $(dirname "$relpath")"
            applied=$((applied+1))
        else
            log_info "Skipped (already in tree or conflicts): $(basename "$p") → $(dirname "$relpath")"
            skipped=$((skipped+1))
        fi
    done < <(find "$PATCHES_DIR" -name "*.patch" -print0 2>/dev/null | sort -z)

    log_ok "Patch summary: applied=$applied skipped=$skipped failed=$failed"
}

unpatch() {
    if [ ! -s "$APPLIED_FILE" ]; then
        log_info "No file-based patches recorded as applied. (Committed git revisions are not reverted.)"
        return 0
    fi
    log_info "Reverting file-based patches from $APPLIED_FILE ..."
    tac "$APPLIED_FILE" | while IFS= read -r relpath; do
        local target_dir="$ANDROID_BUILD_DIR/$(dirname "$relpath")"
        local patch_file="$PATCHES_DIR/$relpath"
        [ -d "$target_dir" ] || continue
        [ -f "$patch_file" ] || continue
        if git -C "$target_dir" apply -R --check "$patch_file" 2>/dev/null; then
            git -C "$target_dir" apply -R "$patch_file"
            log_ok "Reverted: $relpath"
        else
            log_warn "Cannot revert (manual check needed): $relpath"
        fi
    done
    rm -f "$APPLIED_FILE"
}

# =============================================================================
# Build
# =============================================================================

build_env() {
    cd "$ANDROID_BUILD_DIR" || { log_error "Cannot cd to $ANDROID_BUILD_DIR"; return 1; }
    export PATH=/usr/lib/jvm/temurin-8-jdk-amd64/bin:$PATH
    source build/envsetup.sh
    lunch dart_mx8mp-userdebug
}

build() {
    # Auto-apply any leftover file-based patches first (no-op if they're
    # already in tree, since git apply --check will fail and we'll skip).
    patch || true

    log_info "Starting full build (whatever's checked out in git)..."
    build_env || return 1
    local log
    log="build-$(date +%Y%m%d-%H%M).log"
    TARGET_USES_BCM_WIFI=true ./imx-make.sh -j"$(nproc)" 2>&1 | tee "$log"
    log_ok "Build complete! Output: $OUT  Log: $log"
}

build_bootimage() {
    patch || true
    log_info "Building boot.img only..."
    build_env || return 1
    TARGET_USES_BCM_WIFI=true make bootimage -j"$(nproc)"
    log_ok "boot.img build complete!"
}

build_ota() {
    patch || true
    log_info "Building OTA package..."
    build_env || return 1
    local log
    log="build-ota-$(date +%Y%m%d-%H%M).log"
    TARGET_USES_BCM_WIFI=true ./imx-make.sh bootloader kernel -j"$(nproc)"
    TARGET_USES_BCM_WIFI=true make otapackage -j"$(nproc)" 2>&1 | tee "$log"
    log_ok "OTA build complete! Log: $log"
}

# =============================================================================
# Local flash (board attached to THIS PC, via UUU)
# =============================================================================

flash() {
    if [ ! -d "$OUT" ]; then
        log_error "Build output not found at $OUT. Build first."
        return 1
    fi
    if [ -d "$UUU_DIR" ]; then
        log_info "Preparing flash files..."
        cp "$UUU_DIR/emmc_burn_android_imx8mp_var_som_1_x_symphony.lst" "$OUT/" 2>/dev/null || true
        cp "$UUU_DIR/uuu" "$OUT/" 2>/dev/null && chmod +x "$OUT/uuu" || true
    fi
    cd "$OUT"
    echo ""
    echo "Before continuing:"
    echo "  1. Boot switches set to USB serial download (NOT eMMC/SD)"
    echo "  2. NO SD card inserted"
    echo "  3. USB OTG cable connected, board powered on (1fc9:0146 in lsusb)"
    echo ""
    if lsusb | grep -qi "1fc9:0146"; then
        log_ok "ROM SDP device detected (1fc9:0146)"
    elif lsusb | grep -qi "1fc9:0152"; then
        log_warn "Device is in u-boot fastboot (1fc9:0152), not ROM SDP."
        log_warn "uuu will skip SDP* stages and 'FB: ucmd' may fail if the resident u-boot lacks UUU support."
        log_warn "Consider 'deploy_remote' + flash via fastboot mode instead, or reset boot switches to SDP."
    else
        log_warn "No NXP device detected. Check USB and boot mode."
    fi
    read -r -p "Continue with UUU flash? (yes/no): " confirm
    [ "$confirm" = "yes" ] || { log_info "Cancelled."; return 0; }
    log_info "Starting UUU flash..."
    if [ -x "./uuu" ]; then
        sudo ./uuu emmc_burn_android_imx8mp_var_som_1_x_symphony.lst
    else
        sudo uuu emmc_burn_android_imx8mp_var_som_1_x_symphony.lst
    fi
    log_ok "Flash complete!"
}

# =============================================================================
# Remote deploy (push images + uuu to a remote PC over Tailscale, optionally
# flash from there). The remote-side flash-here.sh now auto-detects whether
# the board is in SDP (uuu) or already in fastboot (fastboot) mode.
# =============================================================================

deploy_remote() {
    if [ ! -d "$OUT" ]; then
        log_error "Build output not found at $OUT. Build first."
        return 1
    fi
    if [ ! -d "$UUU_DIR" ]; then
        log_error "UUU directory not found: $UUU_DIR"
        return 1
    fi

    local lst="emmc_burn_android_imx8mp_var_som_1_x_symphony.lst"
    local staging
    staging="$(mktemp -d)"
    trap "rm -rf '$staging'" RETURN

    log_info "Staging flash payload in $staging ..."

    local files=(
        "u-boot-imx8mp-var-dart-uuu.imx"
        "spl-imx8mp-var-dart-dual.bin"
        "partition-table-dual.img"
        "bootloader-imx8mp-var-dart-dual.img"
        "dtbo-imx8mp-var-som-1.x-symphony.img"
        "boot.img"
        "vendor_boot.img"
        "init_boot.img"
        "vbmeta-imx8mp-var-som-1.x-symphony.img"
        "super.img"
    )

    local missing=0
    for f in "${files[@]}"; do
        if [ ! -f "$OUT/$f" ]; then
            log_warn "Missing image: $OUT/$f"
            missing=$((missing+1))
        fi
    done
    if [ "$missing" -gt 0 ]; then
        log_error "$missing image(s) missing — aborting."
        return 1
    fi

    for f in "${files[@]}"; do cp -L "$OUT/$f" "$staging/"; done
    cp -L "$UUU_DIR/$lst" "$staging/"
    cp -L "$UUU_DIR/uuu"  "$staging/"
    chmod +x "$staging/uuu"

    cat > "$staging/flash-here.sh" <<'INNER'
#!/bin/bash
# Run on the remote PC inside ~/image/ to flash the attached device.
# Usage:
#   ./flash-here.sh           # auto-detect mode by lsusb
#   ./flash-here.sh uuu       # force UUU (board must be in ROM SDP, 1fc9:0146)
#   ./flash-here.sh fastboot  # force fastboot (board must be in u-boot fastboot, 1fc9:0152)
set -e
cd "$(dirname "$0")"
LST="emmc_burn_android_imx8mp_var_som_1_x_symphony.lst"

detect_mode() {
    if lsusb 2>/dev/null | grep -q "1fc9:0146"; then echo uuu; return; fi
    if lsusb 2>/dev/null | grep -q "1fc9:0152"; then echo fastboot; return; fi
    echo none
}

MODE="${1:-$(detect_mode)}"
case "$MODE" in
  uuu)
    [ -x ./uuu ] || { echo "uuu binary missing"; exit 1; }
    [ -f "$LST" ] || { echo "$LST missing"; exit 1; }
    echo "[remote] UUU flash (board in ROM SDP)..."
    sudo ./uuu "$LST"
    ;;
  fastboot)
    command -v fastboot >/dev/null || { echo "fastboot not installed"; exit 1; }
    echo "[remote] fastboot reflash (board in u-boot fastboot)..."
    fastboot devices
    if fastboot getvar unlocked 2>&1 | grep -q "unlocked: no"; then
        echo "[remote] Device is locked. Unlocking (will wipe userdata, ~40 s)..."
        fastboot flashing unlock
    fi
    fastboot flash bootloader0   spl-imx8mp-var-dart-dual.bin
    fastboot flash gpt           partition-table-dual.img
    for slot in a b; do
        fastboot flash bootloader_$slot   bootloader-imx8mp-var-dart-dual.img
        fastboot flash dtbo_$slot         dtbo-imx8mp-var-som-1.x-symphony.img
        fastboot flash boot_$slot         boot.img
        fastboot flash vendor_boot_$slot  vendor_boot.img
        fastboot flash init_boot_$slot    init_boot.img
        fastboot flash vbmeta_$slot       vbmeta-imx8mp-var-som-1.x-symphony.img
    done
    fastboot flash super         super.img
    fastboot erase misc
    fastboot erase metadata
    fastboot erase userdata
    fastboot --set-active=a
    fastboot reboot
    ;;
  none)
    echo "No NXP device detected (looked for 1fc9:0146 SDP or 1fc9:0152 fastboot)."
    echo "Power on the board, check USB cable, then re-run."
    exit 1 ;;
  *)
    echo "Usage: $0 [uuu|fastboot]"; exit 1 ;;
esac
echo "[remote] Done."
INNER
    chmod +x "$staging/flash-here.sh"

    log_info "Pushing payload to ${REMOTE_DEPLOY_USER}@${REMOTE_DEPLOY_HOST}:${REMOTE_DEPLOY_DIR}/ ..."
    ssh -o StrictHostKeyChecking=accept-new "${REMOTE_DEPLOY_USER}@${REMOTE_DEPLOY_HOST}" \
        "mkdir -p ${REMOTE_DEPLOY_DIR}" || { log_error "Cannot create remote dir"; return 1; }

    rsync -avh --progress \
        -e "ssh -o StrictHostKeyChecking=accept-new" \
        "$staging"/ \
        "${REMOTE_DEPLOY_USER}@${REMOTE_DEPLOY_HOST}:${REMOTE_DEPLOY_DIR}/" \
        || { log_error "rsync failed"; return 1; }

    log_ok "Payload delivered to ${REMOTE_DEPLOY_HOST}:${REMOTE_DEPLOY_DIR}/"
    echo ""
    echo "Flash from the remote PC with:"
    echo "  ssh ${REMOTE_DEPLOY_USER}@${REMOTE_DEPLOY_HOST}"
    echo "  cd ${REMOTE_DEPLOY_DIR} && ./flash-here.sh           # auto-detect"
    echo "  cd ${REMOTE_DEPLOY_DIR} && ./flash-here.sh uuu"
    echo "  cd ${REMOTE_DEPLOY_DIR} && ./flash-here.sh fastboot"
    echo ""
    read -r -p "Trigger remote flash now? [auto/uuu/fastboot/no]: " mode
    case "$mode" in
        auto|"") log_info "Triggering remote flash (auto-detect)..."
                 ssh -t "${REMOTE_DEPLOY_USER}@${REMOTE_DEPLOY_HOST}" \
                     "cd ${REMOTE_DEPLOY_DIR} && ./flash-here.sh" ;;
        uuu|fastboot) log_info "Triggering remote flash ($mode) ..."
                      ssh -t "${REMOTE_DEPLOY_USER}@${REMOTE_DEPLOY_HOST}" \
                          "cd ${REMOTE_DEPLOY_DIR} && ./flash-here.sh $mode" ;;
        *) log_info "Skipped remote flash. Files are ready in ${REMOTE_DEPLOY_DIR}/." ;;
    esac
}

# =============================================================================
# SD Card
# =============================================================================

sdcard() {
    local device="$1"
    if [ -z "$device" ]; then
        echo "Usage: $0 sdcard /dev/sdX"
        echo ""
        echo "Available devices:"
        lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "sd|mmcblk"
        return 1
    fi
    if [ ! -b "$device" ]; then
        log_error "$device is not a valid block device"
        return 1
    fi
    if [ ! -d "$OUT" ]; then
        log_error "Build output not found. Build first."
        return 1
    fi
    cd "$OUT"
    echo ""
    log_warn "WARNING: This will ERASE ALL DATA on $device"
    read -r -p "Are you sure? (yes/no): " confirm
    [ "$confirm" = "yes" ] || { log_info "Cancelled."; return 0; }
    log_info "Creating bootable SD card..."
    sudo "$ANDROID_BUILD_DIR/var-mksdcard.sh" -f imx8mp-var-som-1.x-symphony "$device"
    sync
    log_ok "SD card creation complete!"
}

build_sdcard_recovery() {
    local helper="$ANDROID_BUILD_DIR/artmedical-android/sdcard/build-sdcard-recovery.sh"
    [ -x "$helper" ] || helper="$ANDROID_BUILD_DIR/sdcard/build-sdcard-recovery.sh"
    if [ ! -x "$helper" ]; then
        log_error "build-sdcard-recovery.sh not found at: $ANDROID_BUILD_DIR/artmedical-android/sdcard/"
        return 1
    fi
    if [ ! -d "$OUT" ]; then
        log_error "Build output not found at $OUT. Run './modular-tools.sh build' first."
        return 1
    fi
    log_info "Building client-shippable recovery SD-card image..."
    "$helper" "$@"
}

# =============================================================================
# Clean
# =============================================================================

clean() {
    log_info "Cleaning build output..."
    cd "$ANDROID_BUILD_DIR" && make clean
    log_ok "Done. (Git-committed customizations remain; file-based patches in patches/ are untouched.)"
}

# =============================================================================
# Help
# =============================================================================

help() {
    cat <<EOF

==========================================
Art-Medical Android 14 Build Tools (git-based)
VAR-SOM-MX8M-PLUS V1.x Symphony (BCM WiFi)
==========================================

The "art-medical" customization lives as committed git revisions in:
  - device/variscite              (Quectel RIL, UART perms, dexopt, FTDI, dtbo)
  - vendor/variscite/kernel_imx   (FEC disable, AUO display, modem drivers)
  - system/core                   (Quectel cdc-wdm0 — currently file-patch)

Whatever is checked out in those trees IS what the build produces. There is
no longer a "vanilla vs patched" toggle.

Status:
  status               - Show git HEAD of each subrepo, art-med fingerprint
                         commits in history, and what's built in out/.

Build (builds current git state):
  build                - Full Android build
  build_bootimage      - Build only boot.img
  build_ota            - Build OTA package

Leftover file-based patches in patches/ (legacy):
  patch                - Apply any patches in patches/ that aren't already
                         in tree. Idempotent — re-applying is safe.
  unpatch              - Revert only file-based patches we applied
                         (does NOT touch git commits).

Flash:
  flash                - Local UUU flash (board attached to THIS PC, ROM SDP)
  deploy_remote        - rsync images + uuu + flash-here.sh to
                         ${REMOTE_DEPLOY_USER}@${REMOTE_DEPLOY_HOST}:${REMOTE_DEPLOY_DIR}/
                         then optionally trigger a flash there. flash-here.sh
                         auto-detects SDP vs fastboot and unlocks AVB if needed.
  sdcard /dev/sdX      - Write a bootable SD card to an attached card

Client delivery:
  build_sdcard_recovery [--variant N] [--output P]
                       - Build a .wic.zst recovery SD card for shipping

Maintenance:
  setup                - Install required packages (Adoptium JDK 8, udev rules)
  clean                - make clean (does NOT touch git or patches/)
  help                 - This help text
EOF
}

# =============================================================================
# Main
# =============================================================================

if [ -n "$*" ]; then
    "$@"
else
    if [ "$0" != "$BASH_SOURCE" ]; then
        echo "$BASH_SOURCE functions loaded"
    else
        echo "Art-Medical Android Build Tools"
        echo "Run \"$0 help\" for usage"
    fi
fi
