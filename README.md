# Art-Medical Android 14 Build System

Build tools for **VAR-SOM-MX8M-PLUS V1.x** on **Symphony-Board** with BCM WiFi support.

Based on Variscite's Android 14.0.0_1.0.0 release for i.MX8M Plus.

## Quick Start

```bash
git clone <your-repo-url> artmedical-android
cd artmedical-android
./modular-tools.sh setup
./modular-tools.sh fetch
./modular-tools.sh build
./modular-tools.sh flash
```

## Commands

| Command | Description |
|---------|-------------|
| `setup` | Install required packages and JDK |
| `fetch` | Download Android source |
| `status` | Show current state (vanilla/patched) |
| `patch` | Apply Art-Medical patches |
| `unpatch` | Revert to vanilla |
| `build` | Full build (asks vanilla/patched) |
| `build_bootimage` | Build boot.img only (asks vanilla/patched) |
| `build_ota` | Build OTA package (asks vanilla/patched) |
| `flash` | Flash to eMMC via UUU |
| `sdcard /dev/sdX` | Create bootable SD card |
| `clean` | Clean build output |

## Build Variants

- **Vanilla**: Unmodified Variscite Android build
- **Patched**: With Art-Medical modifications

All build commands ask which variant to build.

## Patches Included

### system/core
- Quectel cdc-wdm0 device creation

### device/variscite
- Quectel EG25-G/GL RIL driver integration
- UART permissions for /dev/ttymxc0

### vendor/variscite/kernel_imx
- Kernel config for USB modem drivers
- Custom display timing (AUO G121EAN010)
- Disable unused hardware (Ethernet, HDMI, etc.)

## Requirements

- Ubuntu 20.04/22.04 (64-bit)
- 32GB RAM (or 16GB + 32GB swap)
- 500GB free disk space

## Flash Instructions

### Via UUU (recommended)
1. Set boot mode to SD card (NO card inserted)
2. Connect USB OTG cable
3. Power on board
4. Run: `./modular-tools.sh flash`

### Via SD Card
1. Run: `./modular-tools.sh sdcard /dev/sdX`
2. Insert SD card into board
3. Set boot mode to SD card
4. Power on

## Troubleshooting

### OOM during build
```bash
sudo swapoff /swapfile && sudo rm /swapfile
sudo fallocate -l 32G /swapfile
sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
```

### UUU device not detected
1. Boot mode = SD card (no card inserted)
2. USB OTG connected
3. Board powered on

## Project Structure

```
artmedical-android/
├── modular-tools.sh
├── README.md
├── patches/
│   ├── system/core/
│   ├── device/variscite/
│   └── vendor/variscite/kernel_imx/
└── uuu/
    ├── uuu
    └── emmc_burn_android_imx8mp_var_som_1_x_symphony.lst
```

## License

Art-Medical Proprietary
