"""Versioned SD bundle contract, shared by file packer and Linux runtime.

Only standard library code. No imports from a generator, no Golden execution.
Image identities are data, not compiled constants; model IDs/DDR slots are ABI.
"""
from __future__ import annotations
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import zlib

DDR_BYTES = 0x40000000
RESERVED_BASE, RESERVED_BYTES = 0x10000000, 0x10000000
WORKSPACE_BASE, WORKSPACE_MAX = 0x1A000000, 0x01000000
SLOTS = {1: (0x14000000, 0x01000000),
         3: (0x18000000, 0x02000000)}
ABI = {"driver": 2, "frontend_magic": 0x50525031, "frontend": 4,
       "camera_feature": 0x43414D32, "graph_magic": 0x4E475031,
       "graph_extension": 2, "package": 3, "plan_known_features": 15}
PREDECODED_FEATURE = 2
PREDECODED_OFFSET = 0x400
AFFINE_MARKER = 0x31464641
SECTION_NAMES = (b"META", b"TENSORS", b"INSTRUCTIONS", b"ATTRIBUTES", b"CONSTANTS")
ENGINE_OPS = {1: {1, 4, 5, 9, 10, 11}, 2: {20},
              4: {12, 13, 14, 15, 16, 17, 18}, 5: {2, 3}, 6: {19}}
FIELDS = ("id", "model_base", "image_bytes", "image_crc", "plan_offset", "plan_bytes",
          "workspace_bytes", "input_offset", "input_bytes", "output_offset",
          "output_bytes", "output_dtype", "input_width", "input_height", "graph_operations")


def require(ok, why):
    if not ok:
        raise ValueError(why)


def crc(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parse_json(payload):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate JSON key {key}")
            result[key] = value
        return result
    return json.loads(payload, object_pairs_hook=unique_pairs)


def read_json(path):
    return parse_json(Path(path).read_bytes())


def child_file(root, name):
    require(isinstance(name, str) and not Path(name).is_absolute(), "relative bundle path required")
    root = Path(root).resolve()
    path = (root / name).resolve()
    require(path.is_relative_to(root) and path.is_file(), f"bundle file escapes root or absent: {name}")
    return path


def check_image(blob, model):
    """Validate AIPKG3, every section, appended NPUPLN1 and source binding."""
    require(len(blob) == model["image_bytes"] and len(blob) >= 512, "image length")
    require(sha(blob) == model["image_sha256"] and crc(blob) == model["image_crc"], "image SHA256/CRC32")
    require(blob[:8] == b"AIPKG3\0\0", "AIPKG3 magic")
    h = struct.unpack_from("<64I", blob)
    require(h[2:6] == (3, 256, model["id"], 2) and h[9] == h[11] == 0,
            "package ABI/model ID/profile")
    require(h[8] >= 4096 and h[8] % 4096 == 0 and h[8] == model["plan_offset"] and
            h[6] == 5 and 0 < h[10] <= model["workspace_bytes"] and h[10] % 4096 == 0,
            "package extent/directory count/workspace alignment")
    head = bytearray(blob[:256]); head[56:60] = bytes(4)
    require(crc(head) == h[14], "package header CRC")
    directory_end = 256 + h[6] * 64
    require(directory_end <= h[8], "directory extent")
    require(crc(blob[256:directory_end]) == h[7], "directory CRC")
    require(crc(blob[256:h[8]]) == h[16], "body CRC")
    sections, intervals = {}, []
    for i in range(h[6]):
        name, off, size, checksum, alignment, reserved = struct.unpack_from("<16sQQII24s", blob, 256 + 64*i)
        name = name.rstrip(b"\0")
        require(name not in sections and alignment == 4096 and not any(reserved), "section name/alignment")
        require(off >= 4096 and off + size <= h[8] and off % alignment == 0, "section extent")
        sections[name] = (off, size)
        require(all(off + size <= b or e <= off for b, e in intervals), "overlapping package sections")
        intervals.append((off, off+size))
        require(crc(blob[off:off+size]) == checksum, "section CRC")
    require(set(sections) == {b"META", b"TENSORS", b"INSTRUCTIONS", b"ATTRIBUTES", b"CONSTANTS"},
            "profile-2 package sections")
    plan = blob[model["plan_offset"]:]
    require(len(plan) == model["plan_bytes"] and len(plan) >= 256, "appended plan extent")
    p = struct.unpack_from("<64I", plan)
    require(plan[:8] == b"NPUPLN1\0" and p[2:7] == (1, 256, model["id"], 2, 512) and
            p[13] == len(plan) and len(plan) % 4096 == 0, "plan identity/ABI")
    require(p[14:16] == (h[16], h[8]), "plan/package source binding")
    plan_head = bytearray(plan[:256]); plan_head[68:72] = bytes(4)
    require(crc(plan_head) == p[17] and crc(plan[256:]) == p[16], "plan header/body CRC")
    require(p[7] == model["graph_operations"] and p[8] > 0 and p[9] == 4096 and
            p[10] == 8*p[7] and p[11] % 4096 == 0 and p[9]+p[10] <= p[11] and
            p[12] == 512*p[8] and p[11]+p[12] <= len(plan), "plan table geometry")
    require(p[18:20] == sections[b"CONSTANTS"] and p[19] > 0 and
            p[29:31] == h[12:14] and p[31] == model["workspace_bytes"] and
            p[31] > 0 and p[31] % 4096 == 0, "plan memory contract")
    require(sections[b"INSTRUCTIONS"][1] == 128*p[7], "graph operation count")
    require(p[32] & ~15 == 0 and (not p[32] & 8 or p[32] & 2) and not any(p[33:]) and (model["id"] != 1 or not p[32] & 5),
            "unknown plan feature/reserved bits")
    require(model.get("required_features", 0) == p[32], "plan features/manifest drift")
    cursor = 0
    for op in range(p[7]):
        first, count = struct.unpack_from("<II", plan, p[9]+8*op)
        require(first == cursor and (count > 0 or p[32] & 5) and first+count <= p[8],
                "plan index coverage")
        for record in range(first, first+count):
            require(struct.unpack_from("<I", plan, p[11]+512*record+4)[0] == op,
                    "plan record operation owner")
        cursor += count
    require(cursor == p[8], "unowned plan records")
    tensor_base, tensor_bytes = sections[b"TENSORS"]
    require(tensor_bytes % 128 == 0, "tensor table geometry")
    for kind, tid in (("input", p[29]), ("output", p[30])):
        require(tid < tensor_bytes//128, f"{kind} tensor ID")
        t = struct.unpack_from("<32I", blob, tensor_base+128*tid)
        require(t[0] == tid and t[1] == t[5] == t[7] == t[9] == 0 and
                t[2] in (1, 2, 3, 4) and 0 < t[4] <= 8 and
                t[6] == model[f"{kind}_offset"] and t[8] == model[f"{kind}_bytes"],
                f"{kind} tensor descriptor")
        shape = list(t[12:12+t[4]])
        require(all(shape) and math.prod(shape)*(1, 2, 4, 8)[t[2]-1] == t[8], f"{kind} tensor shape")
        if kind == "input":
            require(shape == model["input_shape"] and
                    ("int8", "int16", "int32", "int64")[t[2]-1] == model["input_dtype"],
                    "input tensor shape/dtype contract")
        else:
            require(t[2] == model["output_dtype"], "output tensor dtype contract")
    check_graph_control(blob, model, h, p, sections)
    return p[32]


def record_spans(w, constants_bytes, workspace_bytes, predecoded, packed_feature=False):
    """Validate a relocatable record, including every maximum accessed byte.

    This is integer descriptor validation, not tensor execution. Bounds cover
    all affine jobs and their inner accesses; intermediate overflow is rejected
    before a model is allowed to become resident.
    """
    engine, _, flags, opcode, ad, bd, yd, rank = w[:8]
    require(engine in ENGINE_OPS and opcode in ENGINE_OPS[engine] and rank <= 8 and
            all(d in (1, 2, 3, 4) for d in (ad, bd, yd)), "record engine/opcode/dtype/rank")
    require(not any(w[56:64]) and not any(w[89:91]), "record reserved words")
    dims = list(w[24:24+rank])
    require(all(d > 0 for d in dims) and math.prod(dims) <= 0xFFFFFFFF, "outer iteration product")
    require(not any(w[24+rank:32]), "unused dimensions")
    spans = []
    for lane in range(3):
        steps = w[32+lane*8:40+lane*8]
        require(not any(steps[rank:]), "unused strides")
        rewinds = [(d-1)*s for d, s in zip(dims, steps)]
        require(all(v <= 0xFFFFFFFF for v in rewinds) and sum(rewinds) <= 0xFFFFFFFF,
                "affine rewind/span overflow")
        spans.append(sum(rewinds))
        if predecoded:
            require(list(w[91+lane*8:99+lane*8]) == rewinds+[0]*(8-rank), "predecoded rewind")
    if predecoded:
        require(list(w[115:118]) == spans and w[118] == AFFINE_MARKER and
                w[119] == math.prod(dims) and not any(w[122:]), "AFF1 span/marker/iterations")
        require(not any(w[120:122]) or
                (packed_feature and engine == 5 and w[120] == 0x314b5057), "WPK1 feature/marker")
        require(all(d > 1 for d in dims), "singleton axis remains in predecoded plan")
    else:
        require(not any(w[91:]), "legacy record reserved words")
    aw, bw, yw = (1 << (d-1) for d in (ad, bd, yd))

    def extent(pointer, size=1, span=0, constant=None):
        tagged, offset = bool(pointer & 0x80000000), pointer & 0x7FFFFFFF
        if constant is not None:
            require(tagged == constant, "record pointer region tag")
        capacity = constants_bytes if tagged else workspace_bytes
        require(0 < size <= 0xFFFFFFFF and offset+span+size <= capacity,
                "record pointer/inner/outer extent")
    # Even unused pointers are relocated by the hardware iterator.
    for pointer in w[8:17]:
        extent(pointer)
    require(not w[10] & 0x80000000, "constant destination")
    inner = [1, 1, 1]
    if engine in (1, 4):
        require(w[64] > 0, "empty element/copy record")
        inner = [(w[64]-1)*w[65]+aw, 1, (w[64]-1)*w[67]+yw]
        if engine == 1 and opcode in (4, 5):
            inner[1] = (w[64]-1)*w[66]+bw
        if engine == 1 and (opcode == 1 or flags & 4):
            require(0 < w[17] < 0x80000000 and not w[18] and w[19] <= 62 and yd in (1, 2),
                    "element quantization parameters")
    elif engine == 2:
        require(opcode == 20 and flags == 1 and ad == yd == 1 and w[64] > 0,
                "ResNet INT8 GAP record")
        inner[0] = (w[64]-1)*w[65]+aw
        inner[2] = yw
    elif engine == 5:
        ic, ih, iw, oc, oh, ow, kh, kw, sh, sw, pt, pl, dh, dw, group, linear = w[64:80]
        require(0 < ic <= 4096 and 0 < oc <= 4096 and
                all(0 < d <= 4096 for d in (ih, iw, oh, ow)) and
                0 < kh <= 31 and 0 < kw <= 31 and
                all(0 < d <= 64 for d in (sh, sw, dh, dw)) and
                pt < 65536 and pl < 65536 and group == 1 and
                linear == int(opcode == 3) and ad in (1, 2) and
                yd == (1 if flags == 1 else 3) and w[20] == aw*8, "convolution descriptor")
        icpg, ocpg, full_k = ic, oc, ic*kh*kw
        require(list(w[84:89]) == [icpg, ocpg, full_k, ih*iw*aw, oh*ow*yw], "convolution derived fields")
        require(all(d in (3, 4) for d in w[80:83]) and not w[83], "convolution parameter dtypes")
        require(not w[120] or (kh == kw == 3 and w[121] == ((ic+7)//8)*72 and not w[11] & 7),
                "WPK1 geometry/stride/alignment")
        extent(w[11], oc*(w[121] if w[120] else full_k), constant=True)
        for pointer, dtype in zip(w[12:15], w[80:83]):
            extent(pointer, oc*(1 << (dtype-1)), constant=True)
        extent(w[17], oh*ow*32*8 if full_k > 1024 else 1, constant=False)
        inner = [ic*ih*iw*aw, 1, oc*oh*ow*yw]
        if flags in (8, 16, 24):
            require(math.prod(dims) == 1 and yd == 3 and
                    (w[21] == 3 if flags == 16 else w[21] in (1, 2) and 0 < w[18] < 0x80000000 and w[19] <= 62),
                    "fused convolution geometry/quantizer")
            extent(w[15], oc*oh*ow*(1 << (w[21]-1)), constant=False)
    else:
        ih, iw, oh, ow, kh, kw, sh, sw, pt, pl = w[64:74]
        require(min(ih, iw, oh, ow, kh, kw, sh, sw) > 0 and ad == yd == (1 if flags == 1 else 3),
                "maxpool geometry/dtype")
        inner = [ih*iw*aw, 1, oh*ow*yw]
    for lane in range(3):
        extent(w[8+lane], inner[lane], spans[lane], False if lane == 2 else None)
    return spans


def check_graph_control(blob, model, h, p, sections):
    """Full PS validation omitted from the compact production PL frontend."""
    predecoded = bool(p[32] & PREDECODED_FEATURE)
    require(not h[15] and not any(h[18:]), "package reserved header words")
    if predecoded:
        descriptor = blob[PREDECODED_OFFSET:PREDECODED_OFFSET+128]
        q = struct.unpack("<32I", descriptor)
        copy = bytearray(descriptor); copy[124:128] = bytes(4)
        expected = [*struct.unpack("<2I", b"NPUPRE1\0"), 1, 128, model["id"], 2,
                    h[8], p[31], h[12], h[13], h[17], p[7]]
        for name in SECTION_NAMES:
            expected.extend(sections[name])
        require(list(q[:22]) == expected and not any(q[22:31]) and crc(copy) == q[31],
                "NPUPRE1 descriptor identity/sections/CRC")
        previous = 4096
        for name in SECTION_NAMES:
            offset, size = sections[name]
            require(previous <= offset and size > 0, "predecoded section order/nonempty")
            previous = offset+size
    tensors = []
    base, size = sections[b"TENSORS"]
    require(size > 0 and size % 128 == 0, "tensor table geometry")
    for index in range(size//128):
        t = struct.unpack_from("<32I", blob, base+128*index)
        require(t[0] == index and t[1] in (0, 1) and t[2] in (1, 2, 3, 4) and
                t[4] <= 8 and t[5] == t[1] and not t[7] and not t[9] and
                t[20] == 64 and not any(t[21:]) and not any(t[12+t[4]:20]), "tensor schema/reserved")
        require(t[3] == (16 if not t[1] and t[2] >= 3 else 0), "tensor fractional bits")
        shape = t[12:12+t[4]]
        require(all(shape) and math.prod(shape)*(1 << (t[2]-1)) == t[8] and
                t[6] % 64 == 0 and t[6] < 0x80000000 and
                t[6]+t[8] <= (sections[b"CONSTANTS"][1] if t[1] else h[10]), "tensor shape/region")
        require((t[1] and t[10:12] == (0xFFFFFFFF, 0xFFFFFFFF)) or
                (not t[1] and (t[10] < p[7] or index == h[12] and t[10] == 0xFFFFFFFF) and
                 (t[11] < p[7] or index == h[13] and t[11] == p[7]) and
                 (t[10] == 0xFFFFFFFF or t[10] <= t[11])), "tensor lifetime")
        tensors.append(t)
    require(h[12] < len(tensors) and h[13] < len(tensors) and
            not tensors[h[12]][1] and not tensors[h[13]][1] and
            (h[17] == 0xFFFFFFFF or h[17] < len(tensors) and tensors[h[17]][1]), "package input/output/LUT IDs")
    instructions = []
    ibase, isize = sections[b"INSTRUCTIONS"]
    abase, asize = sections[b"ATTRIBUTES"]
    require(isize == p[7]*128, "instruction table geometry")
    for index in range(p[7]):
        ins = struct.unpack_from("<32I", blob, ibase+128*index)
        require(ins[0] in range(1, 21) and ins[0] not in (6, 7, 8) and
                (ins[0] != 20 or model["id"] == 1) and
                not ins[1] and 1 <= ins[2] <= 4 and 1 <= ins[3] <= 4 and
                not any(ins[15:]) and not any(v != 0xFFFFFFFF for v in ins[4+ins[2]:8]+ins[8+ins[3]:12]),
                "instruction schema/reserved")
        require(all(tid < len(tensors) for tid in ins[4:4+ins[2]]+ins[8:8+ins[3]]) and
                all(not tensors[tid][1] for tid in ins[8:8+ins[3]]), "instruction tensor references/destinations")
        begin, length = ins[12:14]
        require(begin % 16 == 0 and begin+length <= asize, "attribute bounds")
        cursor, end, previous = begin, begin+length, 0
        while cursor < end:
            require(cursor+16 <= end, "partial attribute")
            field, kind, count, value = struct.unpack_from("<IHHq", blob, abase+cursor)
            require(previous < field <= 22 and kind in (1, 2, 3), "attribute order/type")
            if kind == 3:
                require(0 <= value and value % 8 == 0 and count <= 8 and value+count*8 <= begin+length,
                        "attribute vector bounds")
                end = min(end, value)
                require(cursor+16 <= end, "attribute vector/header overlap")
            else:
                require(count == 1 and (kind != 2 or 0 <= value < len(tensors) and tensors[value][1]),
                        "attribute scalar/constant reference")
            previous, cursor = field, cursor+16
        require(cursor == end, "attribute exact extent")
        instructions.append(ins)
    absorbed = set()
    for op, ins in enumerate(instructions):
        first, count = struct.unpack_from("<II", blob, model["plan_offset"]+p[9]+8*op)
        if not count:
            require(op in absorbed, "unjustified absorbed instruction")
            continue
        require(op not in absorbed, "absorbed instruction unexpectedly has records")
        for record in range(first, first+count):
            w = struct.unpack_from("<128I", blob, model["plan_offset"]+p[11]+512*record)
            require(w[1] == op and w[3] == ins[0], "record owner/opcode")
            if model["id"] == 1:
                require(w[2] == 1 and w[3] in (2, 3, 4, 11, 19, 20), "ResNet legacy record")
            else:
                require(w[0] != 2, "GAP is reserved for ResNet")
                require(w[2] == 0 or p[32] & 1 and w[2] in (2, 6) and w[0] == 1 and
                        w[3] == 9 and w[4] == 3 and w[6] in ((1, 2) if w[2] == 6 else (3,)) or
                        p[32] & 4 and w[2] in (8, 16, 24) and w[0] == 5 and w[3] == 2 and w[6] == 3,
                        "record feature flags")
            if w[2] in (8, 16, 24):
                n = 1 if w[2] == 8 else 3 if w[2] == 24 else 2
                require(op+n < len(instructions) and ins[3] == 1, "Conv absorption extent")
                previous = ins[8]
                if w[2] & 16:
                    sig, mul = instructions[op+1:op+3]
                    require(sig[0] == 9 and sig[2:4] == (1, 1) and sig[4] == previous and
                            mul[0] == 5 and mul[2:4] == (2, 1) and
                            sorted(mul[4:6]) == sorted((previous, sig[8])), "Conv SiLU ownership")
                    previous = mul[8]
                if w[2] & 8:
                    quant = instructions[op+n]
                    require(quant[0] == 1 and quant[2:4] == (1, 1) and quant[4] == previous, "Conv Quant ownership")
                absorbed.update(range(op+1, op+n+1))
            if w[2] in (2, 6):
                require(op+1 < len(instructions), "SiLU absorption extent")
                mul = instructions[op+1]
                require(ins[2:4] == (1, 1) and mul[0] == 5 and mul[2:4] == (2, 1) and
                        sorted(mul[4:6]) == sorted((ins[4], ins[8])), "SiLU absorption ownership")
                absorbed.add(op+1)
                if w[2] == 6:
                    require(op+2 < len(instructions), "SiLU QUANT extent")
                    quant = instructions[op+2]
                    require(quant[0] == 1 and quant[2:4] == (1, 1) and quant[4] == mul[8], "SiLU QUANT ownership")
                    absorbed.add(op+2)
            record_spans(w, sections[b"CONSTANTS"][1], p[31], predecoded, bool(p[32] & 8))
    for index in (20, 23, 26):
        offset, count, dtype = p[index:index+3]
        require(dtype in (3, 4) and count >= 2 and offset % (1 << (dtype-1)) == 0 and
                offset+count*(1 << (dtype-1)) <= sections[b"CONSTANTS"][1], "LUT region")


def check_manifest(data):
    require(isinstance(data, dict), "manifest object required")
    require(data.get("format") == "unified-npu-sd" and data.get("schema") == 1, "SD manifest schema")
    abi = data.get("abi")
    require(abi in (ABI, dict(ABI, plan_known_features=1), dict(ABI, plan_known_features=3), dict(ABI, plan_known_features=7)), "runtime ABI")
    require(data.get("ddr_bytes") == DDR_BYTES and
            data.get("reserved") == {"base": RESERVED_BASE, "bytes": RESERVED_BYTES}, "DDR/reservation ABI")
    require(data.get("workspace_base") == WORKSPACE_BASE, "workspace base")
    cap = data.get("workspace_capacity", 0)
    require(type(cap) is int and 0 < cap <= WORKSPACE_MAX and cap % 4096 == 0, "workspace capacity")
    models = data.get("models")
    require(isinstance(models, list) and len(models) == len(SLOTS) and
            all(isinstance(m, dict) for m in models), "two model records")
    for m in models:
        require(all(type(m.get(k)) is int and 0 <= m[k] <= 0xFFFFFFFF for k in FIELDS), "integer model fields")
        require(m["id"] in SLOTS, "model ID")
        require(isinstance(m.get("name"), str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,79}", m["name"]), "model name")
        base, slot = SLOTS[m["id"]]
        require(m["model_base"] == base and 0 < m["image_bytes"] <= slot and m["image_bytes"] % 4 == 0, "model DDR slot")
        require(m["plan_offset"] >= 4096 and m["plan_offset"] % 4096 == 0 and
                m["plan_bytes"] >= 4096 and m["plan_bytes"] % 4096 == 0 and
                m["plan_offset"] + m["plan_bytes"] == m["image_bytes"], "model plan bounds")
        require(0 < m["workspace_bytes"] <= cap and m["workspace_bytes"] % 4096 == 0, "workspace extent")
        require(m["graph_operations"] > 0 and m["input_width"] > 0 and m["input_height"] > 0,
                "nonempty graph/input geometry")
        require(m.get("file") == f"models/m{m['id']}/model.bin" and
                m.get("golden_input") == f"models/m{m['id']}/input.bin", "model bundle paths")
        require(m.get("input_shape") == [1, 3, m["input_height"], m["input_width"]] and
                m.get("input_dtype") in ("int8", "int16", "int32", "int64"), "input shape/dtype")
        for kind in ("input", "output"):
            require(m[f"{kind}_bytes"] > 0 and
                    m[f"{kind}_offset"] + m[f"{kind}_bytes"] <= m["workspace_bytes"], f"{kind} bounds")
        require(m["output_dtype"] in (1, 2, 3, 4), "output dtype")
        width = (1, 2, 4, 8)[m["output_dtype"]-1]
        require(m["output_offset"] % width == 0 and m["output_bytes"] % width == 0, "output alignment")
        require(all(isinstance(m.get(k), str) and re.fullmatch(r"[0-9a-f]{64}", m[k])
                    for k in ("image_sha256", "input_sha256")), "SHA256 encoding")
        require(type(m.get("required_features")) is int and m["required_features"] & ~abi["plan_known_features"] == 0 and
                (m["id"] != 1 or not m["required_features"] & 5), "required features")
    require({m["id"] for m in models} == set(SLOTS), "model IDs must be 1 and 3")
    return sorted(models, key=lambda m: m["id"])
