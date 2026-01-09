#!/bin/bash
set -e

# =============================================================================
# Art-Medical Android 14 Build Tools
# VAR-SOM-MX8M-PLUS V1.x on Symphony-Board with BCM WiFi
#
# Place this script inside android_build/ directory along with patches/ and uuu/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_BUILD_DIR="$SCRIPT_DIR"
OUT="$ANDROID_BUILD_DIR/out/target/product/dart_mx8mp"
PATCHES_DIR="$SCRIPT_DIR/patches"
UUU_DIR="$SCRIPT_DIR/uuu"
STATE_FILE="$ANDROID_BUILD_DIR/.artmedical_state"
APPLIED_FILE="$ANDROID_BUILD_DIR/.artmedical_applied"

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
# State Management
# =============================================================================

get_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "vanilla"
    fi
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

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
    
    # Install Adoptium JDK 8 (openjdk-8 is broken in Ubuntu repos)
    if [ ! -d "/usr/lib/jvm/temurin-8-jdk-amd64" ]; then
        log_info "Installing Adoptium Temurin JDK 8..."
        wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | sudo gpg --dearmor -o /usr/share/keyrings/adoptium.gpg 2>/dev/null || true
        echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/adoptium.list
        sudo apt-get update
        sudo apt-get -y install temurin-8-jdk
    fi
    
    # udev rules for fastboot/UUU
    sudo bash -c 'cat > /etc/udev/rules.d/51-android.rules << EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="1fc9", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="15a2", MODE="0666", GROUP="plugdev"
EOF'
    sudo udevadm control --reload-rules && sudo udevadm trigger
    
    log_ok "Setup complete!"
}

# =============================================================================
# Patch Management
# =============================================================================

_apply_single_patch() {
    local patch_file="$1"
    local target_dir="$2"
    
    if [ ! -d "$target_dir" ]; then
        log_error "Target directory not found: $target_dir"
        return 1
    fi
    
    cd "$target_dir"
    
    # Check if patch can be applied
    if git apply --check "$patch_file" 2>/dev/null; then
        git apply "$patch_file"
        log_ok "Applied: $(basename "$patch_file") → $(basename "$target_dir")"
        return 0
    else
        log_warn "Patch may already be applied or conflicts: $(basename "$patch_file")"
        return 1
    fi
}

_revert_single_patch() {
    local patch_file="$1"
    local target_dir="$2"
    
    if [ ! -d "$target_dir" ]; then
        log_error "Target directory not found: $target_dir"
        return 1
    fi
    
    cd "$target_dir"
    
    # Check if patch can be reverted
    if git apply --check -R "$patch_file" 2>/dev/null; then
        git apply -R "$patch_file"
        log_ok "Reverted: $(basename "$patch_file") → $(basename "$target_dir")"
        return 0
    else
        log_warn "Patch may not be applied: $(basename "$patch_file")"
        return 1
    fi
}

patch() {
    local current_state=$(get_state)
    
    if [ "$current_state" = "patched" ]; then
        log_warn "Already in patched state. Run 'unpatch' first if you want to re-apply."
        return 1
    fi
    
    if [ ! -d "$PATCHES_DIR" ]; then
        log_error "Patches directory not found: $PATCHES_DIR"
        return 1
    fi
    
    log_info "Applying Art-Medical patches..."
    
    local applied=0
    local failed=0
    
    # Clear applied file
    > "$APPLIED_FILE"
    
    # Apply patches in order: system/core, device/variscite, vendor/variscite/kernel_imx
    
    # 1. system/core patches
    if [ -d "$PATCHES_DIR/system/core" ]; then
        for p in "$PATCHES_DIR/system/core"/*.patch; do
            [ -f "$p" ] || continue
            if _apply_single_patch "$p" "$ANDROID_BUILD_DIR/system/core"; then
                echo "system/core:$p" >> "$APPLIED_FILE"
                ((applied++))
            else
                ((failed++))
            fi
        done
    fi
    
    # 2. device/variscite patches
    if [ -d "$PATCHES_DIR/device/variscite" ]; then
        for p in "$PATCHES_DIR/device/variscite"/*.patch; do
            [ -f "$p" ] || continue
            if _apply_single_patch "$p" "$ANDROID_BUILD_DIR/device/variscite"; then
                echo "device/variscite:$p" >> "$APPLIED_FILE"
                ((applied++))
            else
                ((failed++))
            fi
        done
    fi
    
    # 3. vendor/variscite/kernel_imx patches
    if [ -d "$PATCHES_DIR/vendor/variscite/kernel_imx" ]; then
        for p in "$PATCHES_DIR/vendor/variscite/kernel_imx"/*.patch; do
            [ -f "$p" ] || continue
            if _apply_single_patch "$p" "$ANDROID_BUILD_DIR/vendor/variscite/kernel_imx"; then
                echo "vendor/variscite/kernel_imx:$p" >> "$APPLIED_FILE"
                ((applied++))
            else
                ((failed++))
            fi
        done
    fi
    
    set_state "patched"
    log_ok "Patches applied: $applied successful, $failed failed/skipped"
}

unpatch() {
    local current_state=$(get_state)
    
    if [ "$current_state" = "vanilla" ]; then
        log_warn "Already in vanilla state."
        return 0
    fi
    
    if [ ! -f "$APPLIED_FILE" ]; then
        log_error "No record of applied patches. Manual cleanup may be needed."
        return 1
    fi
    
    log_info "Reverting Art-Medical patches..."
    
    # Revert in reverse order
    tac "$APPLIED_FILE" | while IFS=: read -r target patch_path; do
        case "$target" in
            "system/core")
                target_dir="$ANDROID_BUILD_DIR/system/core"
                ;;
            "device/variscite")
                target_dir="$ANDROID_BUILD_DIR/device/variscite"
                ;;
            "vendor/variscite/kernel_imx")
                target_dir="$ANDROID_BUILD_DIR/vendor/variscite/kernel_imx"
                ;;
            *)
                log_warn "Unknown target: $target"
                continue
                ;;
        esac
        
        _revert_single_patch "$patch_path" "$target_dir"
    done
    
    rm -f "$APPLIED_FILE"
    set_state "vanilla"
    log_ok "Patches reverted"
}

status() {
    echo ""
    echo "=========================================="
    echo "Art-Medical Android Build Status"
    echo "=========================================="
    echo ""
    
    log_ok "Android source: $ANDROID_BUILD_DIR"
    
    # Check state
    local state=$(get_state)
    if [ "$state" = "patched" ]; then
        echo -e "Patch state: ${GREEN}PATCHED${NC}"
    else
        echo -e "Patch state: ${YELLOW}VANILLA${NC}"
    fi
    
    # List applied patches
    if [ -f "$APPLIED_FILE" ] && [ -s "$APPLIED_FILE" ]; then
        echo ""
        echo "Applied patches:"
        while IFS=: read -r target patch_path; do
            echo "  - $(basename "$patch_path") → $target"
        done < "$APPLIED_FILE"
    fi
    
    # Check output
    if [ -d "$OUT" ]; then
        echo ""
        echo "Build output: $OUT"
        if [ -f "$OUT/boot.img" ]; then
            log_ok "boot.img exists ($(stat -c%s "$OUT/boot.img" | numfmt --to=iec))"
        fi
        if [ -f "$OUT/super.img" ]; then
            log_ok "super.img exists ($(stat -c%s "$OUT/super.img" | numfmt --to=iec))"
        fi
    fi
    
    echo ""
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

# Shared function for all build commands to select variant
_select_build_variant() {
    local current_state=$(get_state)
    
    echo ""
    echo "Current state: $current_state"
    echo ""
    echo "Build options:"
    echo "  1) Build VANILLA (without Art-Medical patches)"
    echo "  2) Build PATCHED (with Art-Medical patches)"
    echo "  3) Cancel"
    echo ""
    read -p "Select [1-3]: " choice
    
    case "$choice" in
        1)
            if [ "$current_state" = "patched" ]; then
                log_info "Switching to vanilla state..."
                unpatch
            fi
            ;;
        2)
            if [ "$current_state" = "vanilla" ]; then
                log_info "Applying patches..."
                patch
            fi
            ;;
        3)
            log_info "Build cancelled."
            return 1
            ;;
        *)
            log_error "Invalid choice"
            return 1
            ;;
    esac
    
    return 0
}

build() {
    _select_build_variant || return 0
    
    log_info "Starting full build ($(get_state) state)..."
    build_env || return 1
    TARGET_USES_BCM_WIFI=true ./imx-make.sh -j$(nproc) 2>&1 | tee build-$(get_state).log
    
    log_ok "Build complete! Output: $OUT"
}

build_bootimage() {
    _select_build_variant || return 0
    
    log_info "Building boot.img only ($(get_state) state)..."
    build_env || return 1
    TARGET_USES_BCM_WIFI=true make bootimage -j$(nproc)
    
    log_ok "boot.img build complete!"
}

build_ota() {
    _select_build_variant || return 0
    
    log_info "Building OTA package ($(get_state) state)..."
    build_env || return 1
    TARGET_USES_BCM_WIFI=true ./imx-make.sh bootloader kernel -j$(nproc)
    TARGET_USES_BCM_WIFI=true make otapackage -j$(nproc) 2>&1 | tee build-ota-$(get_state).log
    
    log_ok "OTA build complete!"
}

# =============================================================================
# Flash
# =============================================================================

flash() {
    if [ ! -d "$OUT" ]; then
        log_error "Build output not found at $OUT. Build first."
        return 1
    fi
    
    # Copy UUU files to output directory
    if [ -d "$UUU_DIR" ]; then
        log_info "Preparing flash files..."
        cp "$UUU_DIR/emmc_burn_android_imx8mp_var_som_1_x_symphony.lst" "$OUT/" 2>/dev/null || true
        cp "$UUU_DIR/uuu" "$OUT/" 2>/dev/null && chmod +x "$OUT/uuu" || true
    fi
    
    cd "$OUT"
    
    echo ""
    echo "=========================================="
    echo "Flash to eMMC via UUU"
    echo "=========================================="
    echo ""
    echo "Before continuing, make sure:"
    echo "  1. Boot mode set to SD card (with NO card inserted)"
    echo "  2. Board connected via USB OTG"
    echo "  3. Board powered on"
    echo ""
    
    # Check if device is detected
    if lsusb | grep -qi "nxp\|freescale\|1fc9"; then
        log_ok "NXP device detected"
    else
        log_warn "NXP device NOT detected. Check USB connection and boot mode."
    fi
    
    read -p "Continue with flash? (yes/no): " confirm
    [ "$confirm" != "yes" ] && { log_info "Flash cancelled."; return 0; }
    
    log_info "Starting UUU flash..."
    if [ -x "./uuu" ]; then
        sudo ./uuu emmc_burn_android_imx8mp_var_som_1_x_symphony.lst
    else
        sudo uuu emmc_burn_android_imx8mp_var_som_1_x_symphony.lst
    fi
    
    log_ok "Flash complete!"
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
    read -p "Are you sure? (yes/no): " confirm
    [ "$confirm" != "yes" ] && { log_info "Cancelled."; return 0; }
    
    log_info "Creating bootable SD card..."
    sudo "$ANDROID_BUILD_DIR/var-mksdcard.sh" -f imx8mp-var-som-1.x-symphony "$device"
    sync
    
    log_ok "SD card creation complete!"
}

# =============================================================================
# Clean
# =============================================================================

clean() {
    echo ""
    echo "Clean options:"
    echo "  1) Clean build output only"
    echo "  2) Clean build + revert patches (return to vanilla)"
    echo "  3) Cancel"
    echo ""
    read -p "Select [1-3]: " choice
    
    case "$choice" in
        1)
            log_info "Cleaning build output..."
            cd "$ANDROID_BUILD_DIR" && make clean
            ;;
        2)
            log_info "Reverting patches..."
            unpatch
            log_info "Cleaning build output..."
            cd "$ANDROID_BUILD_DIR" && make clean
            ;;
        3)
            log_info "Cancelled."
            ;;
        *)
            log_error "Invalid choice"
            return 1
            ;;
    esac
}

# =============================================================================
# Help
# =============================================================================

help() {
    echo ""
    echo "=========================================="
    echo "Art-Medical Android 14 Build Tools"
    echo "VAR-SOM-MX8M-PLUS V1.x Symphony (BCM WiFi)"
    echo "=========================================="
    echo ""
    echo "Patch Management:"
    echo "  status          - Show current state and applied patches"
    echo "  patch           - Apply Art-Medical patches"
    echo "  unpatch         - Revert Art-Medical patches"
    echo ""
    echo "Build (all ask for vanilla/patched):"
    echo "  build           - Full Android build"
    echo "  build_bootimage - Build only boot.img"
    echo "  build_ota       - Build OTA package"
    echo ""
    echo "Flash:"
    echo "  flash           - Flash to eMMC via UUU"
    echo "  sdcard /dev/sdX - Create bootable SD card"
    echo ""
    echo "Maintenance:"
    echo "  setup           - Install required packages"
    echo "  clean           - Clean build output"
    echo "  help            - Show this help"
    echo ""
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
