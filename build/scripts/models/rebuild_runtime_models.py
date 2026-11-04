"""Rebuild final DDR payloads from the packaged frozen compiler inputs.

Only deterministic file construction is performed. No model inference, training,
quantization, simulator, Vivado or hardware access is launched.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys

REPO=Path(__file__).resolve().parents[3]
TOOLS=REPO/'src/host/plan_tools'

def run(name,*args):
    command=[sys.executable,'-B',str(TOOLS/name),*map(str,args)]
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8')
    if result.returncode:
        print(result.stdout)
        raise RuntimeError(f'{name} failed with exit {result.returncode}')

def digest(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True,help='A new, empty output directory')
    args=parser.parse_args();out=args.output.resolve()
    if out.exists() and any(out.iterdir()):raise ValueError('Refusing to overwrite an existing output directory')
    if out==REPO or (REPO/'data/models').resolve() in out.parents:raise ValueError('Preserve packaged immutable models')
    out.mkdir(parents=True,exist_ok=True)
    run('specialize_resnet.py','--model-dir',REPO/'data/models/intermediate/resnet18_unified',
        '--size',160,'--output',out/'resnet18_spatial')
    run('prepare_predecoded_control.py','--source',out/'resnet18_spatial',
        '--output',out/'resnet18','--coalesce-inner')
    run('specialize_yolox.py','--size',256,'--fuse-silu','--output',out/'neu6_spatial')
    run('compile_conv_fused_plan.py','--model-dir',out/'neu6_spatial','--output',out/'neu6_fused')
    run('prepare_predecoded_control.py','--source',out/'neu6_fused','--output',out/'neu6_control','--coalesce-inner')
    run('pack_runtime_weights.py','--source',out/'neu6_control','--output',out/'neu6')
    run('compile_coco80.py','--source',REPO/'data/models/quantization/coco80','--output',out/'coco80_build')
    final={1:out/'resnet18/ddr.bin',3:out/'neu6/ddr.bin',4:out/'coco80_build/wpk1/ddr.bin'}
    expected=json.loads((REPO/'data/models/runtime/bundle/manifest.json').read_text('utf-8'))['models']
    results=[]
    for m in expected:
        actual=digest(final[m['id']])
        results.append(dict(id=m['id'],path=str(final[m['id']]),sha256=actual,
                            expected=m['image_sha256'],matches=actual==m['image_sha256']))
    report=dict(status='PASS' if all(r['matches'] for r in results) else 'MISMATCH',
                scope='file_construction_and_byte_identity_only',inference_executed=False,models=results)
    (out/'rebuild_verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))
    if report['status']!='PASS':raise SystemExit(1)

if __name__=='__main__':main()
