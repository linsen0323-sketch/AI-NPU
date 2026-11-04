#!/usr/bin/env python3
"""Rebuild own runtime layer using the frozen third-party ARM Python payload."""
import argparse, copy, hashlib, io, json, tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--base',type=Path,default=ROOT/'board/linux/userspace/linux_userspace.tar.gz')
    ap.add_argument('--bridge',type=Path,default=ROOT/'board/linux/driver/libnpu_camera.so')
    ap.add_argument('--output',type=Path,default=ROOT/'build/output/linux/linux_userspace.tar.gz')
    args=ap.parse_args()
    if args.output.exists():ap.error('Output exists; choose a new path')
    assert args.output.resolve()!=args.base.resolve()
    replacements={}
    for name in ('manifest.py','npu_runtime.py','preflight.py','linux_camera.py'):
        replacements['runtime/'+name]=(ROOT/'src/software/runtime/linux'/name).read_bytes()
    for name in ('runtime_check.py','load_models_once.py','npu100.sh','verify_after_boot.sh'):
        replacements[name]=(ROOT/'board/deploy/userspace'/name).read_bytes()
    replacements['runtime/validate_pl.py']=(ROOT/'board/deploy/userspace/validate_pl.py').read_bytes()
    replacements['runtime/app/libnpu_camera.so']=args.bridge.read_bytes()
    config=json.loads((ROOT/'src/software/runtime/linux/camera.json').read_text())
    config['bridge']='/opt/npu100/runtime/app/libnpu_camera.so';config['auto_start']=False
    replacements['camera.json']=(json.dumps(config,indent=2)+'\n').encode()
    members=[];seen=set()
    with tarfile.open(args.base) as bundle:
        for original in bundle.getmembers():
            name=original.name
            assert not Path(name).is_absolute() and '..' not in Path(name).parts,name
            if name in ('files.sha256','FILES.sha256','packaging_provenance.json'):continue
            info=copy.copy(original)
            data=bundle.extractfile(original).read() if info.isreg() else None
            if name in replacements:
                assert info.isreg(),name
                data=replacements[name];seen.add(name);info.size=len(data)
            members.append((info,data))
    assert seen==set(replacements),sorted(set(replacements)-seen)
    receipt={'scope':'REPACKAGED_RUNTIME_LAYER_NO_BOARD_ACCESS','base_sha256':hashlib.sha256(args.base.read_bytes()).hexdigest(),'bridge_sha256':hashlib.sha256(args.bridge.read_bytes()).hexdigest(),'runtime_prefix':'/opt/npu100','replaced_members':sorted(seen),'board_tested':False}
    raw=(json.dumps(receipt,indent=2)+'\n').encode();info=tarfile.TarInfo('packaging_provenance.json');info.mode=0o644;info.size=len(raw);members.append((info,raw))
    lines=[hashlib.sha256(data).hexdigest()+'  '+info.name for info,data in members if info.isreg()]
    raw=('\n'.join(sorted(lines))+'\n').encode();info=tarfile.TarInfo('files.sha256');info.mode=0o644;info.size=len(raw);members.append((info,raw))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with tarfile.open(args.output,'w:gz',compresslevel=6) as out:
        for info,data in members:out.addfile(info,io.BytesIO(data) if data is not None else None)
    print(json.dumps({'output':str(args.output),'sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),'board_tested':False},indent=2))
if __name__=='__main__':main()
