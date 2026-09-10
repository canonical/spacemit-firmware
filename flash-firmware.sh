#!/bin/sh
#
# flash-firmware.sh -- unified firmware flashing for the SpacemiT K3/X100.
#
# Shipped by the spacemit-firmware metapackage and run from its postinst
# both on "configure" and on "triggered" (dpkg file triggers watch the
# image directories of the dependency packages, see debian/triggers), so
# the whole firmware set is flashed coherently in one transaction
# whenever any of the firmware packages is installed or upgraded.
#
# Components flashed (images come from the dependency packages):
#   u-boot-spl-spacemit : bootinfo, FSBL, U-Boot environment
#   opensbi-spacemit    : fw_dynamic.itb
#   esos-spacemit       : esos.itb
#   edk2-spacemit       : edk2.itb (only when booted via UEFI, NOR only)
#
# U-Boot proper (u-boot.itb) is deliberately NOT flashed here: it lives
# in the u-boot-spacemit package, which is not a dependency of the
# metapackage and keeps its own postinst.
#
# Behaviour:
#   - non-SpacemiT host, chroot or ambiguous root device: skip with a
#     message and exit 0, package configuration must never be wedged by
#     the environment;
#   - boot medium cannot be determined on a SpacemiT host: exit 1, the
#     firmware would otherwise silently not be flashed;
#   - NOR writes are always erased first and every image is read back
#     and verified; a failed write or verification exits 1 with a
#     "do NOT reboot" warning.

set -e

# returns 0 if running in chroot, 1 if not
running_in_chroot() {
    if [ "${SYSTEMD_IGNORE_CHROOT:-0}" = "1" ]; then
        return 1
    fi

    if [ -e "/proc/1/root" ]; then
        root_dev_ino=$(stat -c '%d:%i' / 2>/dev/null) || return 0
        proc1_root_dev_ino=$(stat -L -c '%d:%i' /proc/1/root 2>/dev/null) || return 0

        [ "$root_dev_ino" = "$proc1_root_dev_ino" ] && return 1 || return 0
    fi

    if [ ! -d "/proc" ] || [ ! -r "/proc/version" ]; then
        [ "$$" = "1" ] && return 1 || return 0
    fi

    return 0
}

# Detect a Spacemit K3 / X100 platform.  Different kernels expose the SoC
# identity differently, so accept any of:
#   - "Spacemit(R) X100" model string in /proc/cpuinfo (older kernels)
#   - "spacemit,x100" uarch line in /proc/cpuinfo (newer kernels)
#   - "spacemit,k3" in /proc/device-tree/compatible (device tree)
target=""
if grep -q 'Spacemit(R) X100' /proc/cpuinfo \
    || grep -q 'spacemit,x100' /proc/cpuinfo \
    || { [ -r /proc/device-tree/compatible ] &&
         grep -qa 'spacemit,k3' /proc/device-tree/compatible; }; then
    target="spacemit"
else
    echo "Running not in Spacemit K3/X100, skipping firmware flashing."
    exit 0
fi

# Never touch the boot media from inside a chroot.
if running_in_chroot; then
    echo "Running in chroot, skipping firmware flashing."
    exit 0
fi

# Ensure mtdblock/mtdchar are loaded.  They are built-in on SpacemiT
# kernels but ship as modules on mainline kernels (e.g. Ubuntu), where
# /dev/mtdblock* and /dev/mtd* (needed to erase/verify NOR) won't exist
# until the modules are loaded.
modprobe mtdblock 2>/dev/null || true
modprobe mtdchar 2>/dev/null || true

BOOT_MODE=""
ROOT=""
for x in $(cat /proc/cmdline); do
    case $x in
    root=UUID=*)
        ROOT=${x#root=UUID=}
        DEVICES=$(blkid -s UUID | grep "$ROOT" | awk '{print $1}')
        DEVICE_COUNT=$(echo "$DEVICES" | wc -l)
        if [ "$DEVICE_COUNT" -gt 1 ]; then
            echo "Warning: Multiple devices found with the same UUID $ROOT:"
            echo "$DEVICES"
            echo "This may cause installation issues. Please ensure unique UUIDs."
            exit 0
        fi
        ROOT=$(echo "$DEVICES" | head -n1)
        ;;
    root=*)
        ROOT=${x#root=}
        ;;
    boot_mode=*)
        BOOT_MODE=${x#boot_mode=}
        ;;
    esac
done

# Map a boot_mode keyword to the matching boot device node.
get_boot_device_from_mode() {
    local mode=$1
    case $mode in
    emmc)
        echo "/dev/mmcblk2"
        ;;
    sdcard)
        echo "/dev/mmcblk0"
        ;;
    nor|nand)
        # NOR and NAND both use the MTD subsystem, usually /dev/mtdblock0.
        if [ -e "/dev/mtdblock0" ]; then
            echo "/dev/mtdblock0"
        else
            echo ""
        fi
        ;;
    ufs)
        echo "/dev/sda"
        ;;
    *)
        echo ""
        ;;
    esac
}

# Derive the base (whole-disk) device from a rootfs device path.
get_base_device() {
    local dev=$1
    case $dev in
    "/dev/mmcblk0"*)
        echo "/dev/mmcblk0"
        ;;
    "/dev/mmcblk2"*)
        echo "/dev/mmcblk2"
        ;;
    "/dev/sda"*)
        echo "/dev/sda"
        ;;
    "/dev/nvme0n1"*)
        echo "/dev/nvme0n1"
        ;;
    *)
        echo ""
        ;;
    esac
}

# Determine the target device: when boot_mode is set and points to a
# device different from the rootfs, prefer the boot device; otherwise
# fall back to the rootfs device.
TARGET_DEVICE=""
if [ -n "$BOOT_MODE" ]; then
    BOOT_DEVICE=$(get_boot_device_from_mode "$BOOT_MODE")
    if [ -n "$BOOT_DEVICE" ] && [ -n "$ROOT" ]; then
        ROOT_BASE_DEVICE=$(get_base_device "$ROOT")
        if [ "$BOOT_DEVICE" != "$ROOT_BASE_DEVICE" ]; then
            TARGET_DEVICE="$BOOT_DEVICE"
            echo "Boot device ($BOOT_MODE -> $BOOT_DEVICE) differs from rootfs device ($ROOT_BASE_DEVICE), using boot device."
        else
            TARGET_DEVICE="$ROOT_BASE_DEVICE"
            echo "Boot device matches rootfs device, using $TARGET_DEVICE."
        fi
    elif [ -n "$BOOT_DEVICE" ]; then
        TARGET_DEVICE="$BOOT_DEVICE"
        echo "Using boot device from boot_mode=$BOOT_MODE: $TARGET_DEVICE"
    else
        echo "Unsupported boot_mode=$BOOT_MODE, unable to determine boot device."
        exit 1
    fi
fi

# If no target device was determined yet (no boot_mode or parsing
# failed), fall back to the original logic based on the rootfs device.
if [ -z "$TARGET_DEVICE" ] && [ -n "$ROOT" ]; then
    TARGET_DEVICE=$(get_base_device "$ROOT")
fi

# Detect UEFI boot.
IS_UEFI=0
if [ -d "/sys/firmware/efi" ]; then
    IS_UEFI=1
fi

# When booted via UEFI without an explicit boot_mode, fall back to a
# NOR + storage combination if NOR flash is present.  This matches the
# common layout where NOR holds the boot firmware while SSD/UFS/eMMC
# holds the rootfs.
if [ "$IS_UEFI" -eq 1 ] && [ -z "$BOOT_MODE" ] && [ -f "/proc/mtd" ]; then
    echo "UEFI boot without boot_mode, NOR flash detected, falling back to NOR boot device."
    TARGET_DEVICE="/dev/mtdblock0"
    BOOT_MODE="nor"
fi

# ------------------------------------------------------------ components
SPL_DIR=/usr/lib/u-boot/spacemit
OPENSBI_ITB=/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.itb
ESOS_ITB=/usr/lib/riscv64-linux-gnu/esos/esos.itb
EDK2_ITB=/usr/lib/uefi/spacemit/edk2.itb

BOOTINFO_FILE=""
BOOTINFO_DEV="";  BOOTINFO_OFF=""
FSBL_DEV="";      FSBL_OFF=""
ENV_DEV="";       ENV_OFF=""
OPENSBI_DEV="";   OPENSBI_OFF=""
ESOS_DEV="";      ESOS_OFF=""
EDK2_DEV="";      EDK2_OFF=""

if [ -z "$TARGET_DEVICE" ]; then
    echo "Unable to determine target device (missing root= or boot_mode= in cmdline); firmware NOT flashed."
    exit 1
fi

case $TARGET_DEVICE in
"/dev/mmcblk0"|"/dev/mmcblk2"|"/dev/sda")
    BOOTINFO_FILE=bootinfo_block.bin
    BOOTINFO_DEV=$TARGET_DEVICE;  BOOTINFO_OFF=$((1024 * 1024))
    FSBL_DEV=$TARGET_DEVICE;      FSBL_OFF=$((1536 * 1024))
    ENV_DEV=$TARGET_DEVICE;       ENV_OFF=$((640 * 1024))
    OPENSBI_DEV=$TARGET_DEVICE;   OPENSBI_OFF=$((7168 * 1024))
    ESOS_DEV=$TARGET_DEVICE;      ESOS_OFF=$((4096 * 1024))
    # No NOR flash on this layout: EDK2 has nowhere to go.
    ;;
"/dev/mtdblock0")
    if [ "$BOOT_MODE" = "nand" ]; then
        BOOTINFO_FILE=bootinfo_spinand.bin
    else
        BOOTINFO_FILE=bootinfo_spinor.bin
    fi

    if [ ! -f "/proc/mtd" ]; then
        echo "Error: /proc/mtd not found, cannot determine MTD partition layout"
        exit 1
    fi

    MTD0_NAME=$(grep '^mtd0:' /proc/mtd | awk -F'"' '{print $2}')

    if [ "$MTD0_NAME" = "bootinfo" ]; then
        # mtd0 is the bootinfo partition: each component has its own
        # partition, write by partition number.
        echo "Detected MTD partition layout: independent partitions"
        BOOTINFO_DEV=/dev/mtdblock0; BOOTINFO_OFF=0
        FSBL_DEV=/dev/mtdblock1;     FSBL_OFF=0
        ENV_DEV=/dev/mtdblock2;      ENV_OFF=0
        OPENSBI_DEV=/dev/mtdblock4;  OPENSBI_OFF=0
        ESOS_DEV=/dev/mtdblock3;     ESOS_OFF=0
        EDK2_DEV=/dev/mtdblock5;     EDK2_OFF=0
    else
        # mtd0 is the whole device: write with byte offsets.
        echo "Detected MTD partition layout: single device with offsets (mtd0=$MTD0_NAME)"
        BOOTINFO_DEV=/dev/mtdblock0; BOOTINFO_OFF=0
        FSBL_DEV=/dev/mtdblock0;     FSBL_OFF=$((128 * 1024))
        ENV_DEV=/dev/mtdblock0;      ENV_OFF=$((640 * 1024))
        OPENSBI_DEV=/dev/mtdblock0;  OPENSBI_OFF=$((1728 * 1024))
        ESOS_DEV=/dev/mtdblock0;     ESOS_OFF=$((704 * 1024))
        EDK2_DEV=/dev/mtdblock0;     EDK2_OFF=$((2112 * 1024))
    fi
    ;;
"/dev/nvme0n1")
    if [ -f "/proc/mtd" ]; then
        # NVMe rootfs + NOR boot medium.
        BOOTINFO_FILE=bootinfo_spinor.bin
        MTD0_NAME=$(grep '^mtd0:' /proc/mtd | awk -F'"' '{print $2}')

        if [ "$MTD0_NAME" = "bootinfo" ]; then
            echo "Detected MTD partition layout: independent partitions"
            BOOTINFO_DEV=/dev/mtdblock0; BOOTINFO_OFF=0
            FSBL_DEV=/dev/mtdblock1;     FSBL_OFF=0
            ENV_DEV=/dev/mtdblock2;      ENV_OFF=0
            OPENSBI_DEV=/dev/mtdblock4;  OPENSBI_OFF=0
            ESOS_DEV=/dev/mtdblock3;     ESOS_OFF=0
            EDK2_DEV=/dev/mtdblock5;     EDK2_OFF=0
        else
            echo "Detected MTD partition layout: single device with offsets (mtd0=$MTD0_NAME)"
            BOOTINFO_DEV=/dev/mtdblock0; BOOTINFO_OFF=0
            FSBL_DEV=/dev/mtdblock0;     FSBL_OFF=$((128 * 1024))
            ENV_DEV=/dev/mtdblock0;      ENV_OFF=$((640 * 1024))
            OPENSBI_DEV=/dev/mtdblock0;  OPENSBI_OFF=$((1728 * 1024))
            ESOS_DEV=/dev/mtdblock0;     ESOS_OFF=$((704 * 1024))
            EDK2_DEV=/dev/mtdblock0;     EDK2_OFF=$((2112 * 1024))
        fi
    else
        # No NOR flash: the boot medium is eMMC.
        BOOTINFO_FILE=bootinfo_block.bin
        BOOTINFO_DEV=/dev/mmcblk2; BOOTINFO_OFF=$((1024 * 1024))
        FSBL_DEV=/dev/mmcblk2;     FSBL_OFF=$((1536 * 1024))
        ENV_DEV=/dev/mmcblk2;      ENV_OFF=$((640 * 1024))
        OPENSBI_DEV=/dev/mmcblk2;  OPENSBI_OFF=$((1728 * 1024))
        ESOS_DEV=/dev/mmcblk2;     ESOS_OFF=$((704 * 1024))
    fi
    ;;
*)
    echo "Unsupported target device=$TARGET_DEVICE"
    exit 1
    ;;
esac

# EDK2 lives in NOR flash only: when booted via UEFI but no NOR is
# present there is nowhere to write it.
if [ "$IS_UEFI" -eq 1 ] && [ -z "$EDK2_DEV" ]; then
    echo "No NOR flash detected (/proc/mtd absent), skipping the EDK2 image."
fi

# ------------------------------------------------------------- flashing
# Write one image to the boot medium and verify it.  NOR (mtdblock)
# destinations are always erased first: a plain dd can only flip 1->0
# bits, so overwriting a *different* image silently corrupts every byte
# that needs a 0->1 transition while dd still reports success -- the
# board then bricks on the next boot.  On offset-0 NOR targets flashcp
# erases, writes and verifies in one go; inside a whole-device node the
# exact region is erased with mtd_debug first, then dd writes in place
# and the result is read back and verified.
flash_one() {
    img=$1
    dev=$2
    off=$3

    if [ ! -f "$img" ]; then
        echo "Warning: missing image $img, skipping it."
        FAILED=1
        return 0
    fi
    if [ ! -b "$dev" ]; then
        echo "Warning: $dev is not a block device (mtdblock not available in this kernel?), skipping $img."
        FAILED=1
        return 0
    fi

    sz=$(stat -c %s "$img")
    echo "Flashing $img -> $dev at offset $off ..."

    case $dev in
    /dev/mtdblock*)
        mtd=/dev/mtd${dev#/dev/mtdblock}
        if [ ! -c "$mtd" ]; then
            echo "Error: $mtd not found (mtdchar module missing?)."
            echo "Refusing to write NOR without the ability to erase it. Aborting."
            exit 1
        fi

        if [ "$off" -eq 0 ]; then
            # Dedicated partition (or start of a whole-device node).
            echo "Erasing/writing/verifying $img on $mtd ..."
            if ! flashcp -v "$img" "$mtd"; then
                echo "Error: flashcp failed on $mtd"
                exit 1
            fi
            echo "Flashed and verified $img on $mtd."
            return 0
        fi

        # Offset inside a whole-device node: erase exactly the region
        # the image occupies before writing in place.
        es=$(cat "/sys/class/mtd/$(basename "$mtd")/erasesize" 2>/dev/null || echo 4096)
        if [ $((off % es)) -ne 0 ]; then
            echo "Error: offset $off not aligned to erase block size $es"
            exit 1
        fi
        len=$(((sz + es - 1) / es * es))
        echo "Erasing $len bytes at offset $off on $mtd ..."
        if ! mtd_debug erase "$mtd" "$off" "$len"; then
            echo "Error: mtd_debug erase failed on $mtd"
            exit 1
        fi
        ;;
    esac

    dd if="$img" of="$dev" seek="$off" bs=1K conv=fsync oflag=seek_bytes
    sync

    # Read the image back and verify.
    if ! dd if="$dev" skip="$off" bs=1K iflag=skip_bytes,count_bytes count="$sz" 2>/dev/null \
        | cmp -n "$sz" - "$img"; then
        echo "Error: flash verification FAILED for $img on $dev (offset $off)."
        echo "Do NOT reboot. Retry the installation, or reflash $img to $dev (offset $off)."
        exit 1
    fi
    echo "Flashed and verified $img on $dev at offset $off."
}

FAILED=0

# Flash in boot-chain order: SPL chain first, then the payloads.
if [ "$IS_UEFI" -ne 1 ] && [ -n "$EDK2_DEV" ]; then
    echo "Not booted via UEFI, skipping the EDK2 image."
fi

if [ -n "$BOOTINFO_DEV" ]; then
    flash_one "$SPL_DIR/$BOOTINFO_FILE" "$BOOTINFO_DEV" "$BOOTINFO_OFF"
fi
if [ -n "$FSBL_DEV" ]; then
    flash_one "$SPL_DIR/FSBL.bin" "$FSBL_DEV" "$FSBL_OFF"
fi
if [ -n "$ENV_DEV" ]; then
    flash_one "$SPL_DIR/env.bin" "$ENV_DEV" "$ENV_OFF"
fi
if [ -n "$OPENSBI_DEV" ]; then
    flash_one "$OPENSBI_ITB" "$OPENSBI_DEV" "$OPENSBI_OFF"
fi
if [ -n "$ESOS_DEV" ]; then
    flash_one "$ESOS_ITB" "$ESOS_DEV" "$ESOS_OFF"
fi
if [ -n "$EDK2_DEV" ] && [ "$IS_UEFI" -eq 1 ]; then
    flash_one "$EDK2_ITB" "$EDK2_DEV" "$EDK2_OFF"
fi

if [ "$FAILED" -eq 1 ]; then
    echo "Some firmware components could not be flashed (see warnings above)."
    exit 1
fi

echo "SpacemiT firmware update complete: all images written and verified."
exit 0