"""Controlled NEU-DET training; run each experiment manually."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import torch
import ultralytics
import yaml
from ultralytics import YOLO
from ultralytics.cfg import DEFAULT_CFG_DICT, get_cfg


ROOT = Path(__file__).resolve().parent
AI_ROOT = Path(r"D:\AI\fpga_ai")
V3_ARGS = AI_ROOT / "checkpoints/yolov8n_neu_det_416_v3/args.yaml"
COCO_WEIGHTS = AI_ROOT / "yolov8n.pt"
DATA = AI_ROOT / "datasets/NEU-DET-YOLO/data.yaml"
EXPECTED_VERSION = "8.4.174"
EXPECTED_COUNTS = {"train": 1260, "val": 270, "test": 270}
EXPECTED_CLASSES = [
    "crazing", "inclusion", "patches", "pitted_surface",
    "rolled-in_scale", "scratches",
]
EXPERIMENTS = {
    "baseline": {"scale": 0.5, "mosaic": 1.0},
    "scale03": {"scale": 0.3, "mosaic": 1.0},
    "mosaic05": {"scale": 0.5, "mosaic": 0.5},
}


def training_config(experiment: str, seed: int) -> dict:
    for path in (V3_ARGS, COCO_WEIGHTS, DATA):
        if not path.is_file():
            raise FileNotFoundError(path)
    if ultralytics.__version__ != EXPECTED_VERSION:
        raise RuntimeError(
            f"Ultralytics {ultralytics.__version__}; V3 used {EXPECTED_VERSION}. "
            r"Use D:\AI\.venv\Scripts\python.exe for this comparison."
        )

    with V3_ARGS.open(encoding="utf-8") as stream:
        original = yaml.safe_load(stream)
    unknown = set(original) - set(DEFAULT_CFG_DICT) - {"save_dir"}
    if unknown:
        raise ValueError(f"Unsupported V3 configuration keys: {sorted(unknown)}")
    excluded = {"save_dir", "cfg", "model", "mode", "task"}
    params = {key: value for key, value in original.items() if key not in excluded}
    params.update(
        data=str(DATA), epochs=100, imgsz=416, batch=16,
        device=0, workers=0, patience=25, seed=seed,
        deterministic=True, optimizer="auto", pretrained=True,
        resume=False, val=True, split="val",
        project=str(ROOT / "runs"), name=f"{experiment}_seed{seed}",
        exist_ok=False,
        **EXPERIMENTS[experiment],
    )
    get_cfg(overrides=params)  # Validate arguments without constructing a model.
    return params


def check_inputs(params: dict, check_only: bool) -> Path:
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable in this Python environment.")
    with DATA.open(encoding="utf-8") as stream:
        dataset = yaml.safe_load(stream)
    names = dataset["names"]
    ordered_names = [names[key] for key in sorted(names)] if isinstance(names, dict) else names
    if ordered_names != EXPECTED_CLASSES:
        raise ValueError(f"Unexpected class order: {ordered_names}")
    dataset_root = Path(dataset["path"])
    if not dataset_root.is_absolute():
        dataset_root = DATA.parent / dataset_root
    counts = {}
    for split, expected in EXPECTED_COUNTS.items():
        image_dir = dataset_root / dataset[split]
        if not image_dir.is_dir():
            raise FileNotFoundError(image_dir)
        count = sum(
            path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"}
            for path in image_dir.rglob("*")
        )
        if count != expected:
            raise ValueError(f"{split}: expected {expected} images, found {count}")
        counts[split] = count

    output = Path(params["project"]) / params["name"]
    if output.exists() and not check_only:
        raise FileExistsError(
            f"Run already exists: {output}\n"
            "This command starts a fresh experiment. Keep the existing results; "
            "resume interrupted training from its weights/last.pt instead."
        )
    print(f"Python: {sys.executable}")
    print(f"PyTorch: {torch.__version__}; Ultralytics: {ultralytics.__version__}")
    print(f"GPU: {torch.cuda.get_device_name(0)}")
    print(f"Initial weights: {COCO_WEIGHTS}")
    print(f"Dataset: {DATA}; counts: {counts}")
    print(
        f"imgsz={params['imgsz']} batch={params['batch']} epochs={params['epochs']} "
        f"patience={params['patience']} seed={params['seed']} "
        f"scale={params['scale']} mosaic={params['mosaic']}"
    )
    print(f"Output: {output}")
    print("Validation split: val; no automatic test-set evaluation.")
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment", required=True, choices=EXPERIMENTS)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--check", action="store_true", help="Check configuration and GPU only.")
    args = parser.parse_args()
    if args.seed < 0:
        parser.error("--seed must be non-negative")
    params = training_config(args.experiment, args.seed)
    output = check_inputs(params, args.check)
    if args.check:
        print("CHECK PASSED. Training was not started.")
        return

    # Each experiment starts from the same COCO checkpoint, never V3 best.pt.
    model = YOLO(str(COCO_WEIGHTS))
    metrics = model.train(**params)
    print(f"Best weights: {output / 'weights/best.pt'}")
    if metrics is not None:
        print(
            f"Best validation: mAP50={metrics.box.map50:.5f}, "
            f"mAP50-95={metrics.box.map:.5f}, "
            f"precision={metrics.box.mp:.5f}, recall={metrics.box.mr:.5f}"
        )
    print("Compare validation metrics first. best.pt is selected by mAP50-95.")


if __name__ == "__main__":
    main()
