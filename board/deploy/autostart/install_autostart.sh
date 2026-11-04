#!/bin/sh
# Enable the next boot only; preserve the current manually running camera.
set -eu
NPU_PACKAGE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$NPU_PACKAGE"
case "${1:-}" in
    --check-only|--install|--disable) ;;
    *) echo 'Usage: sh install_autostart.sh --check-only|--install|--disable' >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo 'ERROR: Unexpected extra arguments' >&2; exit 2; }
sha256sum -c sha256sums || { echo 'ERROR: Autostart package checksum mismatch' >&2; exit 1; }
NPU_PY=/opt/npu100/python-runtime/python3
[ -x "$NPU_PY" ] || { echo 'ERROR: Install the verified Linux runtime first' >&2; exit 1; }
exec "$NPU_PY" "$NPU_PACKAGE/configure_autostart.py" "$1"
