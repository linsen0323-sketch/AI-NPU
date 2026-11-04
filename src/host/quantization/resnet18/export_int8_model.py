"""Export the existing QDQ ONNX to the descriptor/DDR ABI; never train/quantize.

All fixed-point conversion helpers are imported from the existing, unchanged
verify_full_resnet18_int8.py.  Running this script does not call its debug-model
writers.  Byte offsets in descriptors are relative to the configured DDR base.
"""
from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import importlib.util
import json
import struct
from pathlib import Path

import numpy as np
import onnx

ROOT = Path(__file__).resolve().parents[4]
OUT = ROOT / "work/resnet18_legacy_image"
SEMANTIC = {"Conv", "Relu", "Add", "MaxPool", "ReduceMean", "Reshape", "Gemm"}
OPCODES = {"Conv": 1, "Relu": 2, "Add": 3, "MaxPool": 4, "ReduceMean": 5, "Gemm": 6}
CLASS_NAMES = ["Cr", "In", "PS", "Pa", "RS", "Sc"]
FIELDS = ["opcode", "input", "input2", "output", "input_h", "input_w", "cin",
          "output_h", "output_w", "cout", "kh", "kw", "sh", "sw", "pad_top",
          "pad_left", "weights", "bias", "multipliers", "shifts", "add_ma_lo",
          "add_ma_hi", "add_mb_lo", "add_mb_hi", "add_shift", "gap_multiplier",
          "gap_shift", "output_elements", "flags", "reserved0", "reserved1", "reserved2"]


def sha256(path):
    with Path(path).open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def protected_hashes():
    files = list((ROOT / "tools").glob("*.py"))
    files += list((ROOT / "data/models").glob("*.py"))
    files += list((ROOT / "training").glob("*.py"))
    files += [ROOT / "data/models/checkpoints/resnet18_neu6.pth", ROOT / "data/models/onnx/resnet18_fp32.onnx",
              ROOT / "data/models/onnx/resnet18_int8_qdq.onnx", ROOT / "data/models/quantization/resnet18/requant_params.csv"]
    return {str(p.relative_to(ROOT)).replace("\\", "/"): sha256(p) for p in sorted(files) if p.exists()}


def load_golden():
    path = ROOT / "src/host/quantization/resnet18/verify_full_resnet18_int8.py"
    spec = importlib.util.spec_from_file_location("existing_integer_golden", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scalar(info):
    return float(np.asarray(info["scale"]).reshape(-1)[0])


def require_zero(info):
    assert not np.any(info["zero_point"]), "Only the model's symmetric zero point 0 is supported"


def dims_nchw(shape):
    if len(shape) == 2:
        return (1, 1, shape[1])
    assert len(shape) == 4 and shape[0] == 1
    return (shape[2], shape[3], shape[1])


def pack_weights(weights):
    """[OCtile][ICtile][KH][KW][16 OC lanes][8 IC lanes], lane0 lowest byte."""
    weights = np.asarray(weights, dtype=np.int8)
    if weights.ndim == 2:
        weights = weights[:, :, None, None]
    cout, cin, kh, kw = weights.shape
    padded = np.zeros(((cout + 15) // 16 * 16, (cin + 7) // 8 * 8, kh, kw), dtype=np.int8)
    padded[:cout, :cin] = weights
    packed = padded.reshape(-1, 16, padded.shape[1] // 8, 8, kh, kw).transpose(0, 2, 4, 5, 1, 3)
    # Round-trip proves the OC/IC byte packing including all padded channels.
    restored = packed.transpose(0, 4, 1, 5, 2, 3).reshape(padded.shape)
    assert np.array_equal(restored[:cout, :cin], weights)
    return packed.tobytes()


def parse_model(g):
    onnx.checker.check_model(g.model)
    first = next(n for n in g.graph.node if n.op_type == "Conv")
    first_info = g.parse_dq(first.input[0])
    input_shape = tuple(d.dim_value for d in g.graph.input[0].type.tensor_type.shape.dim)
    assert input_shape == (1, 3, 224, 224)
    shapes = {first_info["q_name"]: input_shape}
    layers = []
    semantic_index = 0
    fused = set()
    for n in g.graph.node:
        if n.op_type not in SEMANTIC:
            continue
        semantic_index += 1
        if n.op_type == "Reshape":
            assert n.name in fused, "An independent Reshape is unsupported"
            continue
        xi = g.parse_dq(n.input[0])
        yi = g.find_nearest_quantize(n.output[0])
        assert yi is not None
        require_zero(xi)
        require_zero(yi)
        xs = shapes[xi["q_name"]]
        ih, iw, cin = dims_nchw(xs)
        d = {"index": len(layers), "semantic_index": semantic_index, "name": n.name,
             "op": n.op_type, "opcode": OPCODES[n.op_type], "input": xi["q_name"],
             "output": yi["q_name"], "input_shape": list(xs), "input_scale": scalar(xi),
             "output_scale": scalar(yi), "kh": 1, "kw": 1, "sh": 1, "sw": 1,
             "pad_top": 0, "pad_left": 0}
        ys = xs
        if n.op_type in {"Conv", "Gemm"}:
            wi = g.parse_dq(n.input[1])
            require_zero(wi)
            w = np.asarray(wi["q_tensor"])
            assert w.dtype == np.int8
            if len(n.input) > 2:
                bi = g.parse_dq(n.input[2])
                require_zero(bi)
                b = np.asarray(bi["q_tensor"]).reshape(-1)
                assert b.dtype == np.int32
            else:
                b = np.zeros(w.shape[0], np.int32)
            if n.op_type == "Conv":
                assert g.get_attr_int(n, "group", 1) == 1
                assert g.get_attr_ints(n, "dilations", [1, 1]) == [1, 1]
                cout, win, kh, kw = w.shape
                assert win == cin and kh == kw and kh in {1, 3, 7}
                sh, sw = g.get_attr_ints(n, "strides", [1, 1])
                pt, pl, pb, pr = g.get_attr_ints(n, "pads", [0] * 4)
                assert sh == sw and sh in {1, 2} and pt == pb and pl == pr
                ys = (1, cout, (ih + pt + pb - kh) // sh + 1, (iw + pl + pr - kw) // sw + 1)
                d.update(kh=kh, kw=kw, sh=sh, sw=sw, pad_top=pt, pad_left=pl)
            else:
                assert g.get_attr_int(n, "transA", 0) == 0 and g.get_attr_int(n, "transB", 0) == 1
                attrs = {a.name: onnx.helper.get_attribute_value(a) for a in n.attribute}
                assert attrs.get("alpha", 1.0) == attrs.get("beta", 1.0) == 1.0
                assert w.shape == (6, 512)
                ys = (1, w.shape[0])
            ratios = scalar(xi) * np.asarray(wi["scale"], np.float64).reshape(-1) / scalar(yi)
            assert len(ratios) == w.shape[0]
            pairs = [g.quantize_real_multiplier(float(r)) for r in ratios]
            mult = np.array([p[0] for p in pairs], dtype=np.int32)
            shifts = np.array([p[1] for p in pairs], dtype=np.uint32)
            assert all(0 <= p[0] < 2**31 and 0 <= p[1] < 256 for p in pairs)
            sums = np.abs(w.astype(np.int64)).reshape(w.shape[0], -1).sum(axis=1) * 128
            assert max(sums) <= 2**31 - 1
            bound = sums + np.abs(b.astype(np.int64))
            assert max(bound) < 2**39
            product_bound = bound * mult.astype(np.int64)
            assert all(int(v) < 2**63 for v in product_bound)
            d.update(_weights=w, _bias=b, _multipliers=mult, _shifts=shifts,
                     weight_shape=list(w.shape), mac_bound=int(max(sums)),
                     acc_with_bias_bound=int(max(bound)), requant_product_bound=int(max(product_bound)),
                     multiplier_min=int(mult.min()), multiplier_max=int(mult.max()),
                     shift_min=int(shifts.min()), shift_max=int(shifts.max()))
        elif n.op_type in {"Relu", "MaxPool"}:
            assert np.isclose(scalar(xi), scalar(yi), rtol=1e-7, atol=0)
            if n.op_type == "MaxPool":
                kh, kw = g.get_attr_ints(n, "kernel_shape", [1, 1])
                sh, sw = g.get_attr_ints(n, "strides", [kh, kw])
                pt, pl, pb, pr = g.get_attr_ints(n, "pads", [0] * 4)
                assert g.get_attr_ints(n, "dilations", [1, 1]) == [1, 1]
                assert g.get_attr_int(n, "ceil_mode", 0) == 0 and pt == pb and pl == pr
                ys = (1, cin, (ih + pt + pb - kh) // sh + 1, (iw + pl + pr - kw) // sw + 1)
                d.update(kh=kh, kw=kw, sh=sh, sw=sw, pad_top=pt, pad_left=pl)
        elif n.op_type == "Add":
            bi = g.parse_dq(n.input[1])
            require_zero(bi)
            assert shapes[bi["q_name"]] == xs
            ma, sa, _ = g.quantize_real_multiplier(scalar(xi) / scalar(yi))
            mb, sb, _ = g.quantize_real_multiplier(scalar(bi) / scalar(yi))
            shift = max(sa, sb)
            ma, mb = ma << (shift - sa), mb << (shift - sb)
            assert (ma + mb) * 128 < 2**63
            d.update(input2=bi["q_name"], input2_scale=scalar(bi), add_ma=ma, add_mb=mb, add_shift=shift)
        elif n.op_type == "ReduceMean":
            axes = (np.asarray(g.initializers[n.input[1]]).reshape(-1).tolist()
                    if len(n.input) > 1 else g.get_attr_ints(n, "axes", [2, 3]))
            assert sorted(a % len(xs) for a in axes) == [2, 3] and (ih, iw, cin) == (7, 7, 512)
            reshape = next(z for z in g.consumers[n.output[0]] if z.op_type == "Reshape")
            target = np.asarray(g.initializers[reshape.input[1]]).reshape(-1).tolist()
            assert target == [1, 512]
            fused.add(reshape.name)
            ma, shift, _ = g.quantize_real_multiplier(scalar(xi) / (ih * iw * scalar(yi)))
            d.update(gap_multiplier=ma, gap_shift=shift, fused_reshape=reshape.name)
            ys = (1, cin)
        d["output_shape"] = list(ys)
        shapes[d["output"]] = ys
        layers.append(d)
    assert collections.Counter(d["op"] for d in layers) == {"Conv": 20, "Relu": 17, "Add": 8, "MaxPool": 1, "ReduceMean": 1, "Gemm": 1}
    return layers, shapes, first_info


def json_layer(layer):
    return {k: v for k, v in layer.items() if not k.startswith("_")}


def write_json(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_hex(path, data):
    data = bytes(data)
    with Path(path).open("w", encoding="ascii", newline="\n") as f:
        for start in range(0, len(data), 65536):
            f.write("".join(f"{x:02x}\n" for x in data[start:start+65536]))


def build_memory(layers, shapes, inputs=None):
    """Allocate every tensor separately (all64 aligned), then packed constants."""
    memory = bytearray(len(layers) * 128)
    tensors, parameters, descs = {}, {}, []

    def allocate(data):
        memory.extend(b"\0" * (-len(memory) % 64))
        offset = len(memory)
        memory.extend(data)
        return offset

    names = []
    for layer in layers:
        for field in ("input", "input2", "output"):
            name = layer.get(field)
            if name and name not in names:
                names.append(name)
    for name in names:
        count = int(np.prod(shapes[name]))
        data = np.asarray((inputs or {}).get(name, np.zeros(count, np.int8)), dtype=np.int8).tobytes()
        assert len(data) == count
        offset = allocate(data)
        tensors[name] = {"offset": offset, "bytes": count, "shape": list(shapes[name]), "dtype": "int8", "layout": "NCHW"}
    for layer in layers:
        ih, iw, cin = dims_nchw(layer["input_shape"])
        oh, ow, cout = dims_nchw(layer["output_shape"])
        d = [0] * 32
        d[:20] = [layer["opcode"], tensors[layer["input"]]["offset"],
                  tensors[layer["input2"]]["offset"] if layer.get("input2") else 0,
                  tensors[layer["output"]]["offset"], ih, iw, cin, oh, ow, cout,
                  layer.get("kh", 1), layer.get("kw", 1), layer.get("sh", 1), layer.get("sw", 1),
                  layer.get("pad_top", 0), layer.get("pad_left", 0), 0, 0, 0, 0]
        param = {}
        if layer["opcode"] in {1, 6}:
            payloads = [("weights", pack_weights(layer["_weights"])),
                        ("bias", np.asarray(layer["_bias"], dtype="<i4").tobytes()),
                        ("multipliers", np.asarray(layer["_multipliers"], dtype="<i4").tobytes()),
                        ("shifts", np.asarray(layer["_shifts"], dtype="<u4").tobytes())]
            for word, (name, data) in enumerate(payloads, start=16):
                d[word] = allocate(data)
                param[name] = {"offset": d[word], "bytes": len(data)}
        ma, mb = layer.get("add_ma", 0), layer.get("add_mb", 0)
        d[20:27] = [ma & 0xffffffff, ma >> 32, mb & 0xffffffff, mb >> 32,
                    layer.get("add_shift", 0), layer.get("gap_multiplier", 0), layer.get("gap_shift", 0)]
        d[27] = int(np.prod(layer["output_shape"]))
        d[28] = int(layer["opcode"] == 6)  # LAST/ARGMAX flag.
        assert all(0 <= v <= 0xffffffff for v in d)
        descs.append(d)
        parameters[layer["name"]] = param
    for index, d in enumerate(descs):
        memory[index*128:(index+1)*128] = struct.pack("<32I", *d)
    memory.extend(b"\0" * (-len(memory) % 64))
    meta = {"abi_version": 1, "endianness": "little", "descriptor_offset": 0,
            "descriptor_count": len(layers), "descriptor_bytes": 128, "descriptor_fields": FIELDS,
            "ddr_bytes": len(memory), "tensors": tensors, "parameters": parameters,
            "descriptors": descs, "class_map": {str(i): name for i, name in enumerate(CLASS_NAMES)},
            "input_offset": tensors[layers[0]["input"]]["offset"],
            "output_offset": tensors[layers[-1]["output"]]["offset"],
            "weight_layout": "[ceil(Cout/16)][ceil(Cin/8)][Kh][Kw][16][8]; padded lanes zero",
            "layers": [json_layer(layer) for layer in layers]}
    return memory, meta


def csv_check(layers):
    rows = list(csv.DictReader((ROOT / "data/models/quantization/resnet18/requant_params.csv").open(newline="", encoding="utf-8")))
    convs = [l for l in layers if l["op"] == "Conv"]
    expected = sum(len(l["_bias"]) for l in convs)
    assert len(rows) == expected
    indexed = {(r["conv_name"], int(r["channel"])): r for r in rows}
    assert len(indexed) == len(rows)
    for layer in convs:
        for c, (mult, shift) in enumerate(zip(layer["_multipliers"], layer["_shifts"])):
            row = indexed[layer["name"], c]
            assert int(row["multiplier_int32"]) == int(mult)
            assert int(row["right_shift"]) == int(shift)
            assert int(row["Zx"]) == int(row["Zw"]) == int(row["Zy"]) == 0
    return {"rows": len(rows), "all_multiplier_shift_rows_exact": True}


def write_artifacts(out, prefix, memory, meta):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{prefix}.bin").write_bytes(memory)
    write_hex(out / f"{prefix}.hex", memory)
    write_json(out / ("layout.json" if prefix == "ddr" else f"{prefix}.json"), meta)


def export(out=OUT):
    before = protected_hashes()
    g = load_golden()
    layers, shapes, input_info = parse_model(g)
    csv_match = csv_check(layers)
    memory, meta = build_memory(layers, shapes)
    meta["input_quantization"] = {"scale": scalar(input_info), "zero_point": 0,
                                  "preprocessing": "RGB Resize256 CenterCrop224 ImageNet mean/std; numpy.rint"}
    meta["source_sha256"] = before
    meta["csv_validation"] = csv_match
    write_artifacts(out, "ddr", memory, meta)
    write_json(Path(out) / "layers.json", [json_layer(l) for l in layers])
    write_json(Path(out) / "source_hashes.json", before)
    counts = collections.Counter(n.op_type for n in g.graph.node)
    audit = {"graph_nodes": len(g.graph.node), "graph_operator_counts": dict(counts),
             "semantic_count": sum(counts[k] for k in SEMANTIC), "hardware_descriptors": len(layers),
             "all_zero_points_zero": True, "all_quantized_weights_int8_bias_int32": True,
             "csv_validation": csv_match, "maximum_accumulator_bound": max(l.get("acc_with_bias_bound", 0) for l in layers),
             "maximum_requant_product_bound": max(l.get("requant_product_bound", 0) for l in layers),
             "shift_range": [min(l.get("shift_min", 256) for l in layers), max(l.get("shift_max", 0) for l in layers)],
             "ddr_bytes": len(memory), "source_sha256": before}
    write_json(Path(out) / "model_audit.json", audit)
    assert before == protected_hashes(), "Existing model/Golden files changed during export"
    print(json.dumps({"export": str(out), "descriptors": len(layers), "ddr_bytes": len(memory), "csv_rows_exact": csv_match["rows"]}))
    return g, layers, shapes, input_info, meta


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT)
    export(parser.parse_args().out)
