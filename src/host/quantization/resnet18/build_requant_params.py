from pathlib import Path
import csv
import math

import numpy as np
import onnx
from onnx import numpy_helper


PROJECT_ROOT = Path(__file__).resolve().parents[4]

MODEL_PATH = PROJECT_ROOT / "data/models/onnx/resnet18_int8_qdq.onnx"

CSV_PATH = PROJECT_ROOT / "work/quantization/resnet18/requant_params.csv"
CSV_PATH.parent.mkdir(parents=True, exist_ok=True)


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
# 2. 工具函数：解析 DequantizeLinear
# ============================================================

def parse_dq(output_name):

    dq = producer.get(output_name)

    if dq is None:
        raise RuntimeError(
            f"找不到 {output_name} 的产生节点"
        )

    if dq.op_type != "DequantizeLinear":
        raise RuntimeError(
            f"{output_name} 不是 "
            f"DequantizeLinear 输出，"
            f"而是 {dq.op_type}"
        )

    q_name = dq.input[0]
    scale_name = dq.input[1]

    zp_name = (
        dq.input[2]
        if len(dq.input) >= 3
        else None
    )

    # Weight / Bias 常常是 initializer
    # Activation 通常不是
    q_tensor = (
        np.asarray(
            initializers[q_name]
        )
        if q_name in initializers
        else None
    )

    if scale_name not in initializers:
        raise RuntimeError(
            f"找不到 scale：{scale_name}"
        )

    scale = np.asarray(
        initializers[scale_name]
    )

    if (
        zp_name is not None
        and zp_name in initializers
    ):

        zero_point = np.asarray(
            initializers[zp_name]
        )

    else:

        zero_point = np.array(
            0,
            dtype=np.int8
        )

    return {
        "q_name": q_name,
        "q_tensor": q_tensor,
        "scale": scale,
        "zero_point": zero_point,
    }


# ============================================================
# 3. 从某个Tensor向后找 QuantizeLinear
# ============================================================

def find_output_quantize(
    start_tensor
):

    # 先看直接后继
    for node in consumers.get(
        start_tensor,
        []
    ):

        if node.op_type == "QuantizeLinear":
            return node

    # 某些图中间可能隔着 ReLU 等简单节点
    frontier = [
        start_tensor
    ]

    visited = set()

    for _ in range(4):

        next_frontier = []

        for tensor_name in frontier:

            if tensor_name in visited:
                continue

            visited.add(
                tensor_name
            )

            for node in consumers.get(
                tensor_name,
                []
            ):

                if (
                    node.op_type
                    == "QuantizeLinear"
                ):

                    return node

                next_frontier.extend(
                    list(node.output)
                )

        frontier = (
            next_frontier
        )

    return None


# ============================================================
# 4. 浮点 M 转换为：
#
# M ≈ multiplier_int / 2^right_shift
#
# 使用 Q31 mantissa
# ============================================================

def quantize_real_multiplier(
    real_multiplier
):

    if real_multiplier == 0.0:

        return (
            0,
            0,
            0.0
        )

    if real_multiplier < 0.0:

        raise ValueError(
            "Multiplier 不应为负数"
        )


    # 把 real_multiplier 分解为：
    #
    # real_multiplier
    # =
    # significand × 2^exponent
    #
    # significand ∈ [0.5, 1)
    significand, exponent = (
        math.frexp(
            real_multiplier
        )
    )


    # 把 significand 映射到 Q31
    multiplier_int = int(
        round(
            significand
            * (1 << 31)
        )
    )


    # 防止舍入到 2^31
    if (
        multiplier_int
        == (1 << 31)
    ):

        multiplier_int //= 2
        exponent += 1


    # 因为：
    #
    # significand
    # ≈
    # multiplier_int / 2^31
    #
    # 所以：
    #
    # M
    # ≈
    # multiplier_int
    # /
    # 2^(31 - exponent)
    right_shift = (
        31
        - exponent
    )


    approx_multiplier = (
        multiplier_int
        / (2.0 ** right_shift)
    )


    return (
        multiplier_int,
        right_shift,
        approx_multiplier
    )


# ============================================================
# 5. 遍历全部 Conv
# ============================================================

rows = []

conv_index = 0

print("=" * 110)
print(
    "ResNet18 INT8 "
    "Requantization 参数提取"
)
print("=" * 110)


for conv in graph.node:

    if conv.op_type != "Conv":
        continue

    conv_index += 1


    # ========================================================
    # 输入 Activation
    # ========================================================

    input_info = parse_dq(
        conv.input[0]
    )

    Sx = float(
        input_info["scale"]
        .reshape(-1)[0]
    )

    Zx = int(
        input_info["zero_point"]
        .reshape(-1)[0]
    )


    # ========================================================
    # Weight
    # ========================================================

    weight_info = parse_dq(
        conv.input[1]
    )

    Sw = (
        weight_info["scale"]
        .reshape(-1)
        .astype(np.float64)
    )

    Zw = (
        weight_info["zero_point"]
        .reshape(-1)
    )


    # ========================================================
    # 输出 Activation
    # ========================================================

    q_node = find_output_quantize(
        conv.output[0]
    )

    if q_node is None:

        raise RuntimeError(
            f"Conv{conv_index} "
            f"找不到输出 QuantizeLinear"
        )


    Sy = float(
        initializers[
            q_node.input[1]
        ].reshape(-1)[0]
    )


    if (
        len(q_node.input) >= 3
        and q_node.input[2]
        in initializers
    ):

        Zy = int(
            initializers[
                q_node.input[2]
            ].reshape(-1)[0]
        )

    else:

        Zy = 0


    # ========================================================
    # M[c]
    #
    # M[c] = Sx * Sw[c] / Sy
    # ========================================================

    M = (
        Sx
        * Sw
        / Sy
    )


    approx_values = []
    shifts = []
    rel_errors = []


    for channel, real_m in enumerate(
        M
    ):

        (
            multiplier_int,
            right_shift,
            approx_m
        ) = quantize_real_multiplier(
            float(real_m)
        )


        abs_error = abs(
            approx_m
            - float(real_m)
        )


        if real_m != 0:

            rel_error = (
                abs_error
                / abs(
                    float(real_m)
                )
            )

        else:

            rel_error = 0.0


        approx_values.append(
            approx_m
        )

        shifts.append(
            right_shift
        )

        rel_errors.append(
            rel_error
        )


        zw_value = (
            int(
                Zw[channel]
            )
            if len(Zw) > 1
            else int(
                Zw[0]
            )
        )


        rows.append({

            "conv_index":
                conv_index,

            "conv_name":
                conv.name,

            "channel":
                channel,

            "Sx":
                Sx,

            "Sw":
                float(
                    Sw[channel]
                ),

            "Sy":
                Sy,

            "Zx":
                Zx,

            "Zw":
                zw_value,

            "Zy":
                Zy,

            "M_real":
                float(
                    real_m
                ),

            "multiplier_int32":
                multiplier_int,

            "right_shift":
                right_shift,

            "M_approx":
                approx_m,

            "abs_error":
                abs_error,

            "rel_error":
                rel_error,
        })


    print(
        f"Conv{conv_index:02d} | "
        f"Cout={len(M):4d} | "
        f"M范围=["
        f"{np.min(M):.3e}, "
        f"{np.max(M):.3e}] | "
        f"shift范围=["
        f"{min(shifts)}, "
        f"{max(shifts)}] | "
        f"最大相对误差="
        f"{max(rel_errors):.3e}"
    )


# ============================================================
# 6. 保存 CSV
# ============================================================

with open(
    CSV_PATH,
    "w",
    newline="",
    encoding="utf-8-sig"
) as f:

    writer = csv.DictWriter(
        f,
        fieldnames=[
            "conv_index",
            "conv_name",
            "channel",
            "Sx",
            "Sw",
            "Sy",
            "Zx",
            "Zw",
            "Zy",
            "M_real",
            "multiplier_int32",
            "right_shift",
            "M_approx",
            "abs_error",
            "rel_error",
        ]
    )

    writer.writeheader()

    writer.writerows(
        rows
    )


# ============================================================
# 7. 第一层第0通道示例
# ============================================================

first = rows[0]


print(
    "\n"
    + "=" * 110
)

print(
    "第一层第0输出通道示例"
)

print(
    "=" * 110
)


print(
    "M_real =",
    first["M_real"]
)

print(
    "multiplier_int32 =",
    first[
        "multiplier_int32"
    ]
)

print(
    "right_shift =",
    first[
        "right_shift"
    ]
)

print(
    "M_approx =",
    first[
        "M_approx"
    ]
)

print(
    "绝对误差 =",
    first[
        "abs_error"
    ]
)

print(
    "相对误差 =",
    first[
        "rel_error"
    ]
)


# ============================================================
# 8. FPGA 实现公式
# ============================================================

print("\nFPGA可以实现为：")

print(
    "product = "
    "acc * multiplier_int32"
)

print(
    "scaled = "
    "signed_round_shift("
    "product, right_shift)"
)

print(
    "y_int8 = "
    "saturate_to_int8("
    "scaled + Zy)"
)


# ============================================================
# 9. 有符号舍入右移参考
# ============================================================

print(
    "\nSigned Round Shift参考："
)

print(
    "若 product >= 0："
)

print(
    "scaled = "
    "(product + "
    "2^(shift-1)) "
    ">> shift"
)

print(
    "\n若 product < 0："
)

print(
    "scaled = -("
    "((-product) + "
    "2^(shift-1)) "
    ">> shift)"
)


print(
    "\n注意："
    "acc × multiplier_int32 "
    "的中间乘积必须使用足够宽的"
    "有符号位宽。"
)


print(
    "\nCSV 已保存："
)

print(
    CSV_PATH
)

print("=" * 110)