"""Validation-only activation/weight sensitivity refinement for YOLOX A."""
import json
import math
import copy
import shutil
import mixed_precision_ptq as q

q.seed_all()
t = q.Task("yolox_s_a")
s = json.loads((t.out / "calibration.json").read_text())
baseline = json.loads((t.out / "fp32_val_metrics.json").read_text())
if not (t.out / "historical_fp16_val_metrics.json").exists():
    t.evaluate(copy.deepcopy(t.original).half(),"historical_fp16")
historical = json.loads((t.out / "historical_fp16_val_metrics.json").read_text())
ops = q.wrap_model(t.model, s)
candidates = json.loads((t.out / "candidates.json").read_text())

for mode in ["predictors", "head", "sensitive_quarter"]:
    p = q.make_policy(t.name, ops, 0)
    ranked = sorted(s, key=lambda n: s[n]["a8_mse"]/max(s[n]["max"]**2, 1e-20), reverse=True)
    for n in p:
        use16 = (any(v in n for v in ["cls_preds", "reg_preds", "obj_preds"]) if mode == "predictors" else n.startswith("head.") if mode == "head" else n in ranked[:len(ranked)//4])
        p[n]["activation_bits"] = 16 if use16 else 8
    q.apply_policy(ops, p)
    m = t.evaluate(t.model, f"mixed_a16_{mode}")
    c = {"tag": f"mixed_a16_{mode}", "policy": p, "metrics": m, "passes_budget": q.passed(t.name, baseline, m) and q.passed(t.name, historical, m), "packed_weight_bytes": sum(o.original_weight.numel() for o in ops.values())}
    candidates.append(c)
    q.dump(t.out / "candidates.json", candidates)

mixed = [c for c in candidates if c["passes_budget"] and any(p["activation_bits"]==16 for p in c["policy"].values())]
anchor = max(mixed, key=lambda c: c["metrics"]["mAP50_95"])
policy = copy.deepcopy(anchor["policy"])
q.apply_policy(ops, policy)
# Test individual W4 changes cumulatively. Begin with small tensors so one
# large low-MSE layer cannot overshoot an intended fraction of the network.
ranked = []
for n,o in ops.items():
    if q.protected(t.name,n):
        continue
    w=o.original_weight
    wi=o.w4.float()*o.s4.reshape([-1]+[1]*(w.ndim-1))
    error=float(((wi-w).square().sum()/w.square().sum()).item())
    ranked.append((o.original_weight.numel(),error,n))
ranked.sort()
trials=[]
last=anchor["metrics"]
for _,_,n in ranked[:30]:
    ops[n].set_precision(4,policy[n]["activation_bits"])
    m=t.evaluate(t.model,f"w4_layer_trial_{len(trials):02d}")
    # Preserve a little margin under the 1pp user budget for export parity.
    ok=all(max(baseline[k],historical[k])-m[k]<=.9 for k in ["mAP50_95","mAP50"])
    if ok:
        policy[n]["weight_bits"]=4
        last=m
    else:
        ops[n].set_precision(8,policy[n]["activation_bits"])
    trials.append({"layer":n,"accepted_w4":ok,"mAP50_95":m["mAP50_95"],"mAP50":m["mAP50"]})
    q.dump(t.out / "weight_sensitivity.json",trials)

q.apply_policy(ops,policy)
final=t.evaluate(t.model,"selected")
assert q.passed(t.name,baseline,final) and q.passed(t.name,historical,final)
selected={"tag":"mixed_sensitivity_selected","policy":policy,"passes_budget":True,"metrics":final,"packed_weight_bytes":sum(math.ceil(o.original_weight.numel()*policy[n]["weight_bits"]/8) for n,o in ops.items()),"activation_anchor":anchor["tag"]}
q.dump(t.out / "selected_policy.json",selected)
q.export_package(t,ops,selected)
# Accuracy-first release: the W4 candidate meets the aggregate budget but
# hurts a weak class more than the W8 mixed-activation anchor. Keep it as an
# explicit optional comparison; do not promote it merely for small size gains.
optional=t.out/'optional_int4'
optional.mkdir(exist_ok=True)
for file in ['selected_policy.json','weights_packed.bin','quantized_reference.pth','model_manifest.json','layer_precision.csv','packing_verification.json']:
    shutil.copy2(t.out/file,optional/file)
recommended=copy.deepcopy(anchor)
recommended['tag']='accuracy_first_w8_mixed_a8_a16'
recommended['selection_reason']='Higher aggregate and weak-class accuracy than the optional INT4 candidate; user selected accuracy first.'
q.apply_policy(ops,recommended['policy'])
recommended['metrics']=t.evaluate(t.model,'selected')
q.dump(t.out/'selected_policy.json',recommended)
q.export_package(t,ops,recommended)
