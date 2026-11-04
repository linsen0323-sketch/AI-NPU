#!/bin/sh
# Build source only; no installation, boot writes, driver load or board access.
set -eu
NPU_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
: "${KERNEL_SRC:?Set KERNEL_SRC to the exact linux-xlnx source tree}"
: "${KERNEL_OUT:?Set KERNEL_OUT to its prepared build output}"
NPU_CROSS=${CROSS_COMPILE:-arm-linux-gnueabihf-}
NPU_CC=${CC:-${NPU_CROSS}gcc}
[ -f "$KERNEL_OUT/Module.symvers" ] || { echo 'Build the matching configured kernel first (MODVERSIONS)' >&2; exit 1; }
make -C "$KERNEL_SRC" O="$KERNEL_OUT" ARCH=arm CROSS_COMPILE="$NPU_CROSS" CC="$NPU_CC" M="$NPU_REPO/src/software/runtime/linux/driver" modules
make -C "$NPU_REPO/src/software/runtime/linux/app" CC="$NPU_CC"
mkdir -p "$NPU_REPO/build/output/linux"
"$NPU_CC" -O2 -Wall -Wextra -Werror -I"$NPU_REPO/board/linux/driver" "$NPU_REPO/board/linux/driver/npu_driver_info.c" -o "$NPU_REPO/build/output/linux/npu_driver_info"
printf '%s
' 'Built source artifacts only. Frozen board binaries were not replaced.'
