#!/bin/sh
# Private versioned runtime; no hardware activity unless explicitly selected.
set -eu
NPU_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NPU_PY=$NPU_ROOT/python-runtime/python3
NPU_MODELS=/home/petalinux/npu100_models
NPU_ACTION=${1:-check}
[ "$#" -eq 0 ] || shift
fail() { echo "ERROR: $*" >&2; exit 1; }
check_files() {
    (cd "$NPU_ROOT" && sha256sum -c files.sha256 >/dev/null) || fail 'Installed runtime checksum mismatch'
    [ "$(uname -r)" = 6.12.40-xilinx-g31626ef92ff1 ] || fail 'Unexpected running kernel'
    sh "$NPU_ROOT/verify_after_boot.sh"
    [ -d /sys/module/unified_npu ] && [ -c /dev/unified-npu ] || fail 'NPU driver is not loaded'
    "$NPU_PY" "$NPU_ROOT/runtime_check.py"
    "$NPU_PY" "$NPU_ROOT/runtime/preflight.py" --bundle "$NPU_MODELS" --device /dev/unified-npu --boot-receipt "$NPU_ROOT/boot.sha256"
}
need_root() { [ "$(id -u)" = 0 ] || fail 'Run this command with sudo'; }
case "$NPU_ACTION" in
    check)
        [ "$#" -eq 0 ] || fail 'Usage: npu100.sh check'
        check_files
        echo 'USERSPACE_CHECK_PASS: Python, bridge, bundle and boot contracts checked; no device opened.'
        ;;
    check-pl)
        [ "$#" -eq 0 ] || fail 'Usage: sudo npu100.sh check-pl'
        need_root
        check_files
        exec "$NPU_PY" "$NPU_ROOT/runtime/validate_pl.py" --bundle "$NPU_MODELS" --boot-contract-checked
        ;;
    load-models)
        [ "$#" -eq 0 ] || fail 'Usage: sudo npu100.sh load-models'
        need_root
        check_files
        exec "$NPU_PY" "$NPU_ROOT/load_models_once.py" --bundle "$NPU_MODELS" --load-models --boot-contract-checked
        ;;
    *) fail 'Supported commands: check, check-pl, load-models' ;;
esac
