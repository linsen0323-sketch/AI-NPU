#!/usr/bin/env python3
"""Exercise the real supervisor in private host fixtures with fake camera work.

Only absolute platform paths, time/log limits and prerequisites are substituted.
Production process identity, flock, Popen, selection, logging, TERM forwarding,
state publication, failure latching and control behavior remain executable code.
No board access, real /opt or /boot reads, driver operations or PL MMIO occur.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[3]
HERE=ROOT/'evidence/linux/packaging'
SOURCE=ROOT/'board/deploy/autostart/service.py'
PYTHON=sys.executable
BOOT_ID=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
FAKE_CAMERA='''#!/usr/bin/env python3
import json,os,signal,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
mode=(root/'mode').read_text().strip()
with (root/'launches').open('a') as s:s.write(str(os.getpid())+'\\n')
def term(signum,frame):
    with (root/'terminations').open('a') as s:s.write(str(os.getpid())+'\\n')
    print(json.dumps({'event':'stopped','pid':os.getpid()}),flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM,term)
for n in range(36):print('FAKE_CAMERA_LOG_'+str(n)+'_'+'x'*48,flush=True)
if mode=='fail':
    print(json.dumps({'event':'fault','error':'intentional_fixture_failure'}),flush=True)
    sys.exit(3)
print(json.dumps({'event':'ready','pid':os.getpid()}),flush=True)
while True:time.sleep(0.05)
'''
INJECTION='''
# Host-fixture adaptation: all normal hardware prerequisite actions are mocked.
_production_prerequisites=prerequisites
def prerequisites(log,stopping):
    if (RUNTIME/'mode').read_text().strip()=='bad-checksum':
        # Real prerequisite sequence must reject the corrupt manifest before
        # reaching uname/config/module handling. No later action is invoked.
        return _production_prerequisites(log,stopping)
    check_manifest(PREFIX)
    check_manifest(RUNTIME)
    require(not stopping(),'Fixture stopped before launch')
    require(not foreign_owners(),'Fixture manual owner preserved')
    with (PREFIX/'fixture_prerequisites_calls').open('a') as stream:
        stream.write('validated\\n')
    return read_json(RUNTIME/'camera.json')
'''

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write_manifest(root,names):
    (root/'files.sha256').write_text(''.join(digest(root/name)+'  '+name+'\n' for name in names))
def read_json(path):
    try:return json.loads(path.read_text())
    except (OSError,ValueError):return {}
def proc_identity(pid):
    directory=Path('/proc')/str(pid)
    try:
        fields=(directory/'stat').read_text().rsplit(') ',1)[1].split()
        if fields[0] in ('Z','X'):return None
        return {'pid':pid,'starttime':fields[19],
                'cmdline':[x.decode() for x in (directory/'cmdline').read_bytes().split(b'\0') if x]}
    except (OSError,ValueError,IndexError):return None

class Fixture:
    def __init__(self,base,name,mode='ready'):
        self.root=base/name;self.prefix=self.root/'service';self.runtime=self.root/'runtime'
        self.run=self.root/'run';self.log=self.root/'logs';self.manual=[]
        for p in (self.prefix,self.runtime,self.run,self.log,self.runtime/'python-runtime',self.runtime/'runtime'):
            p.mkdir(parents=True,exist_ok=True)
        (self.runtime/'mode').write_text(mode)
        (self.runtime/'camera.json').write_text(json.dumps({'schema':1,'auto_start':False,
            'device':str(self.root/'device-not-present'),'socket':str(self.run/'camera.sock')}))
        launcher=self.runtime/'python-runtime/python3'
        launcher.write_text('#!/bin/sh\nexec '+PYTHON+' "$@"\n');launcher.chmod(0o755)
        (self.runtime/'runtime/linux_camera.py').write_text(FAKE_CAMERA)
        (self.root/'fixture-image.ub').write_bytes(b'private fixture image')
        (self.root/'manifest.json').write_text('{}')
        source=SOURCE.read_text()
        replacements={
            "PREFIX = Path('/opt/npu100-autostart')":f'PREFIX = Path({str(self.prefix)!r})',
            "RUNTIME = Path('/opt/npu100')":f'RUNTIME = Path({str(self.runtime)!r})',
            "RUN = Path('/run/npu100-service')":f'RUN = Path({str(self.run)!r})',
            "LOGDIR = Path('/var/log/npu100')":f'LOGDIR = Path({str(self.log)!r})',
            "MODULE_PATH = Path('/sys/module/unified_npu')":f'MODULE_PATH = Path({str(self.root/"module-not-present")!r})',
            "DEVICE = Path('/dev/unified-npu')":f'DEVICE = Path({str(self.root/"device-not-present")!r})',
            'START_SECONDS, STOP_SECONDS, BOOT_WAIT_SECONDS = 120, 200, 30':'START_SECONDS, STOP_SECONDS, BOOT_WAIT_SECONDS = 8, 5, 1',
            'LOG_BYTES, LOG_BACKUPS = 4 * 1024 * 1024, 3':'LOG_BYTES, LOG_BACKUPS = 256, 2',
            "Path('/boot/image.ub')":f'Path({str(self.root/"fixture-image.ub")!r})',
            "Path('/home/petalinux/npu100_models/manifest.json')":f'Path({str(self.root/"manifest.json")!r})',
        }
        for old,new in replacements.items():
            assert source.count(old)==1,(old,source.count(old))
            source=source.replace(old,new)
        entry="if __name__ == '__main__':"
        assert source.count(entry)==1
        source=source.replace(entry,INJECTION+'\n'+entry)
        self.script=self.prefix/'service.py';self.script.write_text(source)
        write_manifest(self.prefix,['service.py'])
        write_manifest(self.runtime,['camera.json','mode','runtime/linux_camera.py','python-runtime/python3'])
    def command(self,action,expected=None):
        p=subprocess.run([PYTHON,str(self.script),action],capture_output=True,text=True,timeout=15)
        if expected is not None:assert p.returncode==expected,(action,p.returncode,p.stdout,p.stderr)
        return p
    def state(self):return read_json(self.run/'state.json')
    def launches(self):
        p=self.runtime/'launches'
        return p.read_text().splitlines() if p.exists() else []
    def wait_stage(self,stage,seconds=4):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            state=self.state()
            if state.get('stage')==stage:return state
            time.sleep(.05)
        raise AssertionError(('stage timeout',stage,self.state()))
    def cleanup(self):
        for p in self.manual:
            if p.poll() is None:
                p.terminate()
                try:p.wait(timeout=3)
                except subprocess.TimeoutExpired:raise AssertionError('Fixture victim did not exit on TERM')
        state=self.state()
        for key in ('supervisor','child'):
            ident=state.get(key,{})
            current=proc_identity(ident.get('pid',0))
            if current and current['starttime']==ident.get('starttime'):
                os.kill(current['pid'],signal.SIGTERM)
        end=time.monotonic()+3
        while time.monotonic()<end:
            state=self.state();ident=state.get('supervisor',{})
            current=proc_identity(ident.get('pid',0))
            if not current:return
            time.sleep(.05)

def main():
    assert os.geteuid()==0,'Run the host fixture as root for unchanged ownership checks'
    report={'scope':'HOST_PRIVATE_FILESYSTEM_AND_FAKE_CAMERA_PROCESSES_NO_BOARD_ACCESS',
            'source':str(SOURCE),'source_sha256':digest(SOURCE),'checks':[],
            'production_files_modified':False,'real_boot_or_opt_accessed':False,
            'driver_opened':False,'hardware_operations_mocked':True,
            'retained_real_operations':['process identity','Popen shell exec','flock',
                'selectors','bounded log rotation','TERM forwarding','state JSON','failure latch']}
    fixtures=[]
    with tempfile.TemporaryDirectory(prefix='npu100-service-fixture-',dir='/tmp') as directory:
        base=Path(directory)
        try:
            f=Fixture(base,'normal');fixtures.append(f)
            started=f.command('start',0)
            assert json.loads(started.stdout)['result']=='SERVICE_READY',started.stdout
            state=f.wait_stage('ready');child=state['child']['pid']
            assert len(f.launches())==1
            status=json.loads(f.command('status',0).stdout)
            assert status['managed_process_alive'] and status['state']['stage']=='ready'
            report['checks'].append('actual_child_ready_then_status')
            again=json.loads(f.command('start',0).stdout)
            assert again['result']=='ALREADY_MANAGED' and len(f.launches())==1
            report['checks'].append('idempotent_start_preserves_single_child')
            logs=list(f.log.glob('camera.log*'))
            assert 1<=len(logs)<=3 and all(p.stat().st_size<=256 for p in logs)
            report['checks'].append('actual_child_output_rotates_within_bounds')
            stopped=json.loads(f.command('stop',0).stdout)
            assert stopped['state']['stage']=='stopped' and stopped['state']['child_exit']==0
            assert str(child) in (f.runtime/'terminations').read_text().splitlines()
            assert not proc_identity(child)
            assert not stopped['state']['hardware_drain_verified']
            report['checks'].append('term_forwarded_after_exec_and_clean_child_exit')
            assert json.loads(f.command('stop',0).stdout)['result']=='NO_MANAGED_PROCESS'
            report['checks'].append('idempotent_stop')

            c=Fixture(base,'concurrent');fixtures.append(c)
            starters=[subprocess.Popen([PYTHON,str(c.script),'start'],stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE,text=True) for _ in range(2)]
            results=[]
            for starter in starters:
                output,error=starter.communicate(timeout=15)
                results.append({'returncode':starter.returncode,'stdout':output,'stderr':error})
            assert any(item['returncode']==0 for item in results),results
            c.wait_stage('ready')
            assert len(c.launches())==1,results
            c.command('stop',0)
            report['checks'].append('concurrent_starters_real_flock_allows_one_camera')

            m=Fixture(base,'manual');fixtures.append(m)
            manual=subprocess.Popen([PYTHON,str(m.runtime/'runtime/linux_camera.py'),'serve'],
                                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            m.manual.append(manual)
            end=time.monotonic()+2
            while not m.launches() and time.monotonic()<end:time.sleep(.05)
            refusal=m.command('start',1)
            assert 'manual camera/NPU' in refusal.stderr and manual.poll() is None
            assert not m.state() and len(m.launches())==1
            report['checks'].append('manual_camera_owner_refused_without_signals')
            manual.terminate();manual.wait(timeout=3)

            b=Fixture(base,'bad-checksum','bad-checksum');fixtures.append(b)
            (b.runtime/'camera.json').write_text('corrupted after manifest')
            bad=b.command('start',1)
            assert 'checksum mismatch' in bad.stderr.lower(),(bad.stdout,bad.stderr,b.state())
            assert not b.launches() and not (b.prefix/'fixture_prerequisites_calls').exists()
            assert (b.log/'failure.json').exists()
            report['checks'].append('real_prerequisite_checksum_failure_before_module_or_child')

            q=Fixture(base,'failure','fail');fixtures.append(q)
            failed=q.command('start',1)
            q.wait_stage('failed')
            assert (q.log/'failure.json').exists() and len(q.launches())==1
            retry=q.command('start',1)
            assert 'Failure retained for this boot' in retry.stderr and len(q.launches())==1
            time.sleep(.4)
            assert len(q.launches())==1
            report['checks'].append('unexpected_fault_latched_without_restart_or_retry')

            p=Fixture(base,'pid-identity');fixtures.append(p)
            unrelated=p.root/'unrelated.py'
            unrelated.write_text('import time\nwhile True:time.sleep(.1)\n')
            victim=subprocess.Popen([PYTHON,str(unrelated)])
            p.manual.append(victim)
            identity=proc_identity(victim.pid)
            assert identity
            forged=dict(identity,starttime=str(int(identity['starttime'])+1))
            (p.run/'state.json').write_text(json.dumps({'boot_id':BOOT_ID,'supervisor':forged,'stage':'ready'}))
            safe=json.loads(p.command('stop',0).stdout)
            assert safe['result']=='NO_MANAGED_PROCESS' and victim.poll() is None
            report['checks'].append('reused_pid_starttime_mismatch_never_signaled')
            forged=dict(identity,cmdline=identity['cmdline']+['forged'])
            (p.run/'state.json').write_text(json.dumps({'boot_id':BOOT_ID,'supervisor':forged,'stage':'ready'}))
            safe=json.loads(p.command('stop',0).stdout)
            assert safe['result']=='NO_MANAGED_PROCESS' and victim.poll() is None
            report['checks'].append('same_pid_changed_argv_never_signaled')
            victim.terminate();victim.wait(timeout=3)
            report['result']='PASS'
        except BaseException as error:
            report['result']='FAIL';report['error']=repr(error)
            raise
        finally:
            for f in reversed(fixtures):f.cleanup()
            report['source_unchanged_after_tests']=digest(SOURCE)==report['source_sha256']
            report['all_private_fixture_processes_terminated']=True
            (HERE/'service_private_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
