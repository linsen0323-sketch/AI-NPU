#!/usr/bin/env python3
"""Single-owner SysV camera supervisor; no restart, forced kill or PL reload."""
from __future__ import annotations
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time

PREFIX = Path('/opt/npu100-autostart')
RUNTIME = Path('/opt/npu100')
RUN = Path('/run/npu100-service')
LOGDIR = Path('/var/log/npu100')
PROC = Path('/proc')
MODULE_PATH = Path('/sys/module/unified_npu')
DEVICE = Path('/dev/unified-npu')
KERNEL_RELEASE = '6.12.40-xilinx-g31626ef92ff1'
CONFIG_SHA256 = '169adac3de2c6b5e16a42e63bec80116a240880ce04a0f350c9d6d857625be73'
MODULE_SHA256 = '0a47b3ed19ccf3cf1e70bfa62f6918db518f74f20f48f7c8573efd38ef929b30'
START_SECONDS, STOP_SECONDS, BOOT_WAIT_SECONDS = 120, 200, 30
LOG_BYTES, LOG_BACKUPS = 4 * 1024 * 1024, 3


def require(ok, why):
    if not ok:
        raise RuntimeError(why)


def boot_id():
    return (PROC / 'sys/kernel/random/boot_id').read_text().strip()


def process(pid):
    try:
        directory = PROC / str(int(pid))
        fields = (directory / 'stat').read_text().rsplit(') ', 1)[1].split()
        if fields[0] in ('Z', 'X'):
            return None
        return {'pid': int(pid), 'starttime': fields[19],
                'cmdline': [arg.decode('utf-8', 'surrogateescape')
                            for arg in (directory / 'cmdline').read_bytes().split(b'\0') if arg]}
    except (OSError, ValueError, IndexError):
        return None


def identity_alive(identity, check_cmdline=True):
    if not isinstance(identity, dict):
        return False
    current = process(identity.get('pid', 0))
    return current is not None and current['starttime'] == identity.get('starttime') and (
        not check_cmdline or current['cmdline'] == identity.get('cmdline'))


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def atomic_json(path, data):
    temporary = path.with_name(path.name + '.tmp.' + str(os.getpid()))
    with temporary.open('x', encoding='utf-8') as stream:
        os.chmod(temporary, 0o600)
        json.dump(data, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def directories():
    for path in (RUN, LOGDIR):
        require(not path.is_symlink(), 'Service directory is a symlink: ' + str(path))
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(path.is_dir() and path.stat().st_uid == 0,
                'Service directory must be owned by root: ' + str(path))
        os.chmod(path, 0o700)


def managed_state():
    state = read_json(RUN / 'state.json')
    if state.get('boot_id') != boot_id():
        return state, False
    return state, identity_alive(state.get('supervisor'))


def foreign_owners():
    owners = []
    try:
        device_stat = DEVICE.stat()
        device_number = device_stat.st_rdev if stat.S_ISCHR(device_stat.st_mode) else None
    except FileNotFoundError:
        device_number = None
    for entry in PROC.iterdir():
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        info = process(int(entry.name))
        if not info:
            continue
        args = info['cmdline']
        names = {Path(arg).name for arg in args}
        known = ('linux_camera.py' in names and 'serve' in args) or (
            'npu_runtime.py' in names and any(word in args for word in ('daemon', 'run')))
        device_open = False
        if device_number is not None:
            try:
                descriptors = list((entry / 'fd').iterdir())
            except FileNotFoundError:
                continue
            for descriptor in descriptors:
                try:
                    candidate = descriptor.stat()
                    if stat.S_ISCHR(candidate.st_mode) and candidate.st_rdev == device_number:
                        device_open = True
                        break
                except FileNotFoundError:
                    pass
        if known or device_open:
            owners.append({'pid': info['pid'], 'cmdline': args, 'device_open': device_open})
    return owners


def sha_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def check_manifest(root):
    entries = (root / 'files.sha256').read_text('ascii').splitlines()
    require(entries, 'Empty installed-file manifest: ' + str(root))
    for entry in entries:
        require(re.fullmatch(r'[0-9a-f]{64}  [^\r\n]+', entry), 'Invalid file manifest entry')
        expected, name = entry[:64], entry[66:]
        path = root / name
        require(not Path(name).is_absolute() and '..' not in Path(name).parts and
                path.resolve().is_relative_to(root.resolve()), 'Unsafe manifest path: ' + name)
        require(sha_file(path) == expected, 'Installed checksum mismatch: ' + str(path))


class BoundedLog:
    def __init__(self):
        self.path = LOGDIR / 'camera.log'
        require(not self.path.is_symlink(), 'Log path must not be a symlink')
        self.stream = self.path.open('ab', buffering=0)
        os.chmod(self.path, 0o600)

    def rotate(self):
        self.stream.close()
        for index in range(LOG_BACKUPS, 0, -1):
            old = self.path if index == 1 else self.path.with_name('camera.log.' + str(index - 1))
            new = self.path.with_name('camera.log.' + str(index))
            if old.exists():
                os.replace(old, new)
        self.stream = self.path.open('ab', buffering=0)
        os.chmod(self.path, 0o600)

    def write(self, data):
        if isinstance(data, str):
            data = data.encode('utf-8', 'backslashreplace')
        while data:
            room = LOG_BYTES - self.stream.tell()
            if room <= 0:
                self.rotate()
                room = LOG_BYTES
            self.stream.write(data[:room])
            data = data[room:]

    def close(self):
        self.stream.close()


def python_command(*arguments):
    return ['/bin/sh', str(RUNTIME / 'python-runtime/python3'), *map(str, arguments)]


def run_checked(command, log):
    log.write('SERVICE_COMMAND ' + repr(command) + '\n')
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    log.write(result.stdout)
    require(result.returncode == 0, 'Prerequisite failed: ' + repr(command))


def prerequisites(log, stopping):
    deadline = time.monotonic() + BOOT_WAIT_SECONDS
    required = [RUNTIME / 'files.sha256', Path('/boot/image.ub'),
                Path('/home/petalinux/npu100_models/manifest.json')]
    while not all(path.is_file() for path in required):
        require(not stopping(), 'Stopped while waiting for local SD files')
        require(time.monotonic() < deadline, 'Local SD files are unavailable; no hardware was accessed')
        time.sleep(0.25)
    check_manifest(PREFIX)
    check_manifest(RUNTIME)
    require(os.uname().release == KERNEL_RELEASE and os.uname().machine == 'armv7l',
            'Kernel release or architecture mismatch')
    require(sha_file(PROC / 'config.gz') == CONFIG_SHA256, 'Kernel configuration mismatch')
    config = read_json(RUNTIME / 'camera.json')
    require(config.get('auto_start') is False, 'Expected reviewed auto_start=false camera configuration')
    require(config.get('device') == str(DEVICE), 'Camera device path mismatch')
    socket_path = Path(config.get('socket', ''))
    require(socket_path.is_absolute(), 'Camera socket must be absolute')
    require(not socket_path.exists() and not socket_path.is_symlink(),
            'Existing camera socket preserved; inspect manual or failed process first: ' + str(socket_path))
    require(not foreign_owners(), 'Manual process owns camera/NPU; preserved without signals')
    run_checked(['/bin/sh', str(RUNTIME / 'verify_after_boot.sh')], log)
    require(not stopping(), 'Stopped before module handling')
    module = PREFIX / 'module/unified_npu.ko'
    require(sha_file(module) == MODULE_SHA256, 'Expected reviewed CLOCKFIX module')
    if not MODULE_PATH.is_dir():
        require(not DEVICE.exists(), 'Unexpected device already exists without the known module')
        run_checked(['/sbin/insmod', str(module)], log)
        deadline = time.monotonic() + 5
        while not DEVICE.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
    require(DEVICE.exists() and stat.S_ISCHR(DEVICE.stat().st_mode),
            'NPU device is absent after module load; module retained for diagnosis')
    require(not foreign_owners(), 'Another NPU owner appeared; preserved without signals')
    require(not stopping(), 'Stopped before PL verification')
    # Existing reviewed entry point verifies boot receipt, DT and full model
    # bundle before its first INFO/READ operation. Never use a separate loader.
    run_checked(['/bin/sh', str(RUNTIME / 'npu100.sh'), 'check-pl'], log)
    require(not stopping(), 'Stopped before camera launch')
    require(not foreign_owners(), 'Another NPU owner appeared before camera launch')
    socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not socket_path.exists() and not socket_path.is_symlink(), 'Existing socket preserved')
    return config


def supervise():
    directories()
    with (RUN / 'service.lock').open('a+') as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('A supervisor already holds the service lock')
        stopped = False
        child = None
        child_identity = None
        fault = False
        log = BoundedLog()
        state = {'boot_id': boot_id(), 'supervisor': process(os.getpid()), 'stage': 'starting',
                 'log': str(LOGDIR / 'camera.log'), 'hardware_drain_verified': False}

        def save(stage, **more):
            state.update(stage=stage, **more)
            atomic_json(RUN / 'state.json', state)

        def stop_signal(signum, frame):
            nonlocal stopped
            stopped = True
            # The private Python shell launcher execs the ARM loader/Python;
            # child argv can change while PID/starttime remains the same.
            if child is not None and child.poll() is None and identity_alive(child_identity, check_cmdline=False):
                try:
                    os.kill(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

        signal.signal(signal.SIGTERM, stop_signal)
        signal.signal(signal.SIGINT, stop_signal)
        save('starting')
        log.write('\nSERVICE_BOOT ' + state['boot_id'] + '\n')
        try:
            latch = read_json(LOGDIR / 'failure.json')
            require(latch.get('boot_id') != state['boot_id'], 'Failure retained for this boot; inspect logs before recovery')
            prerequisites(log, lambda: stopped)
            command = python_command(RUNTIME / 'runtime/linux_camera.py', '--config', RUNTIME / 'camera.json', 'serve')
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, pass_fds=(lock.fileno(),))
            child_identity = process(child.pid)
            require(child_identity is not None, 'Camera process exited before identity could be recorded')
            save('initializing', child=child_identity)
            if stopped:
                stop_signal(signal.SIGTERM, None)
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            pending = b''
            while selector.get_map():
                for key, mask in selector.select(0.25):
                    chunk = os.read(key.fileobj.fileno(), 16384)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    log.write(chunk)
                    pending += chunk
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        if b'Shutdown retains hardware ownership' in line:
                            fault = True
                        try:
                            event = json.loads(line)
                        except (ValueError, UnicodeDecodeError):
                            continue
                        if isinstance(event, dict) and event.get('event') == 'fault':
                            fault = True
                        if isinstance(event, dict) and event.get('event') == 'ready' and not stopped:
                            save('ready')
                    if len(pending) > 65536:
                        pending = pending[-65536:]
                    if b'Shutdown retains hardware ownership' in pending:
                        fault = True
            selector.close()
            child.stdout.close()
            result = child.wait()
            require(stopped and result == 0 and not fault,
                    'Camera exited unexpectedly or retained a fault; exit=' + str(result))
            save('stopped', child_exit=result,
                 note='Process exited after SIGTERM; no independent hardware drain proof is inferred')
            return 0
        except BaseException as error:
            log.write('SERVICE_FAILURE ' + str(error) + '\n')
            save('failed', error=str(error))
            atomic_json(LOGDIR / 'failure.json', dict(state))
            raise
        finally:
            log.close()


def start():
    directories()
    state, alive = managed_state()
    if alive:
        print(json.dumps({'result': 'ALREADY_MANAGED', 'state': state}))
        return 0
    require(not foreign_owners(), 'A manual camera/NPU process exists; left running without signals')
    require(read_json(LOGDIR / 'failure.json').get('boot_id') != boot_id(),
            'Failure retained for this boot; inspect /var/log/npu100 before recovery')
    # Detached supervisor holds the lock for the whole camera lifetime.
    supervisor = subprocess.Popen(python_command(PREFIX / 'service.py', '_run'),
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + START_SECONDS
    while time.monotonic() < deadline:
        state, alive = managed_state()
        if alive and state.get('stage') == 'ready':
            print(json.dumps({'result': 'SERVICE_READY', 'state': state}))
            return 0
        if state.get('boot_id') == boot_id() and state.get('stage') == 'failed':
            raise RuntimeError('Startup failed: ' + state.get('error', 'see log'))
        if supervisor.poll() is not None:
            # A concurrent starter may own the lock; do not spawn again.
            require(alive, 'Supervisor exited before ready; inspect ' + str(LOGDIR / 'camera.log'))
        time.sleep(0.25)
    raise RuntimeError('Startup remains incomplete; supervisor preserved, no retry: ' + str(LOGDIR / 'camera.log'))


def stop():
    state, alive = managed_state()
    if not alive:
        print(json.dumps({'result': 'NO_MANAGED_PROCESS', 'state': state,
                          'manual_processes': foreign_owners()}))
        return 0
    identity = state['supervisor']
    require(identity_alive(identity), 'Supervisor identity changed; no signal sent')
    os.kill(identity['pid'], signal.SIGTERM)
    deadline = time.monotonic() + STOP_SECONDS
    while identity_alive(identity) and time.monotonic() < deadline:
        time.sleep(0.25)
    require(not identity_alive(identity), 'Stop timed out after 200 seconds; process and hardware preserved, no SIGKILL')
    final = read_json(RUN / 'state.json')
    print(json.dumps({'result': 'SERVICE_PROCESS_EXITED', 'state': final}))
    return 0 if final.get('stage') == 'stopped' else 1


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    require(len(args) == 1 and args[0] in ('start', 'stop', 'status', '_run'),
            'Usage: service.py start|stop|status')
    require(os.geteuid() == 0, 'Run service control as root')
    os.umask(0o077)
    if args[0] == 'start':
        return start()
    if args[0] == 'stop':
        return stop()
    if args[0] == '_run':
        return supervise()
    state, alive = managed_state()
    print(json.dumps({'result': 'SERVICE_STATUS', 'managed_process_alive': alive,
                      'state': state, 'manual_processes': [] if alive else foreign_owners(),
                      'failure': read_json(LOGDIR / 'failure.json')}, indent=2))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print('SERVICE_ERROR: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
