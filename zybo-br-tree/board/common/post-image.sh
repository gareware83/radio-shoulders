#!/usr/bin/env bash
#
# Post-image: build the FIT image, then the U-Boot boot script.
#
# Called by Buildroot as:  post-image.sh <BINARIES_DIR> <dtb> [bitstream]
# where the arguments after BINARIES_DIR come from BR2_ROOTFS_POST_SCRIPT_ARGS.

set -euo pipefail

cd "$1"
shift

EXT="$BR2_EXTERNAL_ZYBO_Z7_PATH"

# --- FIT image (kernel + dtb + ramdisk + bitstream) ----------------------
"$EXT/board/common/mkfit.py" fit.its "$@"
mkimage -f fit.its fit.itb

# --- Boot script ---------------------------------------------------------
# boot.scr USED TO BE BUILT BY HAND, and drifted out of sync with the FIT as a
# result: boot.cmd asked for a configuration name the image no longer contained.
# U-Boot then failed that bootm, fell through to a bare bootm, and silently
# booted the FIT's DEFAULT configuration - the ramdisk one. The board came up
# perfectly healthy and quietly discarded every change written to it, because
# root was a ramdisk rather than mmcblk0p2. Generating it here removes the drift.
#
# Each board keeps its boot.cmd beside its .dts, so the right one is derived
# from the dtb argument rather than hardcoded.
DTB="$1"
DTB_BASE="$(basename "$DTB" .dtb)"

BOOT_CMD=""
for d in "$EXT"/board/*/; do
    if [ -f "$d/$DTB_BASE.dts" ] && [ -f "$d/boot.cmd" ]; then
        BOOT_CMD="$d/boot.cmd"
        break
    fi
done

if [ -z "$BOOT_CMD" ]; then
    echo "post-image: no boot.cmd found next to $DTB_BASE.dts - skipping boot.scr" >&2
    exit 0
fi

# Verify the configuration boot.cmd asks for actually exists in the image we
# just built. This is the check whose absence caused the drift above: a
# mismatch is invisible until U-Boot silently boots something else.
WANT="$(sed -n 's/.*bootm[^#]*#\([A-Za-z0-9_-]*\).*/\1/p' "$BOOT_CMD" | head -1)"
if [ -n "$WANT" ]; then
    if ! grep -qE "^[[:space:]]*$WANT[[:space:]]*\{" fit.its; then
        echo "==============================================================" >&2
        echo "post-image: FATAL - boot.cmd requests configuration '$WANT'"   >&2
        echo "            but fit.its does not contain it."                  >&2
        echo "  available:"                                                  >&2
        grep -oE "^[[:space:]]*conf-[A-Za-z0-9_-]*" fit.its | tr -d ' ' | sed 's/^/    /' >&2
        echo "  mkfit.py derives names from the DTB FILENAME, so this"       >&2
        echo "  tracks BR2_ROOTFS_POST_SCRIPT_ARGS, not the board name."     >&2
        echo "  Left unfixed, U-Boot falls back to the DEFAULT config"       >&2
        echo "  (ramdisk root) and the board boots with a throwaway rootfs." >&2
        echo "==============================================================" >&2
        exit 1
    fi
fi

mkimage -A arm -T script -C none -n "Boot script ($DTB_BASE)" \
        -d "$BOOT_CMD" boot.scr

echo "post-image: fit.itb and boot.scr built (config: ${WANT:-default})"
