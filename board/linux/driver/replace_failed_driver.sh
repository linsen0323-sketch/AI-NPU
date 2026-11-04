#!/bin/sh
# Only replace a loaded module whose probe failed and owns no device/reference.
# No forced unload, PL MMIO/DDR, boot-file writes, FPGA reload or reboot.
set -eu
NPU_PACKAGE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$NPU_PACKAGE"
fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$#" -eq 0 ] || fail 'Usage: sudo sh replace_failed_driver.sh'
sh "$NPU_PACKAGE/check_driver.sh" --check-only || fail 'Package preflight failed; loaded module preserved'
[ "$(id -u)" = 0 ] || fail 'Use sudo sh replace_failed_driver.sh'
no_owned_device() {
    [ ! -e /sys/class/misc/unified-npu ] && [ ! -L /sys/class/misc/unified-npu ] || fail 'Misc device exists; preserve a successfully bound or active driver'
    [ ! -e /dev/unified-npu ] && [ ! -L /dev/unified-npu ] || fail 'Device node or symlink exists; preserve driver for diagnosis'
    for NPU_ENTRY in /sys/bus/platform/drivers/unified-npu/*; do
        [ -L "$NPU_ENTRY" ] || continue
        [ "$NPU_ENTRY" = /sys/bus/platform/drivers/unified-npu/module ] && continue
        fail "Bound platform device or unexpected driver symlink exists: $NPU_ENTRY"
    done
}
no_owned_device
if [ -d /sys/module/unified_npu ]; then
    [ -f /sys/module/unified_npu/refcnt ] || fail 'Module reference count unavailable; refusing unload'
    NPU_REFCNT=$(cat /sys/module/unified_npu/refcnt)
    case "$NPU_REFCNT" in ''|*[!0-9]*) fail 'Invalid module reference count; refusing unload' ;; esac
    [ "$NPU_REFCNT" = 0 ] || fail "Module reference count is $NPU_REFCNT; preserve busy driver"
    command -v rmmod >/dev/null 2>&1 || fail 'rmmod unavailable'
    if ! rmmod unified_npu; then
        dmesg | tail -n 60 >&2 || :
        fail 'Ordinary unload refused; no forced retry attempted'
    fi
    [ ! -d /sys/module/unified_npu ] || fail 'Module still present after unload; refusing replacement'
    echo 'FAILED_PROBE_MODULE_REMOVED: no bound device or module references existed.'
fi
no_owned_device
if ! sh "$NPU_PACKAGE/check_driver.sh" --load; then
    dmesg | tail -n 60 >&2 || :
    fail 'Replacement load/check failed; preserve output and current module state'
fi
echo 'Recent kernel log follows, including the actual acquired FCLK rates.'
dmesg | tail -n 60 || :
echo 'FAILED_DRIVER_REPLACEMENT_PASS: INFO metadata checked; no PL MMIO or DDR access.'
