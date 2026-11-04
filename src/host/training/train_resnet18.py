from pathlib import Path
import time
import random

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim

from torch.utils.data import DataLoader
from torchvision import datasets, transforms
from torchvision.models import resnet18, ResNet18_Weights


# ============================================================
# 1. 固定随机种子
# ============================================================

SEED = 42

random.seed(SEED)
np.random.seed(SEED)

torch.manual_seed(SEED)
torch.cuda.manual_seed_all(SEED)

# 为了让 GPU 计算尽可能可复现
torch.backends.cudnn.deterministic = True
torch.backends.cudnn.benchmark = False


# ============================================================
# 2. 路径
# ============================================================

PROJECT_ROOT = Path(__file__).resolve().parents[3]

DATA_ROOT = (
    PROJECT_ROOT
    / "data"
    / "datasets"
    / "neu_cls"
)

TRAIN_DIR = DATA_ROOT / "train"
VAL_DIR = DATA_ROOT / "val"
TEST_DIR = DATA_ROOT / "test"

CHECKPOINT_DIR = PROJECT_ROOT / "work" / "training" / "resnet18"
CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)

BEST_MODEL_PATH = (
    CHECKPOINT_DIR
    / "resnet18_neu_best.pth"
)


# ============================================================
# 3. 训练参数
# ============================================================

BATCH_SIZE = 32
EPOCHS = 30
LEARNING_RATE = 1e-4
WEIGHT_DECAY = 1e-4

NUM_CLASSES = 6

# Windows 下先设为 0，最稳定
NUM_WORKERS = 0


# ============================================================
# 4. 设备
# ============================================================

device = torch.device(
    "cuda" if torch.cuda.is_available()
    else "cpu"
)

print("====================================")
print("使用设备：", device)

if torch.cuda.is_available():
    print(
        "GPU：",
        torch.cuda.get_device_name(0)
    )

print("随机种子：", SEED)
print("====================================")


# ============================================================
# 5. 数据增强
#
# ResNet18 的 ImageNet 预训练模型默认输入：
# 224×224×3
#
# NEU 虽然是灰度图，
# ImageFolder/PIL 读取后这里统一转为 RGB 三通道。
# ============================================================

train_transform = transforms.Compose([

    transforms.Lambda(
        lambda img: img.convert("RGB")
    ),

    transforms.Resize((256, 256)),

    transforms.RandomResizedCrop(
        224,
        scale=(0.80, 1.0)
    ),

    transforms.RandomHorizontalFlip(
        p=0.5
    ),

    transforms.RandomVerticalFlip(
        p=0.5
    ),

    transforms.RandomRotation(
        degrees=10
    ),

    transforms.ToTensor(),

    # ImageNet 预训练模型对应的标准化参数
    transforms.Normalize(
        mean=[
            0.485,
            0.456,
            0.406
        ],
        std=[
            0.229,
            0.224,
            0.225
        ]
    )
])


# 验证集和测试集不能使用随机增强
eval_transform = transforms.Compose([

    transforms.Lambda(
        lambda img: img.convert("RGB")
    ),

    transforms.Resize((256, 256)),

    transforms.CenterCrop(224),

    transforms.ToTensor(),

    transforms.Normalize(
        mean=[
            0.485,
            0.456,
            0.406
        ],
        std=[
            0.229,
            0.224,
            0.225
        ]
    )
])


# ============================================================
# 6. 创建数据集
# ============================================================

train_dataset = datasets.ImageFolder(
    TRAIN_DIR,
    transform=train_transform
)

val_dataset = datasets.ImageFolder(
    VAL_DIR,
    transform=eval_transform
)

test_dataset = datasets.ImageFolder(
    TEST_DIR,
    transform=eval_transform
)


print("\n类别对应关系：")

for name, index in train_dataset.class_to_idx.items():
    print(
        f"{index} -> {name}"
    )


print("\n数据集数量：")
print(
    "Train：",
    len(train_dataset)
)
print(
    "Val：  ",
    len(val_dataset)
)
print(
    "Test： ",
    len(test_dataset)
)


# 检查三个数据集的类别映射完全相同
assert (
    train_dataset.class_to_idx
    == val_dataset.class_to_idx
    == test_dataset.class_to_idx
), "Train/Val/Test 类别映射不一致！"


# ============================================================
# 7. DataLoader
# ============================================================

# 固定 DataLoader shuffle 的随机顺序
loader_generator = torch.Generator()
loader_generator.manual_seed(SEED)

train_loader = DataLoader(
    train_dataset,
    batch_size=BATCH_SIZE,
    shuffle=True,
    num_workers=NUM_WORKERS,
    pin_memory=True,
    generator=loader_generator
)

val_loader = DataLoader(
    val_dataset,
    batch_size=BATCH_SIZE,
    shuffle=False,
    num_workers=NUM_WORKERS,
    pin_memory=True
)

test_loader = DataLoader(
    test_dataset,
    batch_size=BATCH_SIZE,
    shuffle=False,
    num_workers=NUM_WORKERS,
    pin_memory=True
)


# ============================================================
# 8. 创建 ResNet18
# ============================================================

weights = ResNet18_Weights.DEFAULT

model = resnet18(
    weights=weights
)


# 原本：
# 512 -> 1000
#
# 改成：
# 512 -> 6
model.fc = nn.Linear(
    model.fc.in_features,
    NUM_CLASSES
)

model = model.to(device)


print("\n模型最后一层：")
print(model.fc)


# ============================================================
# 9. Loss
# ============================================================

criterion = nn.CrossEntropyLoss()


# ============================================================
# 10. 优化器
#
# 这里不是只训练 FC，
# 而是让整个 ResNet18 一起 Fine-tuning
# ============================================================

optimizer = optim.AdamW(
    model.parameters(),
    lr=LEARNING_RATE,
    weight_decay=WEIGHT_DECAY
)


# ============================================================
# 11. 学习率调度
# ============================================================

scheduler = optim.lr_scheduler.CosineAnnealingLR(
    optimizer,
    T_max=EPOCHS
)


# ============================================================
# 12. 训练一个 Epoch
# ============================================================

def train_one_epoch():

    model.train()

    total_loss = 0.0
    correct = 0
    total = 0

    for images, labels in train_loader:

        images = images.to(
            device,
            non_blocking=True
        )

        labels = labels.to(
            device,
            non_blocking=True
        )

        # 清除上一轮梯度
        optimizer.zero_grad()

        # 正向传播
        outputs = model(images)

        # 计算 Loss
        loss = criterion(
            outputs,
            labels
        )

        # 反向传播
        loss.backward()

        # 更新参数
        optimizer.step()

        total_loss += (
            loss.item()
            * images.size(0)
        )

        _, predicted = torch.max(
            outputs,
            dim=1
        )

        total += labels.size(0)

        correct += (
            predicted == labels
        ).sum().item()


    epoch_loss = (
        total_loss / total
    )

    epoch_acc = (
        100.0 * correct / total
    )

    return epoch_loss, epoch_acc


# ============================================================
# 13. 验证 / 测试
# ============================================================

def evaluate(loader):

    model.eval()

    total_loss = 0.0
    correct = 0
    total = 0

    with torch.no_grad():

        for images, labels in loader:

            images = images.to(
                device,
                non_blocking=True
            )

            labels = labels.to(
                device,
                non_blocking=True
            )

            outputs = model(images)

            loss = criterion(
                outputs,
                labels
            )

            total_loss += (
                loss.item()
                * images.size(0)
            )

            _, predicted = torch.max(
                outputs,
                dim=1
            )

            total += labels.size(0)

            correct += (
                predicted == labels
            ).sum().item()


    average_loss = (
        total_loss / total
    )

    accuracy = (
        100.0 * correct / total
    )

    return average_loss, accuracy


# ============================================================
# 14. 正式训练
#
# 最佳模型选择规则：
# 1) Val Accuracy 更高优先
# 2) Val Accuracy 相同时，Val Loss 更低优先
# ============================================================

best_val_acc = 0.0
best_val_loss = float("inf")
best_epoch = 0

print("\n====================================")
print("开始训练 ResNet18")
print("====================================\n")

start_time = time.time()


for epoch in range(1, EPOCHS + 1):

    train_loss, train_acc = (
        train_one_epoch()
    )

    val_loss, val_acc = (
        evaluate(val_loader)
    )

    current_lr = (
        optimizer.param_groups[0]["lr"]
    )

    print(
        f"Epoch [{epoch:02d}/{EPOCHS}] | "
        f"LR: {current_lr:.6f} | "
        f"Train Loss: {train_loss:.4f} | "
        f"Train Acc: {train_acc:.2f}% | "
        f"Val Loss: {val_loss:.6f} | "
        f"Val Acc: {val_acc:.2f}%"
    )


    # ----------------------------
    # 判断是否为新的最佳模型
    # ----------------------------

    is_best = (
        val_acc > best_val_acc
        or
        (
            val_acc == best_val_acc
            and val_loss < best_val_loss
        )
    )

    if is_best:

        best_val_acc = val_acc
        best_val_loss = val_loss
        best_epoch = epoch

        checkpoint = {

            "architecture":
                "resnet18",

            "epoch":
                epoch,

            "model_state_dict":
                model.state_dict(),

            "optimizer_state_dict":
                optimizer.state_dict(),

            "val_accuracy":
                val_acc,

            "val_loss":
                val_loss,

            "class_to_idx":
                train_dataset.class_to_idx,

            "num_classes":
                NUM_CLASSES,

            "seed":
                SEED
        }

        torch.save(
            checkpoint,
            BEST_MODEL_PATH
        )

        print(
            f"  >>> 保存新的最佳模型 | "
            f"Val Acc = {val_acc:.2f}% | "
            f"Val Loss = {val_loss:.6f}"
        )


    scheduler.step()


# ============================================================
# 15. 训练结束
# ============================================================

elapsed = time.time() - start_time

print("\n====================================")
print("训练完成")
print(
    f"最佳 Epoch：{best_epoch}"
)
print(
    f"最佳 Val Acc："
    f"{best_val_acc:.2f}%"
)
print(
    f"最佳 Val Loss："
    f"{best_val_loss:.6f}"
)
print(
    f"训练耗时："
    f"{elapsed / 60:.2f} 分钟"
)
print(
    f"模型保存位置："
    f"{BEST_MODEL_PATH}"
)
print("====================================")


# ============================================================
# 16. 加载最佳模型
# ============================================================

checkpoint = torch.load(
    BEST_MODEL_PATH,
    map_location=device,
    weights_only=False
)

model.load_state_dict(
    checkpoint[
        "model_state_dict"
    ]
)


# ============================================================
# 17. 最终 Test
#
# Test 集只在模型确定后测一次
# ============================================================

test_loss, test_acc = evaluate(
    test_loader
)

print("\n====================================")
print("最终测试结果")
print(
    f"Test Loss："
    f"{test_loss:.6f}"
)
print(
    f"Test Accuracy："
    f"{test_acc:.2f}%"
)
print("====================================")
