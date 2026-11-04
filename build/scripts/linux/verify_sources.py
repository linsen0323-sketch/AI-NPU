#!/usr/bin/env python3
"""Compile packaged Linux C bridge/checker privately and validate script syntax."""
import argparse, ast, hashlib, json, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--cc',default='arm-linux-gnueabihf-gcc-13');args=ap.parse_args()
    scripts=[]
    for base in ('src/software/runtime/linux','board/deploy','build/scripts/linux'):
        for p in (ROOT/base).rglob('*.py'):
            ast.parse(p.read_text(encoding='utf-8-sig'),filename=str(p));scripts.append(p.relative_to(ROOT).as_posix())
    shells=[]
    for base in ('board/deploy','board/linux/driver','build/scripts/linux'):
        for p in (ROOT/base).rglob('*'):
            if p.is_file() and p.suffix in ('.sh','.init'):
                subprocess.run(['sh','-n',str(p)],check=True);shells.append(p.relative_to(ROOT).as_posix())
    with tempfile.TemporaryDirectory(prefix='npu100_source_verify_') as tmp:
        tmp=Path(tmp);app=ROOT/'src/software/app/src';bridge=tmp/'libnpu_camera.so'
        cmd=[args.cc,'-O2','-std=c11','-Wall','-Wextra','-Werror','-fPIC','-fno-fast-math','-I'+str(app),'-shared',str(ROOT/'src/software/runtime/linux/app/camera_bridge.c'),str(app/'ai_camera_math.c'),str(app/'ai_detector.c'),str(app/'ai_display.c'),'-o',str(bridge)]
        subprocess.run(cmd,check=True)
        info=tmp/'npu_driver_info'
        subprocess.run([args.cc,'-O2','-Wall','-Wextra','-Werror','-I'+str(ROOT/'board/linux/driver'),str(ROOT/'board/linux/driver/npu_driver_info.c'),'-o',str(info)],check=True)
        header=bridge.read_bytes()[:20];assert header[:4]==b'\x7fELF' and header[4]==1 and header[18:20]==b'(\x00'
        report={'scope':'PACKAGED_SOURCE_SYNTAX_AND_PRIVATE_ARM_C_BUILD_NO_BOARD_ACCESS','result':'PASS','python_modules':scripts,'shell_scripts':shells,'bridge_sha256':sha(bridge),'frozen_bridge_sha256':sha(ROOT/'board/linux/driver/libnpu_camera.so'),'rebuilt_bridge_byte_identical':bridge.read_bytes()==(ROOT/'board/linux/driver/libnpu_camera.so').read_bytes(),'info_checker_sha256':sha(info),'driver_source_sha256':sha(ROOT/'src/software/runtime/linux/driver/unified_npu.c'),'driver_module_rebuilt_in_this_check':False,'hardware_opened':False}
    (ROOT/'evidence/linux/packaging/source_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
