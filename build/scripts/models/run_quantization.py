"""Run the existing YOLOX PTQ workflows against separately acquired datasets."""
from pathlib import Path
import argparse
import os
import subprocess
import sys
REPO=Path(__file__).resolve().parents[3]
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model',choices=['neu6','coco80'],required=True)
    args=parser.parse_args()
    scripts=REPO/'src/host/quantization'/args.model
    if args.model=='neu6':
        stages=[('mixed_precision_ptq.py','--model','yolox_s_a','--stage','all'),
                ('refine_yolox_precision.py',),('export_mixed_precision_onnx.py','--model','yolox_s_a')]
        required=[REPO/'data/datasets/neu_det/train2017',REPO/'data/datasets/neu_det/val2017',
                  REPO/'data/datasets/neu_det/annotations/instances_train2017.json',
                  REPO/'data/datasets/neu_det/annotations/instances_val2017.json']
    else:
        stages=[('prepare_coco_calibration.py',),('refine_yolox_coco80_precision.py',)]
        data=Path(os.environ.get('NPU_COCO_DATA',str(REPO/'data/datasets/coco80')))
        required=[data/'val2017',data/'annotations/instances_train2017.json',data/'annotations/instances_val2017.json']
    missing=[str(p) for p in required if not p.exists()]
    if missing:raise SystemExit('Acquire the documented datasets before PTQ; missing: '+', '.join(missing))
    for name,*extra in stages:
        subprocess.run([sys.executable,'-B',str(scripts/name),*extra],cwd=REPO,check=True,
                       env={**os.environ,'PYTHONUTF8':'1','PYTHONDONTWRITEBYTECODE':'1'})
if __name__=='__main__':main()
