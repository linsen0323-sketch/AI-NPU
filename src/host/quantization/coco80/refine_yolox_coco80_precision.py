"""Run COCO-only W8/A8/A16 policy search and original QDQ exporter."""
from __future__ import annotations
from collections import Counter
import importlib.metadata
import json
from pathlib import Path
import shutil
import sys
import traceback
import numpy as np
import torch
import mixed_precision_ptq_coco80 as c

OUT=c.OUT;q=c.q

def status(stage,state='RUNNING',**extra):
    c.dump(OUT/'status.json',dict(stage=stage,status=state,**extra));c.log('STATUS',stage,state)

def protect():
    paths=[c.REPO/'data/models/checkpoints/yolox_s_coco80.pth', c.TOOLS/'mixed_precision_ptq.py',
           c.TOOLS/'export_mixed_precision_onnx.py']
    paths += [p for p in (c.REPO/'data/models/runtime/bundle').rglob('*') if p.is_file()]
    hashes={str(p):q.sha(p) for p in paths if p.is_file()}
    target=OUT/'protected_inputs_sha256.json'
    if target.exists():assert c.read(target)==hashes,'protected source/model identity changed'
    else:c.dump(target,hashes)

def report(failure=None):
    state=c.read(OUT/'status.json');rows=[]
    for label,name in [('FP32','fp32'),('Selected PyTorch QDQ reference','selected'),('Saved ONNX QDQ','onnx')]:
        p=OUT/f'{name}_val_metrics.json'
        if p.exists():
            m=c.read(p);rows.append(f'| {label} | {m["samples"]} | {m["mAP50"]:.6f} | {m["mAP50_95"]:.6f} |')
        else:rows.append(f'| {label} | NOT RUN | NOT RUN | NOT RUN |')
    lines=['# YOLOX-S COCO 80-class PTQ report','',
           'Date: 2026-10-29 (Asia/Shanghai).',f'Status: **{state["status"]}**, stage: `{state["stage"]}`.','',
           'This is FP32 execution over quantize/dequantize tensors. It is not full integer runtime validation or FPGA validation.','',
           '| Model | COCO val images | mAP50 (%) | mAP50-95 (%) |','|---|---:|---:|---:|',*rows,'']
    for name in ['calibration_manifest.json','shape_and_bn_checks.json','selected_policy.json','release_acceptance.json','protected_verification.json']:
        p=OUT/name
        if p.exists():
            d=c.read(p)
            if name=='calibration_manifest.json':d={k:d[k] for k in ['status','verified_images','seed','sampling_rule','empty_image_count','validation_used_for_calibration']}
            elif name=='selected_policy.json':d={k:v for k,v in d.items() if k not in ['policy','metrics']}
            lines += [f'## {name}','', '```json',json.dumps(d,indent=2,ensure_ascii=False),'```','']
    lines += ['## Artifacts and reproducibility','',f'Root: `{OUT}`. All new code is in `scripts/`.',
              'See `provenance.json`, `execution_commands.jsonl`, `run_ptq.log`, `prepare_calibration.log`, `artifacts_sha256.json` and per-stage reports.',
              'Each metrics JSON contains 80-class per-category AP and raw output range. Prediction JSON and standard COCOeval text are preserved.',
              'The PTQ numerical core and exporter were imported from their original files; original source hashes and protected NEU artifact hashes are checked before/after execution.',
              '', '## Deferred stages','',
              '256 baseline, calibration, search and full evaluation states are reported above.',
              'No final FPGA package, compiler changes, RTL changes, synthesis or board connection.','']
    if failure:lines += ['## Failure','', '```text',failure,'```','']
    (OUT/'PTQ_REPORT.md').write_text('\n'.join(lines),encoding='utf-8')
    files=[]
    for p in sorted(OUT.rglob('*')):
        if p.is_file() and p.name not in ['artifacts_sha256.json','run_ptq.log','prepare_calibration.log'] and '__pycache__' not in p.parts:
            files.append(dict(path=str(p),bytes=p.stat().st_size,sha256=q.sha(p)))
    c.dump(OUT/'artifacts_sha256.json',dict(files=files,excluded=['artifacts_sha256.json (self-reference)','run_ptq.log and prepare_calibration.log (possibly open; sealed separately after process exit)']))

def export_and_validate():
    import export_mixed_precision_onnx as original_export
    assert q.sha(c.TOOLS/'export_mixed_precision_onnx.py')=='297333266537f2bf64add9cadb5932dac01a3a9a76bff7f31505780857a82a04'
    def loader(name):
        assert name=='yolox_s_coco80'
        task=c.CocoTask();stats=c.read(OUT/'calibration.json');selected=c.read(OUT/'selected_policy.json')
        assert c.read(OUT/'model_manifest.json')['original_checkpoint_sha256']==c.EXPECTED
        ops=q.wrap_model(task.model,stats)
        bundle=torch.load(OUT/'quantized_reference.pth',map_location='cpu',weights_only=True)
        task.model.load_state_dict(bundle['reference_state'],strict=True)
        q.apply_policy(ops,selected['policy']);c.validate_parameters(ops)
        return task,ops,selected
    # Adapt only the loader in memory; run/symbolics/forward from original file unchanged.
    original_export.load_selected=loader
    task,session=original_export.run('yolox_s_coco80',validate=12)
    assert session.get_inputs()[0].shape==[1,3,256,256]
    assert session.get_outputs()[0].shape==[1,1344,85]
    errors=[]
    c.dump(OUT/'onnx_shape_checks.json',dict(status='PASS',input_shape=session.get_inputs()[0].shape,output_shape=session.get_outputs()[0].shape,opset=21,classes=80,onnx_sha256=q.sha(OUT/'model_mixed_qdq.onnx')))
    class OrtModule(torch.nn.Module):
        def forward(self,x):
            actual=session.run(None,{'images':x.cpu().numpy()})[0]
            ref=task.model(x).detach().cpu().numpy()
            error=np.abs(ref-actual)
            confidence_ref=ref[:,:,4:5]*ref[:,:,5:]
            confidence_actual=actual[:,:,4:5]*actual[:,:,5:]
            errors.append(dict(max_abs=float(error.max()),mean_abs=float(error.mean()),
                probability_max_abs=float(error[:,:,4:].max()),probability_mean_abs=float(error[:,:,4:].mean()),
                confidence_mean_abs=float(np.abs(confidence_ref-confidence_actual).mean()),
                all_finite=bool(np.isfinite(actual).all())))
            return torch.from_numpy(actual).cuda()
    task.batch=1
    m=task.evaluate(OrtModule(),'onnx',cache=False)
    assert len(errors)==5000
    verification=c.read(OUT/'onnx_verification.json')
    verification.update(full_validation_comparison_samples=5000,full_validation_errors=errors,
        full_validation_summary={k:(max(v[k] for v in errors) if 'max' in k else sum(v[k] for v in errors)/len(errors))
            for k in ['max_abs','mean_abs','probability_max_abs','probability_mean_abs','confidence_mean_abs']},
        bit_exact=all(v['max_abs']==0 for v in errors),all_full_outputs_finite=all(v['all_finite'] for v in errors),
        input_shape=[1,3,256,256],output_shape=[1,1344,85],classes=task.classes,category_ids=task.cat_ids)
    c.dump(OUT/'onnx_verification.json',verification)
    with torch.inference_mode():
        comparisons=[]
        for row in task.rows('val')[:12]:
            x=task.tensor(row).unsqueeze(0);fp=task.original(x).cpu().numpy()
            actual=session.run(None,{'images':x.cpu().numpy()})[0]
            err=np.abs(fp-actual)
            comparisons.append(dict(image_id=row['id'],max_abs=float(err.max()),mean_abs=float(err.mean()),
                                   p99_abs=float(np.quantile(err,.99)),probability_mean_abs=float(np.abs(fp[:,:,4:]-actual[:,:,4:]).mean())))
    c.dump(OUT/'fp32_vs_qdq_numerics.json',dict(samples=12,output_shape=[1,1344,85],errors=comparisons,
           note='Unsuppressed decoded box errors are recorded, not thresholded as bit-exact parity; full COCO accuracy is the acceptance gate.'))
    return m

def main():
    torch.set_grad_enabled(False);c.cv2.setNumThreads(1);q.seed_all()
    with (OUT/'execution_commands.jsonl').open('a',encoding='utf-8') as f:
        f.write(json.dumps(dict(executable=sys.executable,argv=sys.argv,cwd=str(Path.cwd())),ensure_ascii=False)+'\n')
    assert c.read(OUT/'dataset_ready.json')['status']=='PASS','calibration/validation data gate failed'
    protect();status('baseline')
    task=c.CocoTask();base=c.baseline(task)
    status('calibration');stats=c.calibrate(task)
    status('policy_search');ops=q.wrap_model(task.model,stats)
    candidates=[];tried=set()
    def evaluate_mode(mode):
        p=c.make_policy(ops,stats,mode);q.apply_policy(ops,p);c.validate_parameters(ops)
        m=task.evaluate(task.model,f'w8_{mode}')
        counts=Counter(v['activation_bits'] for v in p.values())
        item=dict(tag=f'w8_{mode}',mode=mode,policy=p,metrics=m,passes_budget=q.passed(task.name,base,m),
                  layers=83,W8A8=counts[8],W8A16=counts[16],weight_bits=8,
                  drop_pp={k:base[k]-m[k] for k in ['mAP50','mAP50_95']})
        candidates.append(item);tried.add(mode);c.dump(OUT/'candidates.json',candidates)
        return item
    for mode in ['a8','predictors','head','sensitive_quarter']:evaluate_mode(mode)
    if not any(v['passes_budget'] and max(v['drop_pp'].values())<=.8 for v in candidates):
        for mode in ['sensitive_half','sensitive_three_quarters','all16']:evaluate_mode(mode)
    passing=[v for v in candidates if v['passes_budget']]
    if not passing:raise RuntimeError('No W8/A8/A16 reference policy passes the <=1pp COCO accuracy budget')
    # Original accuracy-first selection: choose highest measured AP, not smallest bytes.
    passing.sort(key=lambda v:(v['metrics']['mAP50_95'],v['metrics']['mAP50'],-v['W8A16']),reverse=True)
    selected=passing[0];q.apply_policy(ops,selected['policy']);c.validate_parameters(ops)
    selected['selection_reason']='Accuracy-first among COCO-only full-val candidates; W8 only; original sensitive-quarter/head/predictor rules'
    c.dump(OUT/'selected_policy.json',selected)
    # Explicitly evaluate saved reference policy before serializing original export_package.
    m=task.evaluate(task.model,'selected');assert q.passed(task.name,base,m)
    numeric=[]
    with torch.inference_mode():
        for row in task.rows('val')[:12]:
            x=task.tensor(row).unsqueeze(0);a=task.original(x);b=task.model(x);err=(a-b).abs()
            numeric.append(dict(image_id=row['id'],max_abs=float(err.max()),mean_abs=float(err.mean()),probability_mean_abs=float((a[:,:,4:]-b[:,:,4:]).abs().mean())))
    c.dump(OUT/'fp32_vs_quantized_reference_numerics.json',dict(samples=12,output_shape=[1,1344,85],errors=numeric,reference='FP32 convolution on QDQ values; not an integer execution proof'))
    q.export_package(task,ops,selected)
    manifest=c.read(OUT/'model_manifest.json');manifest.update(format='COCO_PTQ_REFERENCE_V1',num_classes=80,input_shape=[1,3,256,256],output_shape=[1,1344,85],provenance_identity=task.identity)
    c.dump(OUT/'model_manifest.json',manifest)
    c.dump(OUT/'parameter_validation.json',dict(status='PASS',layers=83,all_weights_W8=True,scale_finite_positive=True,bias_int32_bounds_pass=True,weight_roundtrip_pass=c.read(OUT/'packing_verification.json')['all_integer_weights_roundtrip_exact'],
           W8A8=selected['W8A8'],W8A16=selected['W8A16'],rounding='nearest ties-to-even',zero_point=0,signed_narrow_ranges=[[-127,127],[-32767,32767]],
           accumulator_bits_distribution=dict(Counter(l['accumulator_bits_required_worst_case'] for l in manifest['layers']))))
    # Release large observer/wrapper allocations before CPU ORT validation.
    del ops,task;torch.cuda.empty_cache()
    status('onnx_export_and_full_validation');onnx=export_and_validate()
    drops={k:base[k]-onnx[k] for k in ['mAP50','mAP50_95']}
    ok=all(v<=1.0+1e-9 for v in drops.values())
    c.dump(OUT/'release_acceptance.json',dict(status='PASS' if ok else 'FAIL',full_onnx_validation_pass=ok,samples=5000,
           accuracy_budget_percentage_points=1.0,drop_pp=drops,onnx_sha256=q.sha(OUT/'model_mixed_qdq.onnx'),
           checkpoint_sha256=c.EXPECTED,calibration_images=500,onnx_checker_pass=True,onnx_output_shape=[1,1344,85],
           full_integer_runtime_validated=False,fpga_board_validated=False))
    if not ok:raise RuntimeError('Saved QDQ ONNX exceeds 1pp budget: inspect fp32_vs_qdq_numerics.json and candidate metrics before further policy evaluation')
    protect();c.dump(OUT/'protected_verification.json',dict(status='PASS',all_protected_hashes_unchanged=True))
    status('complete','PASS');report()

if __name__=='__main__':
    try:main()
    except Exception:
        failure=traceback.format_exc();print(failure,flush=True)
        (OUT/'ptq_error.log').write_text(failure,encoding='utf-8')
        status('stopped_on_error','FAIL',error=failure.splitlines()[-1])
        try:protect();report(failure)
        except Exception:traceback.print_exc()
        raise
