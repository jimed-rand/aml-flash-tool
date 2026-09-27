# Amlogic flash tool

This is the flash tool for Amlogic platforms.

----------------------------

## Support list

### Supported SoC Families

- Meson GXL: S905X, S905D, S905W, S905L, S805X
- Meson GXBB: S905, S905H
- Meson GXM: S912
- Meson G12A: S905X2, S905Y2, S905D2
- Meson G12B: S922X, A311D
- Meson SM1: S905X3, S905D3, S905Y3
- Meson AXG: A113D, A113X
- Meson TXLX: T962, T962E, T962X
- Meson 8 / 8b: S802, S805, S812

### Supported Boards and Devices

- P212 Reference Family (S905X - Meson GXL):
  - Amlogic P212 Reference Board
  - ZTE ZXV10 B860H v1.1 and v2.1
  - Fiberhome HG680-P / HG860P
  - Khadas VIM1 (S905X)
  - Libre Computer AML-S905X-CC (Le Potato)
  - Nexbox A95X (S905X)
  - Sunvell T95X / T95M
  - Xiaomi Mi Box 3S / 4C (MDZ-16-AB / MDZ-19-AA)
  - OSMC Vero 4K
- P281 / P271 Family (S905W / S905L - Meson GXL):
  - Tanix TX3 Mini
  - X96 Mini
  - Fiberhome / ZTE S905L telecom boxes
- GXBB Boards (S905 - Meson GXBB):
  - Amlogic P200 / P201 Reference Boards
  - Hardkernel ODROID-C2
- GXM Boards (S912 - Meson GXM):
  - Amlogic Q200 / Q201 Reference Boards
  - Khadas VIM2
  - Beelink GT1 / GT1 Ultimate
  - Minix Neo U9-H
- G12A Boards (S905X2 / S905Y2 - Meson G12A):
  - Radxa Zero
  - Khadas VIM3L
  - SEI Robotics SEI510
- G12B Boards (S922X / A311D - Meson G12B):
  - Khadas VIM3
  - Hardkernel ODROID-N2 / ODROID-N2+
  - Radxa Zero 2
  - Beelink GT-King / GT-King Pro
- SM1 Boards (S905X3 - Meson SM1):
  - SEI Robotics SEI610
  - X96 Max Plus
  - Tanix TX3 (SM1)
- AXG Boards (A113D / A113X - Meson AXG):
  - Amlogic S400 / S410 Reference Boards

## Installation

This flash tool relies on the update tool that needs to be installed first.
Please run:

```bash
sudo ./INSTALL.sh
```

to install dependencies and USB udev rules.

After installation, you can execute aml-flash-tool.sh from anywhere:

```bash
$ aml-flash-tool.sh --help
Usage: aml-flash-tool.sh [options] [path/to/aml_upgrade_package.img]
Supported SoC Families:
  gxl   : S905X, S905D, S905W, S905L, S805X (p212, p281, p271, B860H, HG680P, etc.)
  gxbb  : S905, S905H (p200, p201, Odroid C2, etc.)
  gxm   : S912 (q200, q201, Khadas VIM2, etc.)
  g12a  : S905X2, S905Y2, S905D2 (Radxa Zero, Khadas VIM3L, SEI510, etc.)
  g12b  : S922X, A311D (Khadas VIM3, Odroid N2/N2+, Radxa Zero 2, etc.)
  sm1   : S905X3, S905D3, S905Y3 (SEI610, X96 Max+, etc.)
  axg   : A113D, A113X (s400, s410, etc.)
  txlx  : T962, T962E, T962X
  m8    : S802, S805, S812 (Meson8, Meson8b)
Options:
  --tui, -i                     Launch interactive text user interface
  --board=<name>                Target board/device (e.g. p212, b860h, hg680p, radxa-zero)
  --soc=<family>                Target SoC family (gxl, gxbb, gxm, g12a, g12b, sm1, axg, txlx, m8)
  --img=path/to/image.img        Upgrade image package
  --parts=<all|bootloader|...>   Partitions to flash (default: all)
  --wipe                         Wipe data and cache partitions (default: 1)
  --no-wipe                      Do not wipe data and cache partitions
  --reset=<y|n>                  Reset board after burning (default: y)
  --uboot-file=path/to/uboot     Override bootloader file
  --efuse-file=path/to/efuse     Program eFuse file
  --password=path/to/password    Password file for locked USB mode
  --destroy                      Erase bootloader and reset board
  --erase-bootloader             Erase bootloader on connected device
  --reflash-bootloader           Erase and re-flash bootloader on connected device
  --mount-emmc, --ums            Access internal eMMC as USB Mass Storage
  --mmc-dev=<0|1>                Target MMC device for storage mode (default: 1 for eMMC)
  --read-uart[=dev], --uart      Read UART serial console over USB
  --baud=<rate>                  UART baud rate (default: 115200)
  --debug                        Enable debug messages
  --help, -h                     Display this help message
```

## Features and Usage

### Interactive TUI Mode

You can run the interactive menu by executing without arguments or by passing `--tui`:

```bash
aml-flash-tool.sh --tui
```

The TUI provides a complete menu to:
- Select and unpack upgrade images
- Choose SoC family or specific board presets
- Select specific partition(s) to flash
- Mount internal eMMC as USB Mass Storage (UMS)
- Read UART serial console over USB
- Erase or re-flash bootloader
- Toggle wipe, reset, debug, and advanced parameters

### Read UART from USB

To monitor or read the serial console output from a connected USB-to-UART adapter:

Auto-detect port and connect at default 115200 baud:

```bash
aml-flash-tool.sh --read-uart
```

Specify port and baud rate:

```bash
aml-flash-tool.sh --read-uart=/dev/ttyUSB0 --baud=115200
aml-flash-tool.sh --read-uart=/dev/ttyUSB0 --baud=921600
```

### Access eMMC as Mountable Storage (UMS Mode)

You can expose the internal eMMC (or SD card) of the connected device as standard USB Mass Storage to mount partitions on your host computer:

```bash
aml-flash-tool.sh --mount-emmc --img=path/to/image.img
```

Or for SD card (MMC 0):

```bash
aml-flash-tool.sh --mount-emmc --mmc-dev=0 --img=path/to/image.img
```

If the board is already running U-Boot in RAM:

```bash
aml-flash-tool.sh --mount-emmc
```

Once UMS mode is active, inspect block devices on the host (`lsblk` or `dmesg`) and mount partitions directly:

```bash
sudo mount /dev/sdX1 /mnt
```

### Erase and Re-flash Bootloader

To erase the bootloader from the connected device:

```bash
aml-flash-tool.sh --erase-bootloader --img=path/to/image.img
```

To erase and re-flash a new bootloader from an upgrade image package:

```bash
aml-flash-tool.sh --reflash-bootloader --img=path/to/image.img
```

To erase and re-flash a standalone bootloader binary file:

```bash
aml-flash-tool.sh --reflash-bootloader --img=path/to/image.img --uboot-file=path/to/u-boot.bin
```

### Run into maskrom mode

Connect the board to your host PC using the USB OTG port.

Methods to enter MaskROM mode:

1. Recovery button method:
   - Insert a non-conductive pin or toothpick into the AV port to hold the reset switch (or hold the dedicated KEY/SW1 button on development boards).
   - Connect the USB OTG cable while holding the button.
   - Release the button after host detects the USB device.

2. Test point / eMMC pin short method (for locked, bricked, or button-less boards):
   - Locate the eMMC clock or DAT0 test point, or short eMMC pins 29-30 to ground.
   - Connect USB cable with pins shorted, then release immediately upon host detection.

3. Software reboot method (from existing Android or Linux system):
   - From ADB shell or terminal: `reboot update`
   - From U-Boot console: `run update`

When the SoC is running in maskrom mode properly, your Linux machine will detect a new USB device.

By calling dmesg, you should see something like:

```bash
[177122.811055] usb 1-2.2: new high-speed USB device number 31 using xhci_hcd
[177123.584038] usb 1-2.2: New USB device found, idVendor=1b8e, idProduct=c003, bcdDevice= 0.20
[177123.584044] usb 1-2.2: New USB device strings: Mfr=1, Product=2, SerialNumber=0
[177123.584048] usb 1-2.2: Product: GX-CHIP
[177123.584051] usb 1-2.2: Manufacturer: Amlogic
```

And lsusb will report the Amlogic USB device:

```bash
$ lsusb
Bus 001 Device 052: ID 1b8e:c003 Amlogic, Inc. USB DEVICE
```

### Run flash command

Automatic platform detection:

The tool unpacks the image configuration and automatically maps the target architecture (gxl, gxbb, gxm, g12a, g12b, sm1, axg, txlx, m8).

```bash
aml-flash-tool.sh path/to/aml_upgrade_package.img
```

Explicit target board selection:

```bash
aml-flash-tool.sh --board=p212 path/to/aml_upgrade_package.img
aml-flash-tool.sh --board=b860h path/to/aml_upgrade_package.img
aml-flash-tool.sh --board=hg680p path/to/aml_upgrade_package.img
aml-flash-tool.sh --board=radxa-zero path/to/aml_upgrade_package.img
aml-flash-tool.sh --board=vim3 path/to/aml_upgrade_package.img
```

Explicit SoC family selection:

```bash
aml-flash-tool.sh --soc=gxl path/to/aml_upgrade_package.img
aml-flash-tool.sh --soc=gxbb path/to/aml_upgrade_package.img
aml-flash-tool.sh --soc=gxm path/to/aml_upgrade_package.img
aml-flash-tool.sh --soc=g12a path/to/aml_upgrade_package.img
aml-flash-tool.sh --soc=g12b path/to/aml_upgrade_package.img
aml-flash-tool.sh --soc=sm1 path/to/aml_upgrade_package.img
```

It will flash all partitions that are part of the aml_upgrade_package.img.
