#!/bin/sh
# Checks Linux DT/files only. Never opens /dev/unified-npu or /dev/mem.
set -eu
fail() { echo "ERROR: $*" >&2; exit 1; }
check_hash() {
    printf '%s  %s\n' "$1" "$2" | sha256sum -c - || fail "Hash mismatch: $2"
}
text_property() { tr -d '\000' < "$1"; }
NPU_DT=/sys/firmware/devicetree/base
NPU_RESERVED=$NPU_DT/reserved-memory/npu-runtime@10000000
NPU_DEVICE=$NPU_DT/npu-runtime@43c10000
printf '%s  %s\n' '34a91205a86ce3e2e8809c3ea2b340afdebdbd171bc2ce228040e6a7981981b8' /boot/image.ub | sha256sum -c - || fail 'Boot image hash'
[ "$(uname -r)" = '6.12.40-xilinx-g31626ef92ff1' ] || fail 'Kernel release changed'
check_hash 94039884329d3732c577860f40d0dfdf883ff89dac332f87216e692c08892fa2 "$NPU_DT/memory@0/reg"
check_hash 6147cf8c909b2759b94520f536d9b0e9ee960cbc2925c0664b07e44dea9e93e8 "$NPU_RESERVED/reg"
[ -f "$NPU_RESERVED/no-map" ] || fail 'no-map missing'
[ ! -e "$NPU_RESERVED/reusable" ] || fail 'Reservation must not be reusable'
[ "$(text_property "$NPU_DEVICE/compatible")" = 'local,npu100-runtime-v3' ] || fail 'Runtime DT compatible'
[ "$(text_property "$NPU_DEVICE/status")" = 'okay' ] || fail 'Runtime disabled'
check_hash 895c5c2af7bd82f18442caa11597d24af1f8ee3e9910104e3d7b12fae7c30766 "$NPU_DEVICE/reg"
check_hash 793346c90cf6fad5d0d3c749a9fd9bec3dc8833b4b63ca91c8dca90ff9902889 "$NPU_DEVICE/assigned-clock-rates"
[ ! -e "$NPU_DEVICE/dma-coherent" ] || fail 'Unexpected coherency declaration'
for NPU_OLD_NODE in ai_camera_pipeline_bd@43c10000 gpio@41200000 gpio@41210000; do
    [ "$(text_property "$NPU_DT/pl-bus/$NPU_OLD_NODE/status")" = disabled ] || fail "Old node enabled: $NPU_OLD_NODE"
done
echo 'BOOT_DT_PASS: 256 MiB no-map reservation and npu100 runtime DT node are active.'
echo 'This does not verify loaded PL registers, driver binding, model DDR loading or inference.'
grep -E 'MemTotal|CmaTotal' /proc/meminfo
