"""Train YOLO12n on the prepared NEU-DET dataset."""
import argparse
from pathlib import Path

import torch
from ultralytics import YOLO

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--name", default="yolo12n_neu_baseline")
    args = parser.parse_args()
    dataset_yaml = ROOT / "data.yaml"
    if not dataset_yaml.exists():
        raise FileNotFoundError("data.yaml is missing. Run: python prepare_neu.py")
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable. Check your PyTorch/CUDA installation first.")
    print("Training GPU:", torch.cuda.get_device_name(0))
    model = YOLO("yolo12n.pt")  # Official COCO-pretrained detection weights
    model.train(
        data=str(dataset_yaml),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        workers=args.workers,
        device=0,
        seed=42,
        deterministic=True,
        patience=30,
        plots=True,
        project=str(ROOT / "runs" / "detect"),
        name=args.name,
    )


if __name__ == "__main__":  # Necessary for safe Windows script launches
    main()
