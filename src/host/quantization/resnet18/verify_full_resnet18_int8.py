from pathlib import Path
import copy
import math
import argparse

import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn.functional as F

from onnx import helper, numpy_helper, TensorProto
from PIL import Image
from torchvision import transforms


# ============================================================
# 0. 路径
# ============================================================

PROJECT_ROOT = Path(__file__).resolve().parents[4]

MODEL_PATH = PROJECT_ROOT / "data/models/onnx/resnet18_int8_qdq.onnx"

TEST_DIR = PROJECT_ROOT / "data/datasets/neu_cls/test"

DEBUG_MODEL_PATH = PROJECT_ROOT / "work/quantization/resnet18/debug_integer.onnx"


# ============================================================
# 1. 加载模型
# ============================================================

model = onnx.load(MODEL_PATH)
graph = model.graph

initializers = {
    init.name: numpy_helper.to_array(init)
    for init in graph.initializer
}

producer = {}
consumers = {}

for node in graph.node:

    for out_name in node.output:
        producer[out_name] = node

    for in_name in node.input:
        consumers.setdefault(
            in_name,
            []
        ).append(node)


# ============================================================
# 2. 辅助函数
# ============================================================

def parse_dq(output_name):

    node = producer.get(output_name)

    if node is None:
        raise RuntimeError(
            f"找不到 {output_name} 的产生节点"
        )

    if node.op_type != "DequantizeLinear":
        raise RuntimeError(
            f"{output_name} 不是 DequantizeLinear 输出，"
            f"实际为 {node.op_type}"
        )

    q_name = node.input[0]
    scale_name = node.input[1]

    zp_name = (
        node.input[2]
        if len(node.input) >= 3
        else None
    )

    scale = np.asarray(
        initializers[scale_name]
    )

    if (
        zp_name is not None
        and zp_name in initializers
    ):

        zp = np.asarray(
            initializers[zp_name]
        )

    else:

        zp = np.array(
            0,
            dtype=np.int8
        )

    q_tensor = (
        np.asarray(initializers[q_name])
        if q_name in initializers
        else None
    )

    return {
        "q_name": q_name,
        "q_tensor": q_tensor,
        "scale": scale,
        "zero_point": zp,
    }


def find_nearest_quantize(
    tensor_name,
    max_depth=8
):

    queue = [
        (
            tensor_name,
            []
        )
    ]

    visited = set()

    while queue:

        current, path = queue.pop(0)

        if current in visited:
            continue

        visited.add(current)

        if len(path) > max_depth:
            continue

        for node in consumers.get(
            current,
            []
        ):

            if node.op_type == "QuantizeLinear":

                scale = np.asarray(
                    initializers[
                        node.input[1]
                    ]
                )

                if (
                    len(node.input) >= 3
                    and node.input[2]
                    in initializers
                ):

                    zp = np.asarray(
                        initializers[
                            node.input[2]
                        ]
                    )

                else:

                    zp = np.array(
                        0,
                        dtype=np.int8
                    )

                return {
                    "node": node,
                    "q_name": node.output[0],
                    "scale": scale,
                    "zero_point": zp,
                    "path": path,
                }

            new_path = (
                path
                + [node.op_type]
            )

            for out_name in node.output:

                queue.append(
                    (
                        out_name,
                        new_path
                    )
                )

    return None


def get_attr_ints(
    node,
    name,
    default
):

    for attr in node.attribute:

        if attr.name == name:

            return list(
                attr.ints
            )

    return list(default)


def get_attr_int(
    node,
    name,
    default
):

    for attr in node.attribute:

        if attr.name == name:

            return int(
                attr.i
            )

    return default


# ============================================================
# 3. 浮点倍率 -> Integer Multiplier + Shift
# ============================================================

def quantize_real_multiplier(m):

    if m == 0:

        return (
            0,
            0,
            0.0
        )

    significand, exponent = math.frexp(
        float(m)
    )

    multiplier = int(
        round(
            significand
            * (1 << 31)
        )
    )

    if multiplier == (1 << 31):

        multiplier //= 2
        exponent += 1

    shift = (
        31
        - exponent
    )

    approx = (
        multiplier
        / (2.0 ** shift)
    )

    return (
        multiplier,
        shift,
        approx
    )


# ============================================================
# 4. Torch INT64 Round-To-Nearest-Even
# ============================================================

def round_shift_rne_tensor(
    value,
    shift
):

    value = value.to(
        torch.int64
    )

    if shift <= 0:

        return (
            value
            << (-shift)
        )

    negative = (
        value < 0
    )

    a = torch.abs(
        value
    )

    # shift > 63 时：
    # 当前int64数值一定小于0.5 LSB
    if shift > 63:

        return torch.zeros_like(
            value,
            dtype=torch.int64
        )

    # shift = 63 单独处理
    if shift == 63:

        half = (
            1 << 62
        )

        result = (
            a > half
        ).to(
            torch.int64
        )

        return torch.where(
            negative,
            -result,
            result
        )

    quotient = (
        a >> shift
    )

    mask = (
        (1 << shift)
        - 1
    )

    remainder = (
        a & mask
    )

    half = (
        1
        << (shift - 1)
    )

    round_up = (
        (remainder > half)
        |
        (
            (remainder == half)
            &
            ((quotient & 1) == 1)
        )
    )

    quotient = (
        quotient
        + round_up.to(
            torch.int64
        )
    )

    return torch.where(
        negative,
        -quotient,
        quotient
    )


# ============================================================
# 5. Requant
# ============================================================

def requant_per_channel(
    acc,
    real_multipliers,
    zero_point=0
):

    # acc:
    # [N,C,H,W] 或 [N,C]

    output = torch.empty_like(
        acc,
        dtype=torch.int64
    )

    channels = (
        acc.shape[1]
    )

    for c in range(channels):

        multiplier, shift, _ = (
            quantize_real_multiplier(
                real_multipliers[c]
            )
        )

        product = (
            acc[:, c]
            * int(multiplier)
        )

        scaled = round_shift_rne_tensor(
            product,
            shift
        )

        output[:, c] = (
            scaled
            + int(zero_point)
        )

    output = torch.clamp(
        output,
        -128,
        127
    )

    return output.to(
        torch.int8
    )


# ============================================================
# 6. 输入预处理
# ============================================================

transform = transforms.Compose(
    [
        transforms.Lambda(
            lambda img:
            img.convert("RGB")
        ),

        transforms.Resize(
            256
        ),

        transforms.CenterCrop(
            224
        ),

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
    ]
)


def preprocess(image_path):

    image = Image.open(
        image_path
    )

    return (
        transform(image)
        .unsqueeze(0)
        .numpy()
        .astype(np.float32)
    )


# ============================================================
# 7. 输入 FP32 -> INT8
# ============================================================

def quantize_input(
    x_fp32,
    scale,
    zero_point
):

    q = np.rint(
        x_fp32 / scale
    )

    q = (
        q
        + zero_point
    )

    q = np.clip(
        q,
        -128,
        127
    )

    return torch.from_numpy(
        q.astype(np.int8)
    )


# ============================================================
# 8. 整个模型纯整数执行
# ============================================================

def run_integer_model(
    x_fp32,
    record_trace=False
):

    tensors = {}
    trace = []

    fused_reshape_names = set()


    # --------------------------------------------------------
    # 找第一层 Conv 的输入量化参数
    # --------------------------------------------------------

    first_conv = None

    for node in graph.node:

        if node.op_type == "Conv":

            first_conv = node
            break


    input_info = parse_dq(
        first_conv.input[0]
    )


    S_input = float(
        input_info[
            "scale"
        ].reshape(-1)[0]
    )

    Z_input = int(
        input_info[
            "zero_point"
        ].reshape(-1)[0]
    )


    input_q = quantize_input(
        x_fp32,
        S_input,
        Z_input
    )


    tensors[
        input_info["q_name"]
    ] = input_q


    semantic_index = 0


    # ========================================================
    # 遍历49个真正算子
    # ========================================================

    for node in graph.node:

        if node.op_type not in {
            "Conv",
            "Relu",
            "Add",
            "MaxPool",
            "ReduceMean",
            "Reshape",
            "Gemm",
        }:
            continue


        # ====================================================
        # Conv（卷积）
        # ====================================================

        if node.op_type == "Conv":

            semantic_index += 1


            x_info = parse_dq(
                node.input[0]
            )

            w_info = parse_dq(
                node.input[1]
            )


            xq = tensors[
                x_info["q_name"]
            ]


            Wq = torch.from_numpy(
                np.asarray(
                    w_info["q_tensor"]
                ).astype(np.int32)
            )


            Sx = float(
                x_info["scale"]
                .reshape(-1)[0]
            )

            Zx = int(
                x_info["zero_point"]
                .reshape(-1)[0]
            )


            Sw = (
                w_info["scale"]
                .reshape(-1)
                .astype(np.float64)
            )

            Zw = (
                w_info["zero_point"]
                .reshape(-1)
                .astype(np.int64)
            )


            # -----------------------------------------------
            # Bias
            # -----------------------------------------------

            if len(node.input) >= 3:

                b_info = parse_dq(
                    node.input[2]
                )

                Bq = torch.from_numpy(
                    np.asarray(
                        b_info["q_tensor"]
                    )
                    .reshape(-1)
                    .astype(np.int64)
                )

            else:

                Bq = torch.zeros(
                    Wq.shape[0],
                    dtype=torch.int64
                )


            # -----------------------------------------------
            # 输出量化参数
            # -----------------------------------------------

            out_info = (
                find_nearest_quantize(
                    node.output[0]
                )
            )


            Sy = float(
                out_info["scale"]
                .reshape(-1)[0]
            )

            Zy = int(
                out_info["zero_point"]
                .reshape(-1)[0]
            )


            # -----------------------------------------------
            # Conv参数
            # -----------------------------------------------

            strides = get_attr_ints(
                node,
                "strides",
                [1, 1]
            )

            pads = get_attr_ints(
                node,
                "pads",
                [0, 0, 0, 0]
            )

            dilations = get_attr_ints(
                node,
                "dilations",
                [1, 1]
            )

            groups = get_attr_int(
                node,
                "group",
                1
            )


            pad_top = pads[0]
            pad_left = pads[1]
            pad_bottom = pads[2]
            pad_right = pads[3]


            if (
                pad_top != pad_bottom
                or pad_left != pad_right
            ):

                raise RuntimeError(
                    "当前ResNet18出现非对称Padding"
                )


            # -----------------------------------------------
            # ZeroPoint 对齐
            # -----------------------------------------------

            Xcenter = (
                xq.to(torch.int32)
                - Zx
            )


            if len(Zw) == 1:

                Wcenter = (
                    Wq
                    - int(Zw[0])
                )

            else:

                zw_tensor = torch.from_numpy(
                    Zw.astype(np.int32)
                ).reshape(
                    -1,
                    1,
                    1,
                    1
                )

                Wcenter = (
                    Wq
                    - zw_tensor
                )


            # -----------------------------------------------
            # 先检查 INT32 MAC 是否安全
            #
            # 注意：
            # 巨大的Bias在Conv后再用INT64加，
            # 所以这里只检查纯MAC部分。
            # -----------------------------------------------

            input_abs_max = max(
                abs(-128 - Zx),
                abs(127 - Zx)
            )


            weight_abs_sum = (
                torch.abs(
                    Wcenter.to(torch.int64)
                )
                .reshape(
                    Wcenter.shape[0],
                    -1
                )
                .sum(dim=1)
            )


            mac_bound = int(
                (
                    weight_abs_sum.max()
                    * input_abs_max
                ).item()
            )


            if mac_bound > 2147483647:

                raise RuntimeError(
                    f"{node.name} 的纯MAC理论上超过INT32："
                    f"{mac_bound}"
                )


            # -----------------------------------------------
            # 真正整数卷积
            # INT32 × INT32 → INT32 MAC
            # -----------------------------------------------

            dot = F.conv2d(
                Xcenter,
                Wcenter,
                bias=None,
                stride=tuple(strides),
                padding=(
                    pad_top,
                    pad_left
                ),
                dilation=tuple(dilations),
                groups=groups
            )


            # -----------------------------------------------
            # 转 INT64 再加 Bias
            # -----------------------------------------------

            acc = (
                dot.to(torch.int64)
                +
                Bq.reshape(
                    1,
                    -1,
                    1,
                    1
                )
            )


            # -----------------------------------------------
            # Requant
            # -----------------------------------------------

            M = (
                Sx
                * Sw
                / Sy
            )


            qout = requant_per_channel(
                acc,
                M,
                Zy
            )


            tensors[
                out_info["q_name"]
            ] = qout


            if record_trace:

                trace.append(
                    (
                        semantic_index,
                        "Conv（卷积）",
                        out_info["q_name"],
                        qout.clone()
                    )
                )


        # ====================================================
        # ReLU（激活）
        # ====================================================

        elif node.op_type == "Relu":

            semantic_index += 1


            x_info = parse_dq(
                node.input[0]
            )

            out_info = (
                find_nearest_quantize(
                    node.output[0]
                )
            )


            Sx = float(
                x_info["scale"]
                .reshape(-1)[0]
            )

            Sy = float(
                out_info["scale"]
                .reshape(-1)[0]
            )

            Zx = int(
                x_info["zero_point"]
                .reshape(-1)[0]
            )

            Zy = int(
                out_info["zero_point"]
                .reshape(-1)[0]
            )


            if not np.isclose(
                Sx,
                Sy,
                rtol=1e-7,
                atol=0.0
            ):

                raise RuntimeError(
                    "当前ReLU输入输出Scale不一致"
                )


            if Zx != Zy:

                raise RuntimeError(
                    "当前ReLU输入输出ZeroPoint不一致"
                )


            xq = tensors[
                x_info["q_name"]
            ]


            qout = torch.maximum(
                xq,
                torch.tensor(
                    Zx,
                    dtype=torch.int8
                )
            )


            tensors[
                out_info["q_name"]
            ] = qout


            if record_trace:

                trace.append(
                    (
                        semantic_index,
                        "ReLU（激活）",
                        out_info["q_name"],
                        qout.clone()
                    )
                )


        # ====================================================
        # MaxPool（最大池化）
        # ====================================================

        elif node.op_type == "MaxPool":

            semantic_index += 1


            x_info = parse_dq(
                node.input[0]
            )

            out_info = (
                find_nearest_quantize(
                    node.output[0]
                )
            )


            Sx = float(
                x_info["scale"]
                .reshape(-1)[0]
            )

            Sy = float(
                out_info["scale"]
                .reshape(-1)[0]
            )

            Zx = int(
                x_info["zero_point"]
                .reshape(-1)[0]
            )

            Zy = int(
                out_info["zero_point"]
                .reshape(-1)[0]
            )


            if (
                not np.isclose(
                    Sx,
                    Sy,
                    rtol=1e-7,
                    atol=0
                )
                or Zx != Zy
            ):

                raise RuntimeError(
                    "MaxPool输入输出量化尺度不一致"
                )


            kernel = get_attr_ints(
                node,
                "kernel_shape",
                [1, 1]
            )

            strides = get_attr_ints(
                node,
                "strides",
                kernel
            )

            pads = get_attr_ints(
                node,
                "pads",
                [0, 0, 0, 0]
            )

            dilations = get_attr_ints(
                node,
                "dilations",
                [1, 1]
            )

            ceil_mode = get_attr_int(
                node,
                "ceil_mode",
                0
            )


            if (
                pads[0] != pads[2]
                or pads[1] != pads[3]
            ):

                raise RuntimeError(
                    "MaxPool出现非对称Padding"
                )


            xq = tensors[
                x_info["q_name"]
            ]


            qout = F.max_pool2d(
                xq.to(torch.int32),
                kernel_size=tuple(kernel),
                stride=tuple(strides),
                padding=(
                    pads[0],
                    pads[1]
                ),
                dilation=tuple(dilations),
                ceil_mode=bool(
                    ceil_mode
                )
            ).to(
                torch.int8
            )


            tensors[
                out_info["q_name"]
            ] = qout


            if record_trace:

                trace.append(
                    (
                        semantic_index,
                        "MaxPool（最大池化）",
                        out_info["q_name"],
                        qout.clone()
                    )
                )


        # ====================================================
        # Add（残差相加）
        # ====================================================

        elif node.op_type == "Add":

            semantic_index += 1


            a_info = parse_dq(
                node.input[0]
            )

            b_info = parse_dq(
                node.input[1]
            )

            out_info = (
                find_nearest_quantize(
                    node.output[0]
                )
            )


            Qa = tensors[
                a_info["q_name"]
            ].to(torch.int64)

            Qb = tensors[
                b_info["q_name"]
            ].to(torch.int64)


            Sa = float(
                a_info["scale"]
                .reshape(-1)[0]
            )

            Sb = float(
                b_info["scale"]
                .reshape(-1)[0]
            )

            Sy = float(
                out_info["scale"]
                .reshape(-1)[0]
            )


            Za = int(
                a_info["zero_point"]
                .reshape(-1)[0]
            )

            Zb = int(
                b_info["zero_point"]
                .reshape(-1)[0]
            )

            Zy = int(
                out_info["zero_point"]
                .reshape(-1)[0]
            )


            Ma = Sa / Sy
            Mb = Sb / Sy


            mult_a, shift_a, _ = (
                quantize_real_multiplier(
                    Ma
                )
            )

            mult_b, shift_b, _ = (
                quantize_real_multiplier(
                    Mb
                )
            )


            common_shift = max(
                shift_a,
                shift_b
            )


            common_mult_a = (
                mult_a
                << (
                    common_shift
                    - shift_a
                )
            )

            common_mult_b = (
                mult_b
                << (
                    common_shift
                    - shift_b
                )
            )


            numerator = (
                (Qa - Za)
                * int(common_mult_a)
                +
                (Qb - Zb)
                * int(common_mult_b)
            )


            scaled = round_shift_rne_tensor(
                numerator,
                common_shift
            )


            qout = torch.clamp(
                scaled + Zy,
                -128,
                127
            ).to(
                torch.int8
            )


            tensors[
                out_info["q_name"]
            ] = qout


            if record_trace:

                trace.append(
                    (
                        semantic_index,
                        "Add（残差相加）",
                        out_info["q_name"],
                        qout.clone()
                    )
                )


        # ====================================================
        # ReduceMean（全局平均池化）
        #
        # 与紧随其后的 Reshape 合并处理
        # ====================================================

        elif node.op_type == "ReduceMean":

            semantic_index += 1


            x_info = parse_dq(
                node.input[0]
            )

            xq = tensors[
                x_info["q_name"]
            ].to(torch.int64)


            Sx = float(
                x_info["scale"]
                .reshape(-1)[0]
            )

            Zx = int(
                x_info["zero_point"]
                .reshape(-1)[0]
            )


            # -----------------------------------------------
            # axes
            # -----------------------------------------------

            if (
                len(node.input) >= 2
                and node.input[1]
                in initializers
            ):

                axes = list(
                    np.asarray(
                        initializers[
                            node.input[1]
                        ]
                    )
                    .reshape(-1)
                    .astype(int)
                )

            else:

                axes = get_attr_ints(
                    node,
                    "axes",
                    [2, 3]
                )


            # -----------------------------------------------
            # 找紧随其后的Reshape
            # -----------------------------------------------

            next_nodes = consumers.get(
                node.output[0],
                []
            )

            reshape_node = None

            for next_node in next_nodes:

                if (
                    next_node.op_type
                    == "Reshape"
                ):

                    reshape_node = next_node
                    break


            if reshape_node is None:

                raise RuntimeError(
                    "ReduceMean后没有找到Reshape"
                )


            fused_reshape_names.add(
                reshape_node.name
            )


            out_info = (
                find_nearest_quantize(
                    node.output[0]
                )
            )


            Sy = float(
                out_info["scale"]
                .reshape(-1)[0]
            )

            Zy = int(
                out_info["zero_point"]
                .reshape(-1)[0]
            )


            # -----------------------------------------------
            # 求和
            # -----------------------------------------------

            centered = (
                xq
                - Zx
            )


            total = centered.sum(
                dim=tuple(axes),
                keepdim=True
            )


            element_count = 1

            for axis in axes:

                element_count *= (
                    xq.shape[axis]
                )


            M_gap = (
                Sx
                /
                (
                    element_count
                    * Sy
                )
            )


            mult, shift, _ = (
                quantize_real_multiplier(
                    M_gap
                )
            )


            product = (
                total
                * int(mult)
            )


            scaled = round_shift_rne_tensor(
                product,
                shift
            )


            qout = torch.clamp(
                scaled + Zy,
                -128,
                127
            ).to(
                torch.int8
            )


            # -----------------------------------------------
            # Reshape
            # -----------------------------------------------

            shape_name = (
                reshape_node.input[1]
            )

            target_shape = list(
                np.asarray(
                    initializers[
                        shape_name
                    ]
                )
                .reshape(-1)
                .astype(int)
            )


            qout = qout.reshape(
                target_shape
            )


            tensors[
                out_info["q_name"]
            ] = qout


            if record_trace:

                trace.append(
                    (
                        semantic_index,
                        "ReduceMean（全局平均）",
                        out_info["q_name"],
                        qout.clone()
                    )
                )


        # ====================================================
        # Reshape（形状重排）
        # 已经和ReduceMean融合完成
        # ====================================================

        elif node.op_type == "Reshape":

            semantic_index += 1

            if node.name in fused_reshape_names:

                if record_trace:

                    trace.append(
                        (
                            semantic_index,
                            "Reshape（形状重排）",
                            None,
                            None
                        )
                    )

                continue

            raise RuntimeError(
                "出现未处理的独立Reshape"
            )


        # ====================================================
        # Gemm（全连接）
        # ====================================================

        elif node.op_type == "Gemm":

            semantic_index += 1


            x_info = parse_dq(
                node.input[0]
            )

            w_info = parse_dq(
                node.input[1]
            )

            b_info = parse_dq(
                node.input[2]
            )


            Xq = tensors[
                x_info["q_name"]
            ].to(torch.int32)


            Wq = torch.from_numpy(
                np.asarray(
                    w_info["q_tensor"]
                ).astype(np.int32)
            )


            Bq = torch.from_numpy(
                np.asarray(
                    b_info["q_tensor"]
                )
                .reshape(-1)
                .astype(np.int64)
            )


            Sx = float(
                x_info["scale"]
                .reshape(-1)[0]
            )

            Zx = int(
                x_info["zero_point"]
                .reshape(-1)[0]
            )


            Sw = (
                w_info["scale"]
                .reshape(-1)
                .astype(np.float64)
            )

            Zw = (
                w_info["zero_point"]
                .reshape(-1)
                .astype(np.int64)
            )


            out_info = (
                find_nearest_quantize(
                    node.output[0]
                )
            )


            Sy = float(
                out_info["scale"]
                .reshape(-1)[0]
            )

            Zy = int(
                out_info["zero_point"]
                .reshape(-1)[0]
            )


            Xcenter = (
                Xq
                - Zx
            )


            if len(Zw) == 1:

                Wcenter = (
                    Wq
                    - int(Zw[0])
                )

            else:

                Wcenter = (
                    Wq
                    -
                    torch.from_numpy(
                        Zw.astype(np.int32)
                    ).reshape(
                        -1,
                        1
                    )
                )


            # Weight = [6,512]
            # X      = [1,512]
            dot = (
                Xcenter
                @
                Wcenter.T
            )


            acc = (
                dot.to(torch.int64)
                +
                Bq.reshape(
                    1,
                    -1
                )
            )


            M = (
                Sx
                * Sw
                / Sy
            )


            qout = requant_per_channel(
                acc,
                M,
                Zy
            )


            tensors[
                out_info["q_name"]
            ] = qout


            if record_trace:

                trace.append(
                    (
                        semantic_index,
                        "Gemm（全连接）",
                        out_info["q_name"],
                        qout.clone()
                    )
                )


    # ========================================================
    # 找最后 Gemm 的INT8输出
    # ========================================================

    final_out_info = (
        find_nearest_quantize(
            gemm_node.output[0]
        )
    )


    final_q = tensors[
        final_out_info["q_name"]
    ]


    return (
        final_q,
        trace
    )


# ============================================================
# 9. 找Gemm供最后使用
# ============================================================

gemm_node = None

for node in graph.node:

    if node.op_type == "Gemm":

        gemm_node = node
        break


# ============================================================
# 10. 第一张图片逐层验证
# ============================================================

def verify_one_image(
    image_path
):

    print("=" * 120)

    print(
        "整网纯整数 ResNet18 验证"
    )

    print("=" * 120)

    print(
        "测试图片：",
        image_path
    )


    x_fp32 = preprocess(
        image_path
    )


    final_q, trace = (
        run_integer_model(
            x_fp32,
            record_trace=True
        )
    )


    print(
        "\n整数模型最终INT8输出："
    )

    print(
        final_q.numpy()
    )


    print(
        "\n整数模型预测类别ID：",
        int(
            torch.argmax(
                final_q
            ).item()
        )
    )


    # --------------------------------------------------------
    # 把所有中间INT8结果暴露给ORT
    # --------------------------------------------------------

    debug_model = copy.deepcopy(
        model
    )


    trace_with_q = [
        item
        for item in trace
        if item[2] is not None
    ]


    q_names = []

    for (
        index,
        op_name,
        q_name,
        tensor
    ) in trace_with_q:

        if q_name not in q_names:

            q_names.append(
                q_name
            )


    existing_outputs = {
        out.name
        for out in debug_model.graph.output
    }


    for q_name in q_names:

        if q_name in existing_outputs:
            continue

        debug_model.graph.output.extend(
            [
                helper.make_tensor_value_info(
                    q_name,
                    TensorProto.INT8,
                    None
                )
            ]
        )


    onnx.save(
        debug_model,
        DEBUG_MODEL_PATH
    )


    opts = ort.SessionOptions()

    opts.graph_optimization_level = (
        ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    )


    session = ort.InferenceSession(
        str(DEBUG_MODEL_PATH),
        sess_options=opts,
        providers=[
            "CPUExecutionProvider"
        ]
    )


    input_name = (
        session
        .get_inputs()[0]
        .name
    )


    ort_values = session.run(
        q_names,
        {
            input_name:
            x_fp32
        }
    )


    ort_dict = {
        name: value
        for name, value
        in zip(
            q_names,
            ort_values
        )
    }


    # --------------------------------------------------------
    # 每个算子输出比较
    # --------------------------------------------------------

    print(
        "\n"
        + "=" * 120
    )

    print(
        "逐算子 INT8 输出对比"
    )

    print("=" * 120)


    print(
        f"{'编号':<6}"
        f"{'算子':<28}"
        f"{'元素数':>12}"
        f"{'不同数':>12}"
        f"{'最大误差':>12}"
        f"{'一致率':>16}"
    )


    print("-" * 120)


    first_mismatch = None


    for (
        index,
        op_name,
        q_name,
        manual_tensor
    ) in trace:

        if q_name is None:

            print(
                f"{index:<6}"
                f"{op_name:<28}"
                f"{'-':>12}"
                f"{'-':>12}"
                f"{'-':>12}"
                f"{'无数值计算':>16}"
            )

            continue


        manual = (
            manual_tensor
            .cpu()
            .numpy()
            .astype(np.int16)
        )


        reference = (
            ort_dict[q_name]
            .astype(np.int16)
        )


        diff = (
            manual
            - reference
        )


        mismatch = int(
            np.count_nonzero(
                diff
            )
        )

        total = int(
            diff.size
        )

        max_error = int(
            np.max(
                np.abs(
                    diff
                )
            )
        )


        agreement = (
            (
                total
                - mismatch
            )
            / total
            * 100.0
        )


        print(
            f"{index:<6}"
            f"{op_name:<28}"
            f"{total:>12}"
            f"{mismatch:>12}"
            f"{max_error:>12}"
            f"{agreement:>15.6f}%"
        )


        if (
            mismatch > 0
            and first_mismatch is None
        ):

            first_mismatch = (
                index,
                op_name,
                mismatch,
                max_error
            )


    # --------------------------------------------------------
    # ORT最终模型预测
    # --------------------------------------------------------

    normal_session = ort.InferenceSession(
        str(MODEL_PATH),
        providers=[
            "CPUExecutionProvider"
        ]
    )


    normal_input_name = (
        normal_session
        .get_inputs()[0]
        .name
    )


    ort_final = normal_session.run(
        None,
        {
            normal_input_name:
            x_fp32
        }
    )[0]


    ort_prediction = int(
        np.argmax(
            ort_final
        )
    )


    integer_prediction = int(
        torch.argmax(
            final_q
        ).item()
    )


    print(
        "\n"
        + "=" * 120
    )

    print(
        "整网最终结果"
    )

    print("=" * 120)


    print(
        "ONNX Runtime最终输出：",
        ort_final
    )


    print(
        "整数模型最终INT8输出：",
        final_q.numpy()
    )


    print(
        "ORT预测类别ID：",
        ort_prediction
    )

    print(
        "整数模型预测类别ID：",
        integer_prediction
    )


    if (
        ort_prediction
        == integer_prediction
    ):

        print(
            "\n最终分类结果：一致"
        )

    else:

        print(
            "\n最终分类结果：不一致"
        )


    if first_mismatch is None:

        print(
            "\n所有可比较整数算子均100%逐元素一致。"
        )

    else:

        print(
            "\n第一处出现差异："
        )

        print(
            first_mismatch
        )


# ============================================================
# 11. 全270张测试集
# ============================================================

def verify_all_images():

    class_names = sorted(
        [
            p.name
            for p in TEST_DIR.iterdir()
            if p.is_dir()
        ]
    )


    class_to_idx = {
        name: i
        for i, name
        in enumerate(
            class_names
        )
    }


    print(
        "\n类别映射："
    )

    for name, idx in class_to_idx.items():

        print(
            f"{idx} -> {name}"
        )


    extensions = {
        ".bmp",
        ".png",
        ".jpg",
        ".jpeg"
    }


    images = sorted(
        [
            p
            for p in TEST_DIR.rglob("*")
            if (
                p.is_file()
                and p.suffix.lower()
                in extensions
            )
        ]
    )


    ort_session = ort.InferenceSession(
        str(MODEL_PATH),
        providers=[
            "CPUExecutionProvider"
        ]
    )


    ort_input_name = (
        ort_session
        .get_inputs()[0]
        .name
    )


    integer_correct = 0
    ort_correct = 0
    prediction_agreement = 0


    print(
        "\n开始验证全部测试图片..."
    )

    print(
        "图片数量 =",
        len(images)
    )


    for i, image_path in enumerate(
        images,
        start=1
    ):

        x_fp32 = preprocess(
            image_path
        )


        final_q, _ = (
            run_integer_model(
                x_fp32,
                record_trace=False
            )
        )


        integer_pred = int(
            torch.argmax(
                final_q
            ).item()
        )


        ort_output = ort_session.run(
            None,
            {
                ort_input_name:
                x_fp32
            }
        )[0]


        ort_pred = int(
            np.argmax(
                ort_output
            )
        )


        true_label = (
            class_to_idx[
                image_path.parent.name
            ]
        )


        if integer_pred == true_label:

            integer_correct += 1


        if ort_pred == true_label:

            ort_correct += 1


        if integer_pred == ort_pred:

            prediction_agreement += 1


        if (
            i % 10 == 0
            or i == len(images)
        ):

            print(
                f"[{i:3d}/{len(images)}] "
                f"整数正确={integer_correct}, "
                f"ORT正确={ort_correct}, "
                f"预测一致={prediction_agreement}"
            )


    total = len(images)


    print(
        "\n"
        + "=" * 120
    )

    print(
        "完整测试集结果"
    )

    print("=" * 120)


    print(
        f"整数Golden Model准确率："
        f"{integer_correct / total * 100:.2f}%"
    )


    print(
        f"ONNX Runtime准确率："
        f"{ort_correct / total * 100:.2f}%"
    )


    print(
        f"整数模型 / ORT预测一致率："
        f"{prediction_agreement / total * 100:.2f}%"
    )


    print("=" * 120)


# ============================================================
# 12. Main
# ============================================================

if __name__ == "__main__":

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--all",
        action="store_true",
        help="验证全部270张测试图片"
    )

    args = parser.parse_args()


    extensions = {
        ".bmp",
        ".png",
        ".jpg",
        ".jpeg"
    }


    images = sorted(
        [
            p
            for p in TEST_DIR.rglob("*")
            if (
                p.is_file()
                and p.suffix.lower()
                in extensions
            )
        ]
    )


    if not images:

        raise RuntimeError(
            "测试集没有找到图片"
        )


    if args.all:

        verify_all_images()

    else:

        verify_one_image(
            images[0]
        )