#!/usr/bin/env python3
"""Verify the private Python/C runtime without opening any hardware device."""
import ctypes
import fcntl
import hashlib
import json
import math
import mmap
from pathlib import Path
import socket
import struct
import sys
import threading
import time
import zlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'runtime'))
import manifest
import npu_runtime
import preflight
from linux_camera import Bridge, load_config


def main():
    assert sys.version_info >= (3, 9)
    assert struct.calcsize('P') == 4, 'Expected 32-bit ARM Python'
    assert hashlib.sha256(b'abc').hexdigest() == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    assert zlib.decompress(zlib.compress(b'npu100')) == b'npu100'
    config = load_config(HERE / 'camera.json')
    for model in (1, 3, 4):
        bridge = Bridge(HERE / 'runtime/app/libnpu_camera.so', model, config['display'])
        bridge.close()
    print(json.dumps({'result': 'USERSPACE_RUNTIME_PASS', 'python': sys.version,
                      'pointer_bits': 32, 'bridge_models': [1, 3, 4],
                      'hardware_opened': False, 'models_loaded': False}, indent=2))


if __name__ == '__main__':
    main()
