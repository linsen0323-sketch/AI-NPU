"""Deterministic, accuracy-gated PTQ reference for the two selected NEU models.

The forward path is GPU FP32 convolution/linear over quantize-dequantize values.
It measures quantization accuracy, NOT FPGA performance or integer-kernel parity.
SiLU, normalization, attention matrix products, softmax and detector decode stay
explicit FP32 reference islands. Packed weights and the arithmetic contract are
exported separately; no claim of complete integer RTL deployment is made.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import csv
import hashlib
import io
import json
import math
import random
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

ROOT = Path(__file__).resolve().parents[4]
YOLO = ROOT / "src/third_party/yolox/neu6"
OUT = ROOT / "work" / "quantization"
SEED = 20261019


def dump(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


def log(*args):
    print(time.strftime("%H:%M:%S"), *args, flush=True)


def seed_all():
    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)
    torch.cuda.manual_seed_all(SEED)
    torch.set_num_threads(6)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False


def fuse_bn(module):
    """Only fuse the explicit conv->bn pairs used by these architectures."""
    count = 0
    for m in module.modules():
        if isinstance(getattr(m, "conv", None), nn.Conv2d) and isinstance(getattr(m, "bn", None), nn.BatchNorm2d):
            bn = m.bn
            m.conv = torch.nn.utils.fusion.fuse_conv_bn_eval(m.conv, bn)
            # timm BatchNormAct2d inherits BatchNorm2d but also owns the
            # activation. Fold only BN arithmetic, preserving drop/activation.
            m.bn = nn.Sequential(copy.deepcopy(getattr(bn, "drop", nn.Identity())), copy.deepcopy(getattr(bn, "act", nn.Identity())))
            count += 1
    return count


class Task:
    def __init__(self, name):
        self.name = name
        self.out = OUT / name
        self.out.mkdir(parents=True, exist_ok=True)
        self.cache = {}
        if name == "mobilevit_xxs":
            import timm
            from PIL import Image
            from torchvision import datasets, transforms
            self.ckpt = ROOT / "checkpoints/mobilevit_xxs_neu/best.pth"
            ck = torch.load(self.ckpt, map_location="cpu", weights_only=False)
            self.meta = ck["meta"] if "meta" in ck else {k: v for k, v in ck.items() if k != "model_state_dict"}
            # Training exports metadata at top level in some versions.
            architecture = self.meta.get("architecture", "mobilevit_xxs.cvnets_in1k")
            timm.layers.set_fused_attn(False)
            self.model = timm.create_model(architecture, pretrained=False, num_classes=6)
            self.model.load_state_dict(ck["model_state_dict"])
            self.model.eval()
            self.data = ROOT / "datasets/NEU_CLS_split"
            self.transform = transforms.Compose([transforms.Resize((256, 256)), transforms.ToTensor()])
            self.Image = Image
            self.splits = {}
            for split in ["train", "val", "test"]:
                ds = datasets.ImageFolder(self.data / split)
                self.splits[split] = [(str(Path(p)), int(y)) for p, y in ds.samples]
                self.classes = ds.classes
            assert self.classes == ["Cr", "In", "PS", "Pa", "RS", "Sc"]
            self.size, self.batch = 256, 16
            self.preprocess = {"layout": "NCHW", "color": "RGB", "resize": [256, 256], "interpolation": "PIL bilinear", "input_range": [0, 1], "mean": [0, 0, 0], "std": [1, 1, 1]}
        else:
            sys.path.insert(0, str(YOLO))
            from yolox.exp import get_exp
            self.config = ROOT / "src/host/training/yolox_neu6.py"
            self.ckpt = ROOT / "data/models/checkpoints/yolox_s_neu6.pth"
            exp = get_exp(str(self.config), None)
            self.model = exp.get_model().eval()
            ck = torch.load(self.ckpt, map_location="cpu", weights_only=False)
            self.model.load_state_dict(ck["model"])
            self.meta = {k: v for k, v in ck.items() if k not in ["model", "optimizer"]}
            self.data = ROOT / "data/datasets/neu_det"
            self.splits, self.annotations = {}, {}
            for split in ["train", "val"]:
                p = self.data / f"annotations/instances_{split}2017.json"
                a = json.loads(p.read_text(encoding="utf-8"))
                self.annotations[split] = p
                cats = sorted(a["categories"], key=lambda c: c["id"])
                self.cat_ids = [c["id"] for c in cats]
                self.classes = [c["name"] for c in cats]
                labels = {}
                for an in a["annotations"]:
                    labels.setdefault(an["image_id"], []).append(an["category_id"])
                self.splits[split] = [{**im, "path": str(self.data / f"{split}2017" / im["file_name"]), "label": labels[im["id"]][0]} for im in a["images"]]
            self.size, self.batch = 640, 4
            self.conf, self.nms = float(exp.test_conf), float(exp.nmsthre)
            self.preprocess = {"layout": "NCHW", "color": "BGR", "resize": "aspect preserving, cv2 INTER_LINEAR", "letterbox": "top-left, fill 114", "size": [640, 640], "input_range": [0, 255], "conf_threshold": self.conf, "nms_iou": self.nms, "class_agnostic_nms": False}
        del ck
        self.original = self.model.cuda().eval()
        self.model = copy.deepcopy(self.original)
        self.fused_count = fuse_bn(self.model)
        self.model.cuda().eval()
        log(name, "loaded", "BN fused:", self.fused_count)

    def rows(self, split):
        return self.splits[split]

    def tensor(self, row):
        key = str(row[0]) if self.name == "mobilevit_xxs" else row["path"]
        if key not in self.cache:
            if self.name == "mobilevit_xxs":
                im = self.Image.open(key).convert("RGB").resize((256, 256), self.Image.Resampling.BILINEAR)
                a = np.array(im).transpose(2, 0, 1).copy()
            else:
                from yolox.data.data_augment import preproc
                im = cv2.imread(key)
                if im is None:
                    raise FileNotFoundError(key)
                a, _ = preproc(im, (640, 640))
                a = a.astype(np.uint8)
            self.cache[key] = a
        t = torch.from_numpy(self.cache[key]).cuda().float()
        return t / 255 if self.name == "mobilevit_xxs" else t

    def batches(self, rows):
        for i in range(0, len(rows), self.batch):
            sub = rows[i:i+self.batch]
            yield torch.stack([self.tensor(r) for r in sub]), sub

    def calibrate_rows(self, n):
        groups = {}
        for r in self.splits["train"]:
            c = r[1] if self.name == "mobilevit_xxs" else r["label"]
            groups.setdefault(c, []).append(r)
        rng = random.Random(SEED)
        selected = []
        for c in sorted(groups):
            g = groups[c].copy()
            rng.shuffle(g)
            selected.extend(g[:n // len(groups)])
        rng.shuffle(selected)
        return selected

    @torch.inference_mode()
    def evaluate(self, model, tag, split="val"):
        t0 = time.perf_counter()
        model.eval()
        if self.name == "mobilevit_xxs":
            cm = np.zeros((6, 6), dtype=int)
            preds, loss = [], 0.0
            for x, rows in self.batches(self.rows(split)):
                logits = model(x)
                y = torch.tensor([r[1] for r in rows], device="cuda")
                loss += F.cross_entropy(logits, y, reduction="sum").item()
                for r, p in zip(rows, logits.argmax(1).cpu().tolist()):
                    cm[r[1], p] += 1
                    preds.append({"file": r[0], "label": r[1], "prediction": p})
            metrics = {"top1": float(np.trace(cm) / cm.sum() * 100), "loss": loss / cm.sum(), "samples": int(cm.sum()), "confusion_matrix": cm.tolist(), "per_class": {c: float(cm[i, i] / cm[i].sum() * 100) for i, c in enumerate(self.classes)}}
        else:
            from yolox.utils.boxes import postprocess
            from pycocotools.coco import COCO
            from pycocotools.cocoeval import COCOeval
            preds = []
            for x, rows in self.batches(self.rows(split)):
                parameter = next(model.parameters(), None)
                dtype = parameter.dtype if parameter is not None else torch.float32
                outputs = postprocess(model(x.to(dtype=dtype)), 6, self.conf, self.nms)
                for r, pred in zip(rows, outputs):
                    if pred is None:
                        continue
                    pred = pred.detach().cpu().numpy()
                    ratio = min(640/r["height"], 640/r["width"])
                    boxes = pred[:, :4] / ratio
                    boxes[:, 2:] -= boxes[:, :2]
                    for p, box in zip(pred, boxes):
                        preds.append({"image_id": r["id"], "category_id": self.cat_ids[int(p[6])], "bbox": [float(v) for v in box], "score": float(p[4]*p[5])})
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                gt = COCO(str(self.annotations[split]))
                dt = gt.loadRes(preds)
                ev = COCOeval(gt, dt, "bbox")
                ev.evaluate()
                ev.accumulate()
                ev.summarize()
            precision = ev.eval["precision"]
            pc = {}
            for i, c in enumerate(self.classes):
                v, v50 = precision[:, :, i, 0, -1], precision[0, :, i, 0, -1]
                pc[c] = {"AP50_95": float(v[v > -1].mean()*100), "AP50": float(v50[v50 > -1].mean()*100)}
            metrics = {"mAP50_95": float(ev.stats[0]*100), "mAP50": float(ev.stats[1]*100), "AP75": float(ev.stats[2]*100), "samples": len(self.rows(split)), "per_class": pc}
            (self.out / f"{tag}_{split}_coco.txt").write_text(captured.getvalue(), encoding="utf-8")
        metrics.update({"tag": tag, "split": split, "elapsed_s": time.perf_counter()-t0})
        dump(self.out / f"{tag}_{split}_metrics.json", metrics)
        dump(self.out / f"{tag}_{split}_predictions.json", preds)
        log(self.name, tag, split, {k: v for k, v in metrics.items() if k in ["top1", "mAP50_95", "mAP50", "AP75", "elapsed_s"]})
        return metrics


class Observer:
    def __init__(self):
        self.samples, self.maximum, self.calls = [], 0.0, 0

    def hook(self, module, args):
        x = args[0].detach()
        self.maximum = max(self.maximum, x.abs().max().item())
        # Uniform sampling with a seeded generator. Fixed strides alias the
        # channel/token layout (especially MobileViT MLP) and are invalid here.
        flat = x.flatten()
        index = torch.randint(flat.numel(), (min(8192, flat.numel()),), device=x.device)
        self.samples.append(flat[index].float().cpu())
        self.calls += 1

    def finish(self):
        x = torch.cat(self.samples)
        if x.numel() > 262144:
            x = x[::math.ceil(x.numel()/262144)]
        result = {"max": self.maximum, "calls": self.calls, "sample_count": x.numel()}
        for bits in [8, 16]:
            qmax = 2**(bits-1)-1
            thresholds = [self.maximum]
            if bits == 8:
                thresholds += [max(self.maximum*.25, float(torch.quantile(x.abs(), q))) for q in [.999, .9995, .9999]]
            errors = []
            for threshold in thresholds:
                scale = max(threshold/qmax, 1e-12)
                err = ((torch.clamp(torch.round(x/scale), -qmax, qmax)*scale-x)**2).mean().item()
                errors.append((err, scale, threshold))
            err, scale, threshold = min(errors)
            result[f"a{bits}_scale"] = scale
            result[f"a{bits}_mse"] = err
            result[f"a{bits}_clip"] = threshold
        return result


@torch.no_grad()
def weight_quant(w, bits):
    qmax = 2**(bits-1)-1
    flat = w.flatten(1)
    maximum = flat.abs().amax(dim=1).clamp_min(1e-12)
    best_err = torch.full_like(maximum, float("inf"))
    best_scale = maximum / qmax
    for ratio in ([1.0, .975, .95, .925, .9, .875, .85, .8] if bits == 4 else [1.0, .99, .98]):
        s = maximum * ratio / qmax
        q = torch.clamp(torch.round(flat/s[:, None]), -qmax, qmax)
        err = ((q*s[:, None]-flat)**2).mean(1)
        mask = err < best_err
        best_err = torch.minimum(best_err, err)
        best_scale = torch.where(mask, s, best_scale)
    shape = [-1] + [1]*(w.ndim-1)
    qi = torch.clamp(torch.round(w/best_scale.reshape(shape)), -qmax, qmax).to(torch.int8)
    return qi, best_scale


class QuantOp(nn.Module):
    def __init__(self, source, stats):
        super().__init__()
        self.is_conv = isinstance(source, nn.Conv2d)
        self.source_spec = {k: getattr(source, k) for k in ["stride", "padding", "dilation", "groups"]} if self.is_conv else {}
        self.register_buffer("original_weight", source.weight.detach().clone())
        self.register_buffer("original_bias", source.bias.detach().clone() if source.bias is not None else torch.zeros(source.weight.shape[0], device=source.weight.device))
        self.has_bias = source.bias is not None
        self.register_buffer("w4", weight_quant(source.weight, 4)[0])
        self.register_buffer("s4", weight_quant(source.weight, 4)[1])
        self.register_buffer("w8", weight_quant(source.weight, 8)[0])
        self.register_buffer("s8", weight_quant(source.weight, 8)[1])
        self.stats = stats
        self.set_precision(8, 8)

    def set_precision(self, wbits, abits):
        self.wbits, self.abits = wbits, abits
        self.qmax = 2**(abits-1)-1
        qi, sw = (self.w4, self.s4) if wbits == 4 else (self.w8, self.s8)
        self.sx = float(self.stats[f"a{abits}_scale"])
        self.weight = qi.float()*sw.reshape([-1]+[1]*(qi.ndim-1))
        # Bias in accumulator units, ties-to-even, no silently saturated bias.
        qb = torch.round(self.original_bias/(sw*self.sx))
        if bool((qb.abs() > 2147483647).any()):
            raise OverflowError("INT32 bias overflow; widen contract rather than saturate silently")
        self.bias = qb*(sw*self.sx)

    def forward(self, x):
        xq = x if self.abits == 32 else torch.clamp(torch.round(x/self.sx), -self.qmax, self.qmax)*self.sx
        if self.is_conv:
            return F.conv2d(xq, self.weight, self.bias, **self.source_spec)
        return F.linear(xq, self.weight, self.bias)


def wrap_model(model, stats):
    ops = {}
    for name, m in list(model.named_modules()):
        if isinstance(m, (nn.Conv2d, nn.Linear)):
            q = QuantOp(m, stats[name])
            parent, _, leaf = name.rpartition(".")
            setattr(model.get_submodule(parent) if parent else model, leaf, q)
            ops[name] = q
    return ops


def protected(task, name):
    if task == "mobilevit_xxs":
        return name == "stem.conv" or name == "head.fc" or ".attn." in name
    return name == "backbone.backbone.stem.conv.conv" or any(p in name for p in ["cls_preds", "reg_preds", "obj_preds"])


def make_policy(task, ops, fraction=0.0, activation16=False):
    # Rank by relative quantized weight reconstruction error; validation is the
    # actual selection criterion, this score alone is not an accuracy claim.
    scores = []
    for name, op in ops.items():
        w = op.original_weight
        q = op.w4.float()*op.s4.reshape([-1]+[1]*(w.ndim-1))
        score = float((((w-q)**2).sum() / w.square().sum().clamp_min(1e-12)).detach())
        if not protected(task, name) and (not op.is_conv or op.source_spec["groups"] == 1):
            scores.append((score, name, w.numel()))
    scores.sort()
    target = sum(v[2] for v in scores)*fraction
    selected, count = set(), 0
    for _, name, n in scores:
        if count >= target:
            break
        selected.add(name)
        count += n
    return {name: {"weight_bits": 4 if name in selected else 8, "activation_bits": 16 if activation16 and ("attn" in name or "head" in name) else 8} for name in ops}


def apply_policy(ops, policy):
    for name, op in ops.items():
        p = policy[name]
        op.set_precision(p["weight_bits"], p["activation_bits"])


def passed(task, baseline, metrics):
    keys = ["top1"] if task == "mobilevit_xxs" else ["mAP50_95", "mAP50"]
    return all(baseline[k]-metrics[k] <= 1.0+1e-9 for k in keys)


def run(name, stage):
    seed_all()
    task = Task(name)
    if stage in ["baseline", "all"]:
        baseline = task.evaluate(task.original, "fp32")
        x = torch.stack([task.tensor(r) for r in task.rows("val")[:2]])
        with torch.inference_mode():
            a, b = task.original(x), task.model(x)
            parity = {"max_abs_error": float((a-b).abs().max()), "mean_abs_error": float((a-b).abs().mean())}
        dump(task.out / "bn_fold_parity.json", parity)
        log(name, "BN fold parity", parity)
        if parity["mean_abs_error"] > 1e-3:
            raise RuntimeError("BN folding parity failed; quantization calibration is forbidden")
    else:
        baseline = json.loads((task.out / "fp32_val_metrics.json").read_text())
    if stage == "baseline":
        return
    # Save model-independent provenance before work so interrupted runs remain auditable.
    calibration = task.calibrate_rows(192 if name == "mobilevit_xxs" else 96)
    source_files = {"checkpoint": {"path": str(task.ckpt), "sha256": sha(task.ckpt)}}
    if name != "mobilevit_xxs":
        source_files["config"] = {"path": str(task.config), "sha256": sha(task.config)}
        source_files["val_annotations"] = {"path": str(task.annotations["val"]), "sha256": sha(task.annotations["val"])}
    dump(task.out / "provenance.json", {"seed": SEED, "source_files": source_files, "checkpoint_metadata": task.meta, "preprocessing": task.preprocess, "classes": task.classes, "split_counts": {k: len(v) for k, v in task.splits.items()}, "calibration_split": "train only", "calibration_samples": calibration, "accuracy_budget_percentage_points": 1.0, "torch": torch.__version__, "device": torch.cuda.get_device_name(), "bn_pairs_folded": task.fused_count})
    stats_path = task.out / "calibration.json"
    if stats_path.exists():
        stats = json.loads(stats_path.read_text())
        log(name, "reusing calibration")
    else:
        obs, hooks = {}, []
        for n, m in task.model.named_modules():
            if isinstance(m, (nn.Conv2d, nn.Linear)):
                obs[n] = Observer()
                hooks.append(m.register_forward_pre_hook(obs[n].hook))
        with torch.inference_mode():
            for x, _ in task.batches(calibration):
                task.model(x)
        for h in hooks:
            h.remove()
        stats = {n: o.finish() for n, o in obs.items()}
        dump(stats_path, stats)
        log(name, "calibrated", len(stats), "Conv/Linear inputs")
    ops = wrap_model(task.model, stats)
    candidates = []
    for fraction in [0.0, .025, .05, .1, .25, .5, .75, 1.0]:
        tag = "w8a8" if fraction == 0 else f"mixed_w4_fraction_{fraction*100:g}"
        policy = make_policy(name, ops, fraction)
        apply_policy(ops, policy)
        metric_path = task.out / f"{tag}_val_metrics.json"
        metrics = json.loads(metric_path.read_text()) if metric_path.exists() else task.evaluate(task.model, tag)
        ok = passed(name, baseline, metrics)
        wbytes = sum(math.ceil(op.original_weight.numel()*policy[n]["weight_bits"]/8) for n, op in ops.items())
        candidate = {"tag": tag, "fraction_requested": fraction, "passes_budget": ok, "packed_weight_bytes": wbytes, "metrics": metrics, "policy": policy}
        candidates.append(candidate)
        dump(task.out / "candidates.json", candidates)
    passing = [c for c in candidates if c["passes_budget"]]
    if not passing:
        # A16 only where A8 activation clipping is most damaging. A16 Conv/Linear
        # requires a wider accumulator than the existing ResNet engine.
        policy = make_policy(name, ops, 0)
        ranked = sorted(stats, key=lambda n: stats[n]["a8_mse"] / max(stats[n]["max"]**2, 1e-20), reverse=True)
        for n in ranked[:max(1, len(ranked)//3)]:
            policy[n]["activation_bits"] = 16
        apply_policy(ops, policy)
        metrics = task.evaluate(task.model, "w8_mixed_a8_a16")
        c = {"tag": "w8_mixed_a8_a16", "passes_budget": passed(name, baseline, metrics), "packed_weight_bytes": sum(op.original_weight.numel() for op in ops.values()), "metrics": metrics, "policy": policy}
        candidates.append(c)
        dump(task.out / "candidates.json", candidates)
        passing = [c for c in candidates if c["passes_budget"]]
    if not passing:
        if name == "mobilevit_xxs":
            # Start from high precision, then validate each proposed A16->A8
            # change cumulatively. The held-out test split is not used here.
            policy = {n: {"weight_bits": 8, "activation_bits": 16} for n in ops}
            apply_policy(ops, policy)
            metrics = task.evaluate(task.model, "w8a16_anchor")
            if not passed(name, baseline, metrics):
                raise RuntimeError("Even W8A16 failed accuracy gate")
            trials = []
            ranked = sorted(stats, key=lambda n: stats[n]["a8_mse"] / max(stats[n]["max"]**2, 1e-20))
            for n in ranked:
                ops[n].set_precision(8, 8)
                m = task.evaluate(task.model, f"a8_trial_{len(trials):02d}")
                # Keep val Top-1 unchanged for activation demotions. Weight
                # search below may spend the user-approved 1pp budget.
                accepted = m["top1"] >= baseline["top1"] - 1e-9
                if accepted:
                    policy[n]["activation_bits"] = 8
                else:
                    ops[n].set_precision(8, 16)
                trials.append({"layer": n, "accepted_a8": accepted, "top1": m["top1"]})
            dump(task.out / "activation_sensitivity.json", trials)
            for fraction in [0, .025, .05, .1, .25, .5, .75, 1.0]:
                p = make_policy(name, ops, fraction)
                for n in p:
                    p[n]["activation_bits"] = policy[n]["activation_bits"]
                apply_policy(ops, p)
                tag = f"mixed_a8_a16_w4_{fraction*100:g}"
                m = task.evaluate(task.model, tag)
                candidates.append({"tag": tag, "passes_budget": passed(name, baseline, m), "packed_weight_bytes": sum(math.ceil(o.original_weight.numel()*p[n]["weight_bits"]/8) for n,o in ops.items()), "metrics": m, "policy": p})
            dump(task.out / "candidates.json", candidates)
            passing = [c for c in candidates if c["passes_budget"]]
    if not passing:
        raise RuntimeError("PTQ failed the 1 percentage point gate; no deployable package promoted")
    selected = min(passing, key=lambda c: c["packed_weight_bytes"])
    apply_policy(ops, selected["policy"])
    dump(task.out / "selected_policy.json", selected)
    log(name, "SELECTED", selected["tag"], selected["packed_weight_bytes"], "packed weight bytes")
    if name == "mobilevit_xxs":
        task.evaluate(task.original, "fp32", "test")
        task.evaluate(task.model, "selected", "test")
    export_package(task, ops, selected)


def export_package(task, ops, selected):
    """Separate compact integer storage from the executable FP32 QDQ reference."""
    manifest, payload, quant = [], bytearray(), {}
    rows = []
    for name, op in ops.items():
        qi, sw = (op.w4, op.s4) if op.wbits == 4 else (op.w8, op.s8)
        arr = qi.cpu().numpy().reshape(-1)
        if op.wbits == 4:
            u = (arr.astype(np.int16) & 15).astype(np.uint8)
            if len(u) % 2:
                u = np.pad(u, (0, 1))
            data = (u[0::2] | (u[1::2] << 4)).tobytes()
        else:
            data = arr.tobytes()
        # 64-byte aligned tensors for future burst loading.
        payload.extend(bytes((-len(payload)) % 64))
        offset = len(payload)
        payload.extend(data)
        qb = torch.round(op.original_bias/(sw*op.sx)).to(torch.int32).cpu()
        bound = qi.to(torch.int64).flatten(1).abs().sum(1)*op.qmax + qb.cuda().to(torch.int64).abs()
        accumulator_bits = max(32, int(math.ceil(math.log2(int(bound.max().item())+1)))+1)
        desc = {"name": name, "kind": "Conv" if op.is_conv else "Linear", "shape": list(qi.shape), "weight_bits": op.wbits, "activation_bits": op.abits, "weight_offset": offset, "weight_bytes": len(data), "activation_scale": op.sx, "weight_scales": sw.cpu().tolist(), "bias_int32": qb.tolist(), "accumulator_bits_required_worst_case": accumulator_bits, "conv": op.source_spec}
        manifest.append(desc)
        quant[name] = {"weight_int": qi.cpu(), "weight_scale": sw.cpu(), "bias_int32": qb, "activation_scale": op.sx, "weight_bits": op.wbits, "activation_bits": op.abits}
        rows.append({k: desc[k] for k in ["name", "kind", "weight_bits", "activation_bits", "weight_offset", "weight_bytes", "activation_scale", "accumulator_bits_required_worst_case"]})
    (task.out / "weights_packed.bin").write_bytes(payload)
    torch.save({"quantized_ops": quant, "reference_state": {k: v.cpu() for k, v in task.model.state_dict().items()}, "selected_policy": selected["policy"]}, task.out / "quantized_reference.pth")
    with open(task.out / "layer_precision.csv", "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    contract = {"format": "NEU_PTQ_REFERENCE_V1", "model": task.name, "layers": manifest, "rounding": "round-to-nearest ties-to-even", "activation_quantization": "symmetric per-tensor signed, zero_point=0; narrow range [-127,127] or [-32767,32767]", "weight_quantization": "symmetric per-output-channel, zero_point=0; INT4 [-7,7], INT8 [-127,127]", "int4_packing": "two signed two's-complement nibbles per byte, first element in LOW nibble, C-order OIHW/OCIC, padding nibble zero", "bias": "INT32 round(bias/(input_scale*weight_scale[channel]))", "alignment_bytes": 64, "reference_compute": "FP32 Conv/Linear on QDQ values; not an integer RTL or integer overflow verification", "fp32_islands": ["SiLU", "normalization not folded into convolution", "residual/concat glue", "attention QK/AV matmul and softmax (MobileViT only)", "detector sigmoid/exp/decode/NMS (YOLOX only)"], "preprocessing": task.preprocess, "classes": task.classes, "weights_packed_sha256": sha(task.out / "weights_packed.bin"), "original_checkpoint_sha256": sha(task.ckpt), "validation_budget_pass": True, "selected_candidate": selected["tag"]}
    dump(task.out / "model_manifest.json", contract)
    # Verify each stored integer tensor, including sign restoration of INT4.
    for d in manifest:
        raw = payload[d["weight_offset"]:d["weight_offset"]+d["weight_bytes"]]
        if d["weight_bits"] == 4:
            u = np.frombuffer(raw, dtype=np.uint8)
            n = np.stack([u & 15, u >> 4], axis=1).flatten().astype(np.int8)
            a = np.where(n >= 8, n.astype(np.int16)-16, n).astype(np.int8)
        else:
            a = np.frombuffer(raw, dtype=np.int8)
        expected = quant[d["name"]]["weight_int"].numpy().flatten()
        np.testing.assert_array_equal(a[:len(expected)], expected)
    dump(task.out / "packing_verification.json", {"layers_verified": len(manifest), "all_integer_weights_roundtrip_exact": True, "payload_bytes": len(payload)})
    log(task.name, "integer package exported, packed roundtrip PASS")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--model", choices=["yolox_s_a"], required=True)
    p.add_argument("--stage", choices=["all", "baseline", "quantize"], default="all")
    args = p.parse_args()
    run(args.model, args.stage)
