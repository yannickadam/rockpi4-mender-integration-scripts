#!/bin/bash

# Script to generate Mender integration binaries for RockPi4 Armbian
#
# Files that will be packaged:
#
#     - rksd_loader.img
#     - fw_printenv
#     - fw_env.config
#     - boot.scr
#
# NOTE! This script is not necessarily well tested and the main purpose
# is to provide an reference on how the current integration binaries where
# generated.

set -e

function usage() {
    echo "./$(basename $0) <emmc|sd>"
}

if [ -z "$1" ]; then
    usage
    exit 1
fi

if [ "$1" == "emmc" -o "$1" == "sd" ]; then
    rockpi4_config=$1
else
    usage
    exit 1
fi

export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=aarch64

# Test if the toolchain is actually installed
aarch64-linux-gnu-gcc --version

# Fresh clone
rm -rf rockpi4-uboot
git clone https://github.com/u-boot/u-boot.git -b v2020.04 rockpi4-uboot
cd rockpi4-uboot

# Get u-boot base version
uboot_version=$(git describe --tags | sed 's/\([0-9]\{4\}\.[0-9]\{2\}\).*/\1/')

# Apply Mender integration patches
git am ../patches/0002-Generic-boot-code-for-Mender.patch
git apply ../patches/0003-Integration-of-Mender-boot-code-into-U-Boot.patch
git am ../patches/0004-add-config_mender_defines.h.patch
git apply ../patches/0005-configs-rockpi4-add-Mender-support.patch
# Comment below if you would like to generate binaries suitable for booting
# from SD card instead of eMMC
if [ "$rockpi4_config" == "emmc" ]; then
    git apply ../patches/0006-RockPi4-eMMC-integration-for-Mender.patch
fi
git apply ../patches/0010-enable-DT-overlay.patch
git apply ../patches/0011-env-display-offset.patch
git apply ../patches/0012-remove-wrong-env-dev.patch


git clone https://github.com/armbian/rkbin -b master rkbin-tools

make rock-pi-4-rk3399_defconfig
make BL31=rkbin-tools/rk33/rk3399_bl31_v1.30.elf idbloader.img u-boot.itb
make envtools

# Original code to have a working bootloader 
# dd if=idbloader.img of=rockpi4-uboot.img seek=64 conv=notrunc
# dd if=u-boot.itb of=rockpi4-uboot.img seek=16384 conv=notrunc

# Code to work with mender-convert
dd if=idbloader.img of=rksd_loader.img seek=0 conv=notrunc
dd if=u-boot.itb of=rksd_loader.img seek=16320 conv=notrunc

# This script is copied from an stock Armbian image and has been modified
# slightly to work with Mender.
cat <<- 'EOF' > boot.cmd
# DO NOT EDIT THIS FILE
#
# Please edit /boot/armbianEnv.txt to set supported parameters
#

setenv load_addr "0x39000000"
setenv overlay_error "false"
# default values
setenv verbosity "7"
setenv console "serial"
setenv rootfstype "ext4"
setenv docker_optimizations "on"

run mender_setup

echo "Boot script loaded from ${mender_uboot_boot}"

if test -e ${mender_uboot_root} /boot/armbianEnv.txt; then
        load ${mender_uboot_root} ${load_addr} /boot/armbianEnv.txt
        env import -t ${load_addr} ${filesize}
fi

if test "${logo}" = "disabled"; then setenv logo "logo.nologo"; fi

if test "${console}" = "display" || test "${console}" = "both"; then setenv consoleargs "console=tty1"; fi
if test "${console}" = "serial" || test "${console}" = "both"; then setenv consoleargs "${consoleargs} console=ttyS2,1500000n8"; fi

setenv verbosity "7"

# get PARTUUID of first partition on SD/eMMC the boot script was loaded from
if test "${devtype}" = "mmc"; then part uuid mmc ${devnum}:1 partuuid; fi

setenv bootargs "root=${mender_kernel_root} rootwait rootfstype=${rootfstype} ${consoleargs} panic=10 consoleblank=0 loglevel=${verbosity} ubootpart=${partuuid} usb-storage.quirks=${usbstoragequirks} ${extraargs} ${extrabootargs}"

if test "${docker_optimizations}" = "on"; then setenv bootargs "${bootargs} cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1"; fi

load ${mender_uboot_root} ${ramdisk_addr_r} /boot/uInitrd
load ${mender_uboot_root} ${kernel_addr_r} /boot/Image

load ${mender_uboot_root} ${fdt_addr_r} /boot/dtb/${fdtfile}
fdt addr ${fdt_addr_r}
fdt resize 65536
for overlay_file in ${overlays}; do
        if load ${mender_uboot_root} ${load_addr} /boot/dtb/rockchip/overlay/${overlay_prefix}-${overlay_file}.dtbo; then
                echo "Applying kernel provided DT overlay ${overlay_prefix}-${overlay_file}.dtbo"
                fdt apply ${load_addr} || setenv overlay_error "true"
        fi
done
for overlay_file in ${user_overlays}; do
        if load ${mender_uboot_root} ${load_addr} /boot/overlay-user/${overlay_file}.dtbo; then
                echo "Applying user provided DT overlay ${overlay_file}.dtbo"
                fdt apply ${load_addr} || setenv overlay_error "true"
        fi
done
if test "${overlay_error}" = "true"; then
        echo "Error applying DT overlays, restoring original DT"
        load ${mender_uboot_root} ${fdt_addr_r} /boot/dtb/${fdtfile}
else
        if load ${mender_uboot_root} ${load_addr} /boot/dtb/rockchip/overlay/${overlay_prefix}-fixup.scr; then
                echo "Applying kernel provided DT fixup script (${overlay_prefix}-fixup.scr)"
                source ${load_addr}
        fi
        if test -e ${devtype} ${devnum} /boot/fixup.scr; then
                load ${mender_uboot_root} ${load_addr} /boot/fixup.scr
                echo "Applying user provided fixup script (fixup.scr)"
                source ${load_addr}
        fi
fi
booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
run mender_try_to_recover

# Recompile with:
# mkimage -C none -A arm -T script -d boot.cmd boot.scr
EOF

mkimage -C none -A arm -T script -d boot.cmd boot.scr

cat <<- EOF > fw_env.config
/dev/mmcblk0 0x400000 0x8000
/dev/mmcblk0 0x600000 0x8000
EOF

cp rksd_loader.img boot.scr tools/env/fw_printenv fw_env.config $OLDPWD/
cd -
pwd 
tar czvf rockpi4_${rockpi4_config}-${uboot_version}.tar.gz rksd_loader.img boot.scr fw_printenv fw_env.config

# Writing the image to SD/eMMC
#dd if=$1/rksd_loader.img of=$2 seek=64 conv=notrunc status=none >/dev/null 2>&
