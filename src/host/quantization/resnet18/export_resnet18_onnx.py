from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn as nn

from torchvision.models import resnet18


# ============================================================
# 1. 路径
# ============================================================

PROJECT_ROOT = Path(__file__).resolve().parents[4]

CHECKPOINT_PATH = PROJECT_ROOT / "data/models/checkpoints/resnet18_neu6.pth"

ONNX_DIR = PROJECT_ROOT / "work/quantization/resnet18"
ONNX_DIR.mkdir(parents=True, exist_ok=True)

ONNX_PATH = (
    ONNX_DIR
    / "resnet18_neu_fp32.onnx"
)


# ============================================================
# 2. 设备
# ============================================================

device = torch.device(
    "cuda" if torch.cuda.is_available()
    else "cpu"
)

print("使用设备：", device)


# ============================================================
# 3. 创建与训练时完全一致的 ResNet18
# ============================================================

model = resnet18(weights=None)

model.fc = nn.Linear(
    model.fc.in_features,
    6
)


# ============================================================
# 4. 加载我们训练好的最佳权重
# ============================================================

checkpoint = torch.load(
    CHECKPOINT_PATH,
    map_location=device,
    weights_only=False
)

model.load_state_dict(
    checkpoint["model_state_dict"]
)

model = model.to(device)

# 导出推理模型必须进入 eval 模式
model.eval()


print("已加载模型：")
print("Architecture:", checkpoint["architecture"])
print("Best Epoch:", checkpoint["epoch"])
print("Val Accuracy:", checkpoint["val_accuracy"])
print("Class Mapping:", checkpoint["class_to_idx"])


# ============================================================
# 5. 构造一个示例输入
#
# ResNet18正式输入：
# Batch × Channel × Height × Width
# 1 × 3 × 224 × 224
# ============================================================

dummy_input = torch.randn(
    1,
    3,
    224,
    224,
    dtype=torch.float32,
    device=device
)


# ============================================================
# 6. 先跑一次 PyTorch
# ============================================================

with torch.no_grad():
    pytorch_output = model(
        dummy_input
    )

print(
    "\nPyTorch输出尺寸：",
    pytorch_output.shape
)


# ============================================================
# 7. 导出 ONNX
#
# PyTorch 2.14 推荐 dynamo=True
# ============================================================

# 新的 ONNX exporter 在 CPU 上导出通常更稳妥，
# 因此这里复制模型和输入到 CPU。
export_model = model.cpu()

export_input = dummy_input.cpu()


onnx_program = torch.onnx.export(
    export_model,

    (
        export_input,
    ),

    input_names=[
        "input"
    ],

    output_names=[
        "output"
    ],

    dynamo=True
)


# 保存 ONNX
onnx_program.save(
    ONNX_PATH
)

print(
    "\nONNX导出完成："
)
print(
    ONNX_PATH
)


# ============================================================
# 8. 检查 ONNX 文件是否符合规范
# ============================================================

onnx_model = onnx.load(
    ONNX_PATH
)

onnx.checker.check_model(
    onnx_model
)

print(
    "ONNX结构检查：通过"
)


# ============================================================
# 9. 用 ONNX Runtime 推理
# ============================================================

session = ort.InferenceSession(
    str(ONNX_PATH),
    providers=[
        "CPUExecutionProvider"
    ]
)


onnx_input = {
    session.get_inputs()[0].name:
        export_input.numpy()
}


onnx_output = session.run(
    None,
    onnx_input
)[0]


# ============================================================
# 10. 用完全相同输入重新计算 PyTorch结果
# ============================================================

export_model.eval()

with torch.no_grad():

    pytorch_output_cpu = (
        export_model(export_input)
        .numpy()
    )


# ============================================================
# 11. 比较 PyTorch 和 ONNX
# ============================================================

max_abs_error = np.max(
    np.abs(
        pytorch_output_cpu
        - onnx_output
    )
)

print(
    "\nPyTorch输出："
)
print(
    pytorch_output_cpu
)

print(
    "\nONNX输出："
)
print(
    onnx_output
)

print(
    "\n最大绝对误差：",
    max_abs_error
)


np.testing.assert_allclose(
    pytorch_output_cpu,
    onnx_output,
    rtol=1e-4,
    atol=1e-5
)

print(
    "\n===================================="
)
print(
    "PyTorch 与 ONNX 输出一致！"
)
print(
    "ONNX 转换验证成功。"
)
print(
    "===================================="
)