#!/usr/bin/env python3
"""Validate the packaged ARM runtime privately; never opens a hardware device."""
import argparse, hashlib, json, os, subprocess, tarfile, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--archive',type=Path,default=ROOT/'board/linux/userspace/linux_userspace.tar.gz')
    ap.add_argument('--qemu',type=Path)
    ap.add_argument('--receipt',type=Path,default=ROOT/'evidence/linux/packaging/userspace_validation.json')
    ap.add_argument('--sysroot',type=Path)
    ap.add_argument('--bundle',type=Path,default=ROOT/'data/models/runtime/bundle')
    args=ap.parse_args()
    report={'scope':'PRIVATE_ARCHIVE_CHECKS_OPTIONAL_QEMU_ARM_NO_BOARD_ACCESS','archive_sha256':hashlib.sha256(args.archive.read_bytes()).hexdigest(),'hardware_opened':False,'qemu':False}
    with tempfile.TemporaryDirectory(prefix='npu100_package_verify_') as tmp:
        target=Path(tmp)
        with tarfile.open(args.archive) as bundle:
            for member in bundle.getmembers():
                path=Path(member.name)
                assert not path.is_absolute() and '..' not in path.parts, member.name
            bundle.extractall(target,filter='tar')
        count=0
        for line in (target/'files.sha256').read_text().splitlines():
            expected,name=line.split('  ',1)
            p=target/name
            assert not Path(name).is_absolute() and '..' not in Path(name).parts and p.resolve().is_relative_to(target.resolve())
            assert hashlib.sha256(p.read_bytes()).hexdigest()==expected,name
            count+=1
        report['regular_file_checksums']=count
        for p in target.rglob('*'):
            if p.is_symlink():
                assert not Path(os.readlink(p)).is_absolute() and p.resolve().is_relative_to(target.resolve()) and p.exists(),str(p)
        config=json.loads((target/'camera.json').read_text())
        assert config['bridge']=='/opt/npu100/runtime/app/libnpu_camera.so'
        assert config['auto_start'] is False and config['keys_enabled'] is True
        assert (target/'runtime/app/libnpu_camera.so').read_bytes()==(ROOT/'board/linux/driver/libnpu_camera.so').read_bytes()
        for name in ('manifest.py','npu_runtime.py','preflight.py','linux_camera.py'):
            assert (target/'runtime'/name).read_bytes()==(ROOT/'src/software/runtime/linux'/name).read_bytes(),name
        if args.qemu:
            assert args.sysroot is not None and args.sysroot.is_dir(),'QEMU needs the exact board libc/loader sysroot'
            runtime=target/'python-runtime'
            base=[str(args.qemu),'-L',str(args.sysroot),'-E','PYTHONHOME='+str(runtime/'usr'),'-E','PYTHONDONTWRITEBYTECODE=1','-E','PYTHONNOUSERSITE=1','-E','LD_LIBRARY_PATH='+':'.join(map(str,[runtime/'usr/lib/arm-linux-gnueabihf',runtime/'lib/arm-linux-gnueabihf',args.sysroot/'lib'])),str(runtime/'usr/bin/python3.12'),'-B']
            def call(script,*arguments):
                result=subprocess.run(base+[str(script),*map(str,arguments)],text=True,capture_output=True,check=True)
                return json.loads(result.stdout)
            report['runtime_smoke']=call(target/'runtime_check.py')
            assert report['runtime_smoke']['result']=='USERSPACE_RUNTIME_PASS'
            report['models']=call(target/'runtime/preflight.py','--files-only','--bundle',args.bundle)
            assert report['models']['bundle']['integrity']=='PASS'
            report['qemu']=True
    report['result']='PASS'
    output=args.receipt;output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
