#!/bin/sh
# Install a new private userspace prefix. Never changes boot files or drivers.
set -eu
NPU_PACKAGE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$NPU_PACKAGE"
NPU_TARGET=/opt/npu100
NPU_STAGE=/opt/npu100.installing
fail() { echo "ERROR: $*" >&2; exit 1; }
case "${1:-}" in
    --check-only) NPU_INSTALL=no ;;
    --install) NPU_INSTALL=yes ;;
    *) fail 'Usage: sh install_runtime.sh --check-only|--install' ;;
esac
[ "$#" -eq 1 ] || fail 'Unexpected extra arguments'
sha256sum -c sha256sums || fail 'Runtime package checksum mismatch'
[ "$(uname -r)" = 6.12.40-xilinx-g31626ef92ff1 ] || fail 'Unexpected running kernel'
[ "$(uname -m)" = armv7l ] || fail 'Expected ARMv7 board'
printf '%s  %s\n' 169adac3de2c6b5e16a42e63bec80116a240880ce04a0f350c9d6d857625be73 /proc/config.gz | sha256sum -c - || fail 'Kernel configuration mismatch'
sh "$NPU_PACKAGE/verify_after_boot.sh"
[ -d /sys/module/unified_npu ] && [ -c /dev/unified-npu ] || fail 'Load the verified NPU driver first'
[ ! -e "$NPU_TARGET" ] && [ ! -L "$NPU_TARGET" ] || fail "Existing installation preserved: $NPU_TARGET"
[ ! -e "$NPU_STAGE" ] && [ ! -L "$NPU_STAGE" ] || fail "Existing staging directory preserved: $NPU_STAGE"
echo 'USERSPACE_INSTALL_CHECK_OK: package, kernel, boot and loaded driver match.'
[ "$NPU_INSTALL" = yes ] || exit 0
[ "$(id -u)" = 0 ] || fail 'Use sudo sh install_runtime.sh --install'
command -v tar >/dev/null 2>&1 || fail 'tar is required to unpack the runtime'
mkdir -p /opt
NPU_FREE_KIB=$(df -Pk /opt | awk 'NR == 2 {print $4}')
case "$NPU_FREE_KIB" in ''|*[!0-9]*) fail 'Cannot determine /opt free space' ;; esac
[ "$NPU_FREE_KIB" -ge 131072 ] || fail 'Need at least 128 MiB free under /opt'
mkdir "$NPU_STAGE"
tar -xzf "$NPU_PACKAGE/../../linux/userspace/linux_userspace.tar.gz" -C "$NPU_STAGE"
(cd "$NPU_STAGE" && sha256sum -c files.sha256 >/dev/null) || fail 'Extracted file checksum mismatch; staging preserved'
sh "$NPU_STAGE/python-runtime/python3" "$NPU_STAGE/runtime_check.py"
mv "$NPU_STAGE" "$NPU_TARGET"
echo "USERSPACE_INSTALL_PASS: $NPU_TARGET"
echo "Next: sudo $NPU_TARGET/npu100.sh check-pl"
echo 'No boot files, kernel modules, startup services, PL registers or DDR were changed.'
