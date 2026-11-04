#!/bin/sh
# Driver-only package. Default checks are read-only and do not open the device.
# --load uses insmod once, then INFO ioctls only; it never accesses PL MMIO/DDR.
set -eu
NPU_PACKAGE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$NPU_PACKAGE"
case "${1:-}" in
    ''|--check-only) NPU_LOAD=no ;;
    --load) NPU_LOAD=yes ;;
    *) echo 'Usage: sh check_driver.sh [--check-only|--load]' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'ERROR: Unexpected extra arguments' >&2; exit 2; }
fail() { echo "ERROR: $*" >&2; exit 1; }
check_hash() {
    printf '%s  %s\n' "$1" "$2" | sha256sum -c - || fail "Hash mismatch: $2"
}
text_property() { tr -d '\000' < "$1"; }
show_kernel_log() {
    echo 'Recent kernel log follows; preserve this output before retrying.' >&2
    dmesg | tail -n 60 >&2 || :
}
sha256sum -c sha256sums || fail 'Driver package checksum failed'
[ "$(uname -r)" = '6.12.40-xilinx-g31626ef92ff1' ] || fail 'Unexpected running kernel'
[ "$(uname -m)" = armv7l ] || fail 'Expected ARMv7 board'
check_hash 169adac3de2c6b5e16a42e63bec80116a240880ce04a0f350c9d6d857625be73 /proc/config.gz
check_hash 4707115527d5e730a4d5baff031fc5e59fa0706c1328b79c6483682ba1d13bf7 /boot/BOOT.BIN
check_hash 4c7ed60cad10872084bf727b2c9ab0eca9eab992635cf3abf67dfe7ed9cc7807 /boot/boot.scr
check_hash 34a91205a86ce3e2e8809c3ea2b340afdebdbd171bc2ce228040e6a7981981b8 /boot/image.ub
NPU_DT=/sys/firmware/devicetree/base
NPU_RESERVED=$NPU_DT/reserved-memory/npu-runtime@10000000
NPU_DEVICE=$NPU_DT/npu-runtime@43c10000
check_hash 94039884329d3732c577860f40d0dfdf883ff89dac332f87216e692c08892fa2 "$NPU_DT/memory@0/reg"
check_hash 6147cf8c909b2759b94520f536d9b0e9ee960cbc2925c0664b07e44dea9e93e8 "$NPU_RESERVED/reg"
[ -f "$NPU_RESERVED/no-map" ] || fail 'no-map missing'
[ ! -e "$NPU_RESERVED/reusable" ] || fail 'Reservation must not be reusable'
[ "$(text_property "$NPU_DEVICE/compatible")" = 'local,npu100-runtime-v3' ] || fail 'Runtime DT compatible'
[ "$(text_property "$NPU_DEVICE/status")" = okay ] || fail 'Runtime disabled'
check_hash 895c5c2af7bd82f18442caa11597d24af1f8ee3e9910104e3d7b12fae7c30766 "$NPU_DEVICE/reg"
check_hash 793346c90cf6fad5d0d3c749a9fd9bec3dc8833b4b63ca91c8dca90ff9902889 "$NPU_DEVICE/assigned-clock-rates"
[ ! -e "$NPU_DEVICE/dma-coherent" ] || fail 'Unexpected coherency declaration'
for NPU_OLD_NODE in ai_camera_pipeline_bd@43c10000 gpio@41200000 gpio@41210000; do
    [ "$(text_property "$NPU_DT/pl-bus/$NPU_OLD_NODE/status")" = disabled ] || fail "Old node enabled: $NPU_OLD_NODE"
done
echo 'DRIVER_CHECK_OK: package, kernel configuration, boot files and live DT match.'
if [ "$NPU_LOAD" = no ]; then
    echo 'CHECK_ONLY: no module loaded, device opened, PL MMIO or DDR accessed.'
    exit 0
fi
[ "$(id -u)" = 0 ] || fail 'Use sudo sh check_driver.sh --load'
command -v insmod >/dev/null 2>&1 || fail 'insmod is unavailable'
[ -x "$NPU_PACKAGE/npu_driver_info" ] || fail 'Run chmod +x npu_driver_info before --load'
[ ! -d /sys/module/unified_npu ] || fail 'Module is already loaded; preserved without reload. Run sudo ./npu_driver_info to recheck INFO only.'
[ ! -e /dev/unified-npu ] || fail 'Existing device preserved; inspect its owner before loading'
if ! insmod "$NPU_PACKAGE/unified_npu.ko"; then
    show_kernel_log
    fail 'Module load failed; no forced retry or unload was attempted'
fi
if [ ! -c /dev/unified-npu ]; then
    show_kernel_log
    fail 'Module loaded but device node absent; module preserved for diagnosis'
fi
if ! "$NPU_PACKAGE/npu_driver_info"; then
    show_kernel_log
    fail 'INFO verification failed; module preserved for diagnosis'
fi
echo 'DRIVER_LOAD_PASS: module and INFO metadata verified; module remains loaded.'
echo 'No automatic startup, reboot, FPGA configuration, PL MMIO or model DDR load occurred.'
