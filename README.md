# Art-Medical Android 14 Build System

Build tools for **VAR-SOM-MX8M-PLUS V1.x** on **Symphony-Board** with BCM WiFi support.

Based on Variscite's Android 14.0.0_1.0.0 release for i.MX8M Plus.

## Installation

Extract into your existing `android_build` directory:

```bash
cd ~/var_imx-android-14.0.0_1.0.0/android_build
unzip artmedical-patches.zip
chmod +x modular-tools.sh
```

## Directory Structure

```
android_build/
├── modular-tools.sh            # Build script
├── patches/                    # Art-Medical patches
│   ├── system/core/
│   ├── device/variscite/
│   └── vendor/variscite/kernel_imx/
├── uuu/                        # Flash tools
│   ├── uuu
│   └── emmc_burn_android_imx8mp_var_som_1_x_symphony.lst
├── system/                     # Android source
├── device/
├── vendor/
└── ...
```

## Commands

| Command | Description |
|---------|-------------|
| `./modular-tools.sh status` | Show current state (vanilla/patched) |
| `./modular-tools.sh patch` | Apply Art-Medical patches |
| `./modular-tools.sh unpatch` | Revert to vanilla |
| `./modular-tools.sh build` | Full build (asks vanilla/patched) |
| `./modular-tools.sh build_bootimage` | Build boot.img only |
| `./modular-tools.sh build_ota` | Build OTA package |
| `./modular-tools.sh flash` | Flash to eMMC via UUU |
| `./modular-tools.sh sdcard /dev/sdX` | Create bootable SD card |
| `./modular-tools.sh build_sdcard_recovery` | Build a client-shippable `.wic.zst` recovery SD image |
| `./modular-tools.sh setup` | Install build dependencies |
| `./modular-tools.sh clean` | Clean build output |
| `./modular-tools.sh help` | Show help |

## Build Variants

All build commands ask which variant to build:

- **VANILLA**: Unmodified Variscite Android build
- **PATCHED**: With Art-Medical modifications

The script automatically applies or reverts patches as needed.

## Patches Included

### system/core
- `0001-AOSP-system-core-add-Quectel-patch...` - Creates /dev/cdc-wdm0 for Quectel modem

### device/variscite
- `0001-imx8mp-var-dart-Add-initial-radio...` - Quectel EG25-G/GL RIL driver
- `0002-Change-UART-device-permissions...` - UART permissions for /dev/ttymxc0
- `0003-imx8mp-var-dart-force-AOT-dexopt...` - Force `pm.dexopt.install=speed` so installed APKs are AOT compiled (apps without cloud profiles otherwise stay interpreted)

### vendor/variscite/kernel_imx
- `0001-modem-setup-in-defconfig.patch` - Kernel config for USB modem
- `0002-Disable-NXP-FEC-ethernet...` - Custom display timing (AUO G121EAN010)
- `0003-disable-unnecessary-hardware...` - Disable unused peripherals

## Flash Instructions

### Via UUU (recommended)

1. Set boot mode to **SD card** (with NO card inserted)
2. Connect USB OTG cable from board to host PC
3. Power on the board
4. Verify device: `lsusb` should show "NXP Semiconductors"
5. Run: `./modular-tools.sh flash`

### Via SD Card

1. Insert SD card into host PC
2. Identify device: `lsblk`
3. Run: `./modular-tools.sh sdcard /dev/sdX`
4. Insert SD card into board
5. Set boot mode to SD card
6. Power on

## Client delivery (recovery SD card image)

To ship a new version to a client, produce a self-contained `.wic.zst` that
writes Android to the device's eMMC on first boot:

```
./modular-tools.sh build_sdcard_recovery
```

This wraps Variscite's prebuilt Yocto recovery SD image (auto-downloaded once
and cached in `sdcard/base/`) with your most recent Android build. Output
lands in `sdcard/artmedical-sdcard-<date>.wic.zst` (~5 GB).

Client instructions:

```
zstd -d artmedical-sdcard-<date>.wic.zst -o artmedical-sdcard.wic
sudo dd if=artmedical-sdcard.wic of=/dev/sdX bs=1M status=progress conv=fsync
```

Insert the SD card, set boot mode to **SD card**, power on. `install_android.sh`
runs automatically, flashes eMMC, then powers down. Remove the card, switch
boot mode back to **eMMC**, power on — the board now runs your Android.

See `sdcard/build-sdcard-recovery.sh --help` for variant overrides and other
options. The target is VAR-SOM-MX8M-PLUS V1.x on Symphony-Board by default.

## Requirements

- Ubuntu 20.04 or 22.04 (64-bit)
- 32GB RAM recommended (16GB minimum with 32GB swap)
- 500GB free disk space

## Troubleshooting

### Build fails with "Killed" (OOM)

Add more swap:
```bash
sudo swapoff /swapfile
sudo rm /swapfile
sudo fallocate -l 32G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### Java not found

Run setup to install Adoptium JDK 8:
```bash
./modular-tools.sh setup
```

### UUU device not detected

1. Verify boot mode is SD card with no card inserted
2. Check USB OTG cable connection
3. Reload udev rules:
   ```bash
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```

### Patch fails to apply

Check current state:
```bash
./modular-tools.sh status
```

If needed, revert and re-apply:
```bash
./modular-tools.sh unpatch
./modular-tools.sh patch
```

## Workflow Example

```bash
# First time setup
./modular-tools.sh setup

# Check status
./modular-tools.sh status

# Build with Art-Medical patches
./modular-tools.sh build
# Select: 2) Build PATCHED

# Flash to device
./modular-tools.sh flash

# Later, build vanilla for comparison
./modular-tools.sh build
# Select: 1) Build VANILLA
```

## License

Art-Medical Proprietary
