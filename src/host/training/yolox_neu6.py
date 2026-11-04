"""YOLOX-s MixUp ablation, same NEU-DET split and training settings.
Published: YOLOX-s, 100 epochs, 640x640, batch 16, 80/20; other settings
inherited from the checked-out YOLOX version, except MixUp explicitly disabled.
"""
import os
from yolox.exp import Exp as BaseExp

class Exp(BaseExp):
    def __init__(self):
        super().__init__()
        self.depth = 0.33
        self.width = 0.5
        self.num_classes = 6
        self.exp_name = "yolox_s_neu6"
        self.enable_mixup = False  # Ablation: MixUp OFF; keep all other settings inherited.
        self.data_dir = str(__import__("pathlib").Path(__file__).resolve().parents[3] / "data/datasets/neu_det")
        self.output_dir = str(__import__("pathlib").Path(__file__).resolve().parents[3] / "work/training")
        self.train_ann = "instances_train2017.json"
        self.val_ann = "instances_val2017.json"
        self.input_size = (640, 640)
        self.test_size = (640, 640)
        self.max_epoch = 100
        self.eval_interval = 1
        self.data_num_workers = 2  # Windows adaptation
        # Other augmentation and optimizer settings inherit YOLOX defaults.


_BaseExp = Exp

class Exp(_BaseExp):
    def __init__(self):
        super().__init__()
        self.seed = 2022
        self.mosaic_prob = 1.0
        self.enable_mixup = False
        self.exp_name = "yolox_s_neu6"
