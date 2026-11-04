"""COCO task adapter. Quantization math is imported unchanged from original PTQ."""
from __future__ import annotations
import concurrent.futures as cf
import contextlib
import copy
import hashlib
import io
import json
import math
from pathlib import Path
import sys
import time
import cv2
import numpy as np
import torch

REPO=Path(__file__).resolve().parents[4]
import os
OUT=Path(os.environ.get("NPU_COCO_QUANT_OUT", str(REPO/"work/quantization/coco80")))
OUT.mkdir(parents=True, exist_ok=True)
DATA=Path(os.environ.get("NPU_COCO_DATA", str(REPO/"data/datasets/coco80")))
YOLO=REPO/"src/third_party/yolox/coco80"
TOOLS=Path(__file__).resolve().parent
sys.path.insert(0,str(TOOLS))
sys.path.insert(0,str(YOLO))
import mixed_precision_ptq as q
from yolox.exp import get_exp
from yolox.data.data_augment import preproc
from yolox.utils.boxes import postprocess
from pycocotools.coco import COCO
from pycocotools.cocoeval import COCOeval

EXPECTED='f55ded7181e1b0c13285c56e7790b8f0e8f8db590fe4edb37f0b7f345c913a30'
CORE_HASH='0306320b0c8414a85a01cf9bf53d07189068083d9878a183019e69e433df4bfc'

def read(path): return json.loads(Path(path).read_text(encoding='utf-8'))
def dump(path,obj): q.dump(path,obj)
def log(*items): print(time.strftime('%H:%M:%S'),*items,flush=True)

class CocoTask:
    def __init__(self):
        assert q.sha(TOOLS/'mixed_precision_ptq.py')==CORE_HASH,'frozen PTQ source changed'
        assert Path(q.__file__).resolve()==(TOOLS/'mixed_precision_ptq.py').resolve()
        self.name='yolox_s_coco80';self.out=OUT
        self.ckpt=REPO/'data/models/checkpoints/yolox_s_coco80.pth'
        assert q.sha(self.ckpt)==EXPECTED,'COCO checkpoint changed'
        self.config=YOLO/'exps/default/yolox_s.py'
        self.exp=get_exp(str(self.config),None)
        assert self.exp.num_classes==80 and self.exp.depth==.33 and self.exp.width==.5
        ck=torch.load(self.ckpt,map_location='cpu',weights_only=True)
        self.original=self.exp.get_model().eval()
        result=self.original.load_state_dict(ck['model'],strict=True)
        assert not result.missing_keys and not result.unexpected_keys and self.original.head.num_classes==80
        for i in range(3):assert list(ck['model'][f'head.cls_preds.{i}.weight'].shape)==[80,128,1,1]
        self.original.cuda().eval()
        self.model=copy.deepcopy(self.original)
        self.fused_count=q.fuse_bn(self.model)
        assert self.fused_count==74,'unexpected YOLOX-S Conv/BN structure'
        self.model.cuda().eval()
        self.calibration=read(OUT/'calibration_manifest.json')
        assert self.calibration['status']=='PASS' and self.calibration['verified_images']==500
        self.annotations={'val':DATA/'annotations/instances_val2017.json'}
        val=read(self.annotations['val'])
        cats=sorted(val['categories'],key=lambda c:c['id'])
        assert len(cats)==80
        self.classes=[c['name'] for c in cats];self.cat_ids=[c['id'] for c in cats]
        assert [(c['id'],c['name']) for c in cats]==[(c['id'],c['name']) for c in self.calibration['categories']]
        self.splits={'train':[{**r,'id':r['image_id']} for r in self.calibration['images']],
                     'val':[{**im,'path':str(DATA/'val2017'/im['file_name'])} for im in sorted(val['images'],key=lambda im:im['id'])]}
        assert len(self.splits['val'])==5000
        assert {r['id'] for r in self.splits['train']}.isdisjoint(r['id'] for r in self.splits['val'])
        self.size=256;self.batch=4
        self.conf=.01;self.nms=.65
        self.preprocess=dict(layout='NCHW',color='BGR',resize='aspect preserving, cv2 INTER_LINEAR',
                             letterbox='top-left, fill 114',size=[256,256],input_range=[0,255],
                             conf_threshold=self.conf,nms_iou=self.nms,class_agnostic_nms=False)
        sources={str(p):q.sha(p) for p in [self.ckpt,self.config,YOLO/'yolox/exp/yolox_base.py',
                TOOLS/'mixed_precision_ptq.py',TOOLS/'export_mixed_precision_onnx.py',
                *sorted(TOOLS.glob('*.py')),OUT/'calibration_manifest.json',self.annotations['val'],
                YOLO/'yolox/data/data_augment.py',YOLO/'yolox/utils/boxes.py',
                *sorted((YOLO/'yolox/models').glob('*.py'))]}
        # Cache validity also binds every validation image, never only its filename.
        dataset_index=OUT/'validation_fingerprints.json'
        fingerprints=[]
        for r in self.splits['val']:
            p=Path(r['path']);fingerprints.append(dict(image_id=r['id'],path=str(p),bytes=p.stat().st_size,sha256=q.sha(p)))
        fingerprint_hash=hashlib.sha256(json.dumps(fingerprints,sort_keys=True).encode()).hexdigest()
        if dataset_index.exists():assert read(dataset_index)['fingerprints_sha256']==fingerprint_hash,'validation images changed'
        else:dump(dataset_index,dict(fingerprints_sha256=fingerprint_hash,files=fingerprints))
        self.identity=hashlib.sha256(json.dumps(dict(sources=sources,validation_images=fingerprint_hash),sort_keys=True).encode()).hexdigest()
        self.gt=COCO(str(self.annotations['val']))
        prov=dict(schema='COCO80_PTQ_PROVENANCE_V1',checkpoint=str(self.ckpt),checkpoint_sha256=EXPECTED,
                  classes=self.classes,num_classes=80,strict_load_pass=True,missing_keys=[],unexpected_keys=[],
                  sources=sources,identity=self.identity,validation_images_sha256=fingerprint_hash,
                  preprocessing=self.preprocess,observer_seed=q.SEED,calibration_selection_seed=self.calibration['seed'],
                  calibration_images=500,validation_images=5000,bn_pairs_folded=self.fused_count,
                  reused_core=['seed_all','fuse_bn','Observer','weight_quant','QuantOp','wrap_model','apply_policy','passed','export_package'],
                  calibration_and_metrics_from_neu_used=False,reference_compute='FP32 convolution over QDQ values; not integer runtime or FPGA',
                  python=sys.version,torch=torch.__version__,gpu=torch.cuda.get_device_name(0))
        if (OUT/'provenance.json').exists():assert read(OUT/'provenance.json')['identity']==self.identity,'COCO run identity changed; do not reuse old cache'
        else:dump(OUT/'provenance.json',prov)

    def rows(self,split): return self.splits[split]

    def pixels(self,row,size=256):
        image=cv2.imread(row['path'],cv2.IMREAD_COLOR)
        if image is None or image.shape[:2]!=(row['height'],row['width']):raise ValueError(f'image decode/dimensions: {row["path"]}')
        array,_=preproc(image,(size,size))
        array=array.astype(np.uint8)
        assert array.shape==(3,size,size)
        return array

    def tensor(self,row,size=256): return torch.from_numpy(self.pixels(row,size)).cuda().float()

    def batches(self,rows):
        # Bounded per-batch loading avoids the six-class task's unbounded image cache.
        with cf.ThreadPoolExecutor(max_workers=4) as pool:
            for begin in range(0,len(rows),self.batch):
                sub=rows[begin:begin+self.batch]
                arrays=list(pool.map(self.pixels,sub))
                yield torch.from_numpy(np.stack(arrays)).cuda().float(),sub

    @torch.inference_mode()
    def evaluate(self,model,tag,split='val',cache=True):
        assert split=='val'
        metric_path=OUT/f'{tag}_val_metrics.json'
        if cache and metric_path.exists():
            saved=read(metric_path)
            assert saved['identity']==self.identity and saved['samples']==5000 and saved['output_shape']==[1,1344,85]
            log('CACHE',tag,saved['mAP50'],saved['mAP50_95']);return saved
        started=time.perf_counter();preds=[];ranges=[]
        model.eval()
        for n,(x,rows) in enumerate(self.batches(self.rows(split)),1):
            output=model(x)
            if tuple(output.shape)!=(len(rows),1344,85):raise ValueError(f'80-class output mismatch: {output.shape}')
            if not bool(torch.isfinite(output).all()):raise FloatingPointError(f'nonfinite {tag} output')
            ranges.append((float(output.min()),float(output.max()),float(output[:,:,4:].min()),float(output[:,:,4:].max())))
            results=postprocess(output,80,self.conf,self.nms)
            for row,pred in zip(rows,results):
                if pred is None:continue
                pred=pred.detach().cpu().numpy()
                ratio=min(self.size/row['height'],self.size/row['width'])
                boxes=pred[:,:4]/ratio;boxes[:,2:]-=boxes[:,:2]
                for p,b in zip(pred,boxes):preds.append(dict(image_id=row['id'],category_id=self.cat_ids[int(p[6])],bbox=[float(v) for v in b],score=float(p[4]*p[5])))
            if n%100==0:log(tag,f'{min(n*self.batch,5000)}/5000',f'{time.perf_counter()-started:.1f}s')
        if not preds:raise RuntimeError(f'{tag}: no detections on full COCO val')
        dump(OUT/f'{tag}_val_predictions.json',preds)
        captured=io.StringIO()
        with contextlib.redirect_stdout(captured):
            dt=self.gt.loadRes(preds);ev=COCOeval(self.gt,dt,'bbox')
            ev.evaluate();ev.accumulate();ev.summarize()
        (OUT/f'{tag}_val_coco.txt').write_text(captured.getvalue(),encoding='utf-8')
        precision=ev.eval['precision'];pc={}
        for i,name in enumerate(self.classes):
            v=precision[:,:,i,0,-1];v50=precision[0,:,i,0,-1]
            pc[name]=dict(category_id=self.cat_ids[i],AP50_95=float(v[v>-1].mean()*100),AP50=float(v50[v50>-1].mean()*100))
        metric=dict(mAP50_95=float(ev.stats[0]*100),mAP50=float(ev.stats[1]*100),AP75=float(ev.stats[2]*100),
                    samples=5000,per_class=pc,tag=tag,split=split,identity=self.identity,
                    output_shape=[1,1344,85],output_min=min(r[0] for r in ranges),output_max=max(r[1] for r in ranges),
                    probability_min=min(r[2] for r in ranges),probability_max=max(r[3] for r in ranges),
                    elapsed_s=time.perf_counter()-started,all_5000_images_decoded=True,
                    predictions=len(preds),max_detections_evaluation=100)
        assert all(math.isfinite(metric[k]) and 0<=metric[k]<=100 for k in ['mAP50','mAP50_95'])
        dump(metric_path,metric);log('METRIC',tag,metric['mAP50'],metric['mAP50_95'],metric['elapsed_s'])
        return metric

def baseline(task):
    if not (OUT/'shape_and_bn_checks.json').exists():
        checks=[]
        with torch.inference_mode():
            for size,expected in [(256,1344)]:
                x=task.tensor(task.rows('val')[0],size).unsqueeze(0)
                a=task.original(x);b=task.model(x)
                assert list(a.shape)==[1,expected,85] and bool(torch.isfinite(a).all())
                error=(a-b).abs()
                checks.append(dict(input_shape=list(x.shape),output_shape=list(a.shape),dtype=str(a.dtype),
                                   output_min=float(a.min()),output_max=float(a.max()),
                                   bn_max_abs_error=float(error.max()),bn_mean_abs_error=float(error.mean()),
                                   input_contract='FP32 NCHW BGR 0..255, top-left letterbox 114',
                                   output_contract='FP32 decoded cx,cy,w,h, objectness and 80 class probabilities; NMS outside graph'))
                assert float(error.mean())<=1e-3,'BN fold parity fails original mean-error gate'
        dump(OUT/'shape_and_bn_checks.json',dict(status='PASS',checks=checks,
             note='256 BN parity smoke; full 5000-image accuracy is evaluated separately'))
    return task.evaluate(task.original,'fp32')

def calibrate(task):
    path=OUT/'calibration.json'
    if path.exists():
        receipt=read(OUT/'calibration_identity.json')
        assert receipt['identity']==task.identity and receipt['statistics_sha256']==q.sha(path)
        return read(path)
    observers={};hooks=[]
    for name,module in task.model.named_modules():
        if isinstance(module,(torch.nn.Conv2d,torch.nn.Linear)):
            observers[name]=q.Observer();hooks.append(module.register_forward_pre_hook(observers[name].hook))
    assert len(observers)==83
    for row in task.rows('train'):assert q.sha(row['path'])==row['sha256'],'calibration image changed'
    # Explicit reset keeps observer random sampling independent of validation execution.
    q.seed_all()
    with torch.inference_mode():
        for n,(x,_) in enumerate(task.batches(task.rows('train')),1):
            y=task.model(x)
            assert list(y.shape)[1:]==[1344,85] and bool(torch.isfinite(y).all())
            if n%25==0:log('CALIBRATION',n*task.batch,'/500')
    for hook in hooks:hook.remove()
    stats={name:observer.finish() for name,observer in observers.items()}
    for name,s in stats.items():
        assert s['calls']==125 and s['sample_count']>0
        for bits in [8,16]:assert math.isfinite(s[f'a{bits}_scale']) and s[f'a{bits}_scale']>0
    dump(path,stats);dump(OUT/'calibration_identity.json',dict(identity=task.identity,images=500,layers=83,observer_seed=q.SEED,statistics_sha256=q.sha(path)))
    return stats

def make_policy(ops,stats,mode):
    # Same original refinement rules; weights are always W8, no INT4 search.
    policy=q.make_policy('yolox_s_a',ops,0)
    ranked=sorted(stats,key=lambda n:stats[n]['a8_mse']/max(stats[n]['max']**2,1e-20),reverse=True)
    fractions={'sensitive_quarter':.25,'sensitive_third':1/3,'sensitive_half':.5,'sensitive_three_quarters':.75}
    chosen=set(ranked[:int(len(ranked)*fractions[mode])]) if mode in fractions else set()
    for name in policy:
        a16=(mode=='all16' or (mode=='predictors' and any(s in name for s in ['cls_preds','reg_preds','obj_preds']))
             or (mode=='head' and name.startswith('head.')) or name in chosen)
        policy[name]={'weight_bits':8,'activation_bits':16 if a16 else 8}
    return policy

def validate_parameters(ops):
    for name,op in ops.items():
        assert op.wbits==8 and op.abits in (8,16)
        assert op.w8.dtype==torch.int8 and bool((op.w8>=-127).all()) and bool((op.w8<=127).all())
        assert bool(torch.isfinite(op.s8).all()) and bool((op.s8>0).all()) and math.isfinite(op.sx) and op.sx>0
        bias=torch.round(op.original_bias/(op.s8*op.sx))
        assert bool(torch.isfinite(bias).all()) and bool((bias.abs()<=2147483647).all()),f'INT32 bias overflow {name}'

if __name__=='__main__':
    raise SystemExit('Use refine_yolox_coco80_precision.py to execute the audited stage sequence.')
