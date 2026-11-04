#!/usr/bin/env python3
"""Isolated real checksum/copy/link tests; system paths and read-check calls mocked."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / 'board/deploy/autostart'
PRODUCTION = ROOT / 'src/software/runtime/linux'

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def snapshot(root):
    output = {}
    for path in sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        if path.is_symlink(): output[name] = ['link', os.readlink(path)]
        elif path.is_file(): output[name] = ['file', digest(path), path.stat().st_mode & 0o777]
        elif path.is_dir(): output[name] = ['dir', path.stat().st_mode & 0o777]
    return output

class Fixture:
    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='npu100_autostart_fixture_')
        self.root = Path(self.temp.name)
        self.package = self.root / 'package'
        self.package.mkdir()
        spec = importlib.util.spec_from_file_location('autostart_fixture_module', EVIDENCE/'configure_autostart.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.commands = []
        self.syncs = []
        def private_path(*parts):
            value = Path(*parts)
            if value.is_absolute() and len(value.parts)>1 and value.parts[1] in ('proc','etc','opt'):
                return self.root / str(value).lstrip('/')
            return value
        m = self.module
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(patch.object(m, 'Path', private_path))
        m.PACKAGE = self.package
        m.RUNTIME = private_path('/opt/npu100')
        m.TARGET = private_path('/opt/npu100-autostart')
        m.STAGE = private_path('/opt/npu100-autostart.installing')
        m.INIT = private_path('/etc/init.d/npu100')
        m.INIT.parent.mkdir(parents=True)
        m.LINKS = [private_path(str(path)) for path in m.LINKS]
        for path in m.LINKS: path.parent.mkdir(parents=True,exist_ok=True)
        for original in m.SYSV_HASHES:
            target = private_path(original)
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_text('FIXTURE baseline for '+original+'\n')
        m.SYSV_HASHES = {name:digest(private_path(name)) for name in m.SYSV_HASHES}
        config = private_path('/proc/config.gz')
        config.parent.mkdir(parents=True,exist_ok=True)
        config.write_bytes(b'FIXTURE exact kernel config payload')
        m.CONFIG_SHA = digest(config)
        comm = private_path('/proc/1/comm')
        comm.parent.mkdir(parents=True)
        comm.write_text('init\n')
        (self.package/'module').mkdir()
        (self.package/'module/unified_npu.ko').write_bytes(b'FIXTURE module')
        (self.package/'module/npu_driver_info').write_text('FIXTURE info checker\n')
        m.MODULE_SHA = digest(self.package/'module/unified_npu.ko')
        for name in ('npu100.init','configure_autostart.py','install_autostart.sh'):
            shutil.copyfile(EVIDENCE/name,self.package/name)
        for name in ('service.py','readme.md','validation.json'):
            (self.package/name).write_text('FIXTURE package file '+name+'\n')
        sums = ''.join(digest(p)+'  '+str(p.relative_to(self.package))+'\n'
                       for p in sorted(self.package.rglob('*')) if p.is_file())
        (self.package/'files.sha256').write_text(sums)
        (self.package/'sha256sums').write_text(sums)
        (m.RUNTIME/'runtime').mkdir(parents=True)
        for name in ('linux_camera.py','npu_runtime.py','manifest.py'):
            shutil.copyfile(PRODUCTION/name,m.RUNTIME/'runtime'/name)
        camera = json.loads((PRODUCTION/'camera.json').read_text())
        camera['bridge'] = str(m.RUNTIME/'runtime/app/libnpu_camera.so')
        (m.RUNTIME/'camera.json').write_text(json.dumps(camera))
        runtime_sums=''.join(digest(p)+'  '+str(p.relative_to(m.RUNTIME))+'\n'
                             for p in sorted(m.RUNTIME.rglob('*')) if p.is_file())
        (m.RUNTIME/'files.sha256').write_text(runtime_sums)
        self.process = self.root/'current_camera_process_sentinel'
        self.process.write_text('UNCHANGED existing camera process identity\n')
        original_checked = m.checked
        def checked(command,cwd=None):
            self.commands.append(list(map(str,command)))
            if command[0]=='sha256sum': return original_checked(command,cwd)
            allowed = (["sh",str(m.RUNTIME/'verify_after_boot.sh')],
                       [str(m.RUNTIME/'python-runtime/python3'),str(m.RUNTIME/'runtime_check.py')],
                       [str(m.RUNTIME/'python-runtime/python3'),str(m.RUNTIME/'runtime/preflight.py'),
                        '--bundle','/home/petalinux/npu100_models','--boot-receipt',str(m.RUNTIME/'boot.sha256')])
            if command not in allowed: raise AssertionError('Unexpected process operation: '+repr(command))
            return '{"fixture_read_check":"PASS"}\n'
        self.stack.enter_context(patch.object(m,'checked',checked))
        self.stack.enter_context(patch.object(m.platform,'release',lambda:'6.12.40-xilinx-g31626ef92ff1'))
        self.stack.enter_context(patch.object(m.platform,'machine',lambda:'armv7l'))
        self.stack.enter_context(patch.object(m.os,'geteuid',lambda:0))
        self.stack.enter_context(patch.object(m.os,'sync',lambda:self.syncs.append('sync')))
        self.stack.enter_context(patch.object(m.os,'kill',lambda *args: (_ for _ in ()).throw(AssertionError('kill forbidden'))))
        old_which=m.shutil.which
        self.stack.enter_context(patch.object(m.shutil,'which',lambda command:'/fixture/insmod' if command=='insmod' else old_which(command)))
        return self

    def invoke(self,argument):
        output=io.StringIO()
        with patch.object(sys,'argv',['configure_autostart.py',argument]),contextlib.redirect_stdout(output):
            self.module.main()
        return output.getvalue()

    def __exit__(self,*args):
        self.stack.close()
        self.temp.cleanup()

def main():
    results={}
    with Fixture() as f:
        before=snapshot(f.root)
        out=f.invoke('--check-only')
        assert 'AUTOSTART_CHECK_PASS' in out and snapshot(f.root)==before
        assert not f.syncs and not f.module.INIT.exists() and not f.module.TARGET.exists()
        results['check_only_no_writes_or_process_mutation']={'result':'PASS','commands':f.commands}
    for case in ('sysv_mismatch','unrelated_init','conflicting_link','unrelated_startup_link'):
        with Fixture() as f:
            m=f.module
            if case=='sysv_mismatch': (f.root/'etc/inittab').write_text('changed init contract\n')
            elif case=='unrelated_init': m.INIT.write_text('unrelated init script\n')
            elif case=='conflicting_link': m.LINKS[0].symlink_to('../init.d/unrelated')
            else: (m.LINKS[0].parent/'S98npu100_other').symlink_to('../init.d/unrelated')
            before=snapshot(f.root)
            try: f.invoke('--install')
            except RuntimeError as exc: rejection=str(exc)
            else: raise AssertionError('Expected refusal: '+case)
            assert snapshot(f.root)==before and not f.syncs and not m.TARGET.exists() and not m.STAGE.exists()
            results[case]={'result':'PASS','rejection':rejection}
    with Fixture() as f:
        m=f.module
        sentinel=f.process.read_bytes()
        out=f.invoke('--install')
        assert 'AUTOSTART_ENABLED' in out and not m.STAGE.exists()
        assert m.INIT.read_bytes()==(f.package/'npu100.init').read_bytes()
        actual=[path for directory in (f.root/'etc').glob('rc?.d') for path in directory.iterdir()]
        assert set(actual)==set(m.LINKS) and len(actual)==7
        assert all(path.is_symlink() and os.readlink(path)==m.LINK_TARGET for path in actual)
        assert f.process.read_bytes()==sentinel
        results['install_creates_exactly_seven_owned_links']={'result':'PASS','links':[str(p.relative_to(f.root)) for p in actual]}
        before=snapshot(f.root)
        out=f.invoke('--install')
        receipt=json.loads((m.TARGET/'INSTALL_RECEIPT.json').read_text())
        assert receipt['new_links']==[] and 'AUTOSTART_ENABLED' in out
        after=snapshot(f.root)
        receipt_key=str((m.TARGET/'INSTALL_RECEIPT.json').relative_to(f.root))
        assert {k:v for k,v in before.items() if k!=receipt_key}=={k:v for k,v in after.items() if k!=receipt_key}
        results['idempotent_install_only_refreshes_receipt']={'result':'PASS'}
        unrelated=m.LINKS[0].parent/'S98unrelated'
        unrelated.symlink_to('../init.d/unrelated')
        target_before=snapshot(m.TARGET)
        init_before=m.INIT.read_bytes()
        out=f.invoke('--disable')
        assert 'AUTOSTART_DISABLED' in out and all(not p.is_symlink() and not p.exists() for p in m.LINKS)
        assert unrelated.is_symlink() and os.readlink(unrelated)=='../init.d/unrelated'
        assert snapshot(m.TARGET)==target_before and m.INIT.read_bytes()==init_before
        assert f.process.read_bytes()==sentinel
        results['disable_only_owned_links_preserves_files_and_process']={'result':'PASS'}
    syntax={}
    for name in ('install_autostart.sh','npu100.init'):
        r=subprocess.run(['sh','-n',str(EVIDENCE/name)],capture_output=True,text=True)
        assert r.returncode==0,r.stderr
        syntax[name]='PASS'
    report={'scope':'LOCAL_PRIVATE_FILESYSTEM_REAL_CHECKSUM_COPY_LINK_LOGIC_NO_BOARD_ACCESS',
            'result':'PASS','cases':results,'shell_syntax':syntax,
            'mocked_inputs':['system_path_constants_and_Path_factory','kernel_machine_identity',
                             'fixture_config_sysv_module_hash_constants','root_uid','os.sync',
                             'insmod_presence','three_runtime_readonly_check_commands'],
            'real_driver_or_process_operations':False,'real_system_files_modified':False,
            'source_files_modified':False}
    (ROOT/'evidence/linux/packaging/autostart_install.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'result':'PASS','cases':list(results),'shell_syntax':syntax}))

if __name__=='__main__':main()
