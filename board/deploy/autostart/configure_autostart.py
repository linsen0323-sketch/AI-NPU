#!/usr/bin/env python3
"""Install a new SysV service without opening NPU or disturbing current processes."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

PACKAGE = Path(__file__).resolve().parent
RUNTIME = Path('/opt/npu100')
TARGET = Path('/opt/npu100-autostart')
STAGE = Path('/opt/npu100-autostart.installing')
INIT = Path('/etc/init.d/npu100')
LINKS = [Path('/etc/rc%s.d/%s' % (level, name)) for level, name in (
    ('2', 'S99npu100'), ('3', 'S99npu100'), ('4', 'S99npu100'), ('5', 'S99npu100'),
    ('0', 'K01npu100'), ('1', 'K01npu100'), ('6', 'K01npu100'))]
LINK_TARGET = '../init.d/npu100'
SYSV_HASHES = {
    '/etc/inittab': '7f21524e6caeab79462038dc9e592bdaa324bdb8a6ba64e0807cad76cae6c42d',
    '/etc/init.d/rcS': '19ce896144ff4c85b826fe3cd5f940ff5d41ec19b6bb56f2966215da7888c7be',
    '/etc/init.d/rc': 'dc914f7bac4ec44ed39fc95b34d6250d6a8573633b5a7e16f74f0ff533d34312',
}
CONFIG_SHA = '169adac3de2c6b5e16a42e63bec80116a240880ce04a0f350c9d6d857625be73'
MODULE_SHA = '0a47b3ed19ccf3cf1e70bfa62f6918db518f74f20f48f7c8573efd38ef929b30'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def checked(command, cwd=None):
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(map(str, command)) + '\n' + result.stdout + result.stderr)
    return result.stdout


def verify_files(root):
    checked(['sha256sum', '-c', 'files.sha256'], cwd=root)


def owned_init():
    return INIT.is_file() and not INIT.is_symlink() and sha(INIT) == sha(PACKAGE / 'npu100.init')


def check_destinations():
    require(not STAGE.exists() and not STAGE.is_symlink(), 'Existing staging directory preserved: ' + str(STAGE))
    if TARGET.exists() or TARGET.is_symlink():
        require(TARGET.is_dir() and not TARGET.is_symlink(), 'Existing target preserved: ' + str(TARGET))
        require(sha(TARGET / 'files.sha256') == sha(PACKAGE / 'files.sha256'), 'Different installed autostart package preserved')
        verify_files(TARGET)
    if INIT.exists() or INIT.is_symlink():
        require(owned_init(), 'Existing unrelated init script preserved: ' + str(INIT))
    for link in LINKS:
        require(link.parent.is_dir(), 'SysV runlevel directory missing: ' + str(link.parent))
        if link.exists() or link.is_symlink():
            require(link.is_symlink() and os.readlink(link) == LINK_TARGET,
                    'Existing conflicting runlevel entry preserved: ' + str(link))
    for directory in Path('/etc').glob('rc?.d'):
        for entry in directory.glob('*npu100*'):
            require(entry in LINKS and entry.is_symlink() and os.readlink(entry) == LINK_TARGET,
                    'Unrelated NPU startup entry needs review: ' + str(entry))


def check_environment():
    require(platform.release() == '6.12.40-xilinx-g31626ef92ff1', 'Unexpected running kernel')
    require(platform.machine() == 'armv7l', 'Expected ARMv7 board')
    require(sha('/proc/config.gz') == CONFIG_SHA, 'Kernel configuration mismatch')
    require(Path('/proc/1/comm').read_text().strip() == 'init', 'Expected current SysV init')
    for name, expected in SYSV_HASHES.items():
        require(sha(name) == expected, 'SysV startup layout changed; existing files preserved: ' + name)
    verify_files(PACKAGE)
    require(sha(PACKAGE / 'module/unified_npu.ko') == MODULE_SHA, 'Expected board-tested clockfixed driver')
    verify_files(RUNTIME)
    checked(['sh', str(RUNTIME / 'verify_after_boot.sh')])
    python = str(RUNTIME / 'python-runtime/python3')
    checked([python, str(RUNTIME / 'runtime_check.py')])
    checked([python, str(RUNTIME / 'runtime/preflight.py'), '--bundle', '/home/petalinux/npu100_models',
             '--boot-receipt', str(RUNTIME / 'boot.sha256')])
    sys.path.insert(0, str(RUNTIME / 'runtime'))
    from linux_camera import load_config
    config = load_config(RUNTIME / 'camera.json')
    require(config['auto_start'] is False, 'This package preserves preview-only startup; auto_start must remain false')
    require(config['keys_enabled'] is True, 'Physical-key control must remain enabled')
    require(config['device'] == '/dev/unified-npu' and config['socket'] == '/run/npu100/camera.sock',
            'Expected the verified device and camera socket paths')
    require(config['bundle'] == '/home/petalinux/npu100_models', 'Unexpected model bundle path')
    require(config['bridge'] == str(RUNTIME / 'runtime/app/libnpu_camera.so'), 'Unexpected C bridge path')
    require(shutil.which('insmod') is not None, 'insmod is unavailable')
    check_destinations()
    print(json.dumps({'result': 'AUTOSTART_CHECK_PASS', 'startup': 'models_then_camera_preview',
                      'auto_start_inference': False, 'keys_enabled': True,
                      'current_processes_modified': False, 'device_opened': False}, indent=2), flush=True)


def install():
    require(os.geteuid() == 0, 'Use sudo sh install_autostart.sh --install')
    if not TARGET.exists():
        require(shutil.disk_usage(TARGET.parent).free >= 8 * 1024 * 1024, 'Need at least 8 MiB free under /opt')
        STAGE.mkdir(mode=0o755)
        for name in ('service.py', 'npu100.init', 'configure_autostart.py', 'install_autostart.sh',
                     'files.sha256', 'sha256sums', 'readme.md', 'validation.json'):
            shutil.copy2(PACKAGE / name, STAGE / name)
        shutil.copytree(PACKAGE / 'module', STAGE / 'module')
        for name in ('npu100.init', 'install_autostart.sh', 'module/npu_driver_info'):
            (STAGE / name).chmod(0o755)
        verify_files(STAGE)
        STAGE.rename(TARGET)
    if not INIT.exists():
        with INIT.open('xb') as stream:
            stream.write((PACKAGE / 'npu100.init').read_bytes())
        INIT.chmod(0o755)
    created = []
    for link in LINKS:
        if not link.is_symlink():
            link.symlink_to(LINK_TARGET)
            created.append(str(link))
    receipt = {'result': 'AUTOSTART_ENABLED', 'installed_prefix': str(TARGET),
               'enabled_links': [str(link) for link in LINKS], 'new_links': created,
               'enabled_at_epoch': time.time(), 'effective': 'next_boot_or_explicit_start',
               'camera_preview_on_boot': True, 'inference_on_boot': False,
               'current_processes_modified': False, 'boot_files_modified': False,
               'runtime_or_model_files_modified': False}
    (TARGET / 'INSTALL_RECEIPT.json').write_text(json.dumps(receipt, indent=2) + '\n')
    os.sync()
    print(json.dumps(receipt, indent=2), flush=True)


def disable():
    require(os.geteuid() == 0, 'Use sudo sh install_autostart.sh --disable')
    # Validate all ownership before deleting any link; preserve program/logs.
    require(owned_init(), 'Init script changed or absent; no startup links removed')
    for link in LINKS:
        if link.exists() or link.is_symlink():
            require(link.is_symlink() and os.readlink(link) == LINK_TARGET,
                    'Unrelated runlevel entry preserved: ' + str(link))
    removed = []
    for link in LINKS:
        if link.is_symlink():
            link.unlink()
            removed.append(str(link))
    os.sync()
    print(json.dumps({'result': 'AUTOSTART_DISABLED', 'removed_links': removed,
                      'current_processes_modified': False, 'installed_files_preserved': True}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--check-only', action='store_true')
    modes.add_argument('--install', action='store_true')
    modes.add_argument('--disable', action='store_true')
    args = parser.parse_args()
    if args.disable:
        disable()
    else:
        check_environment()
        if args.install:
            install()


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print('AUTOSTART_CONFIG_FAIL: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
