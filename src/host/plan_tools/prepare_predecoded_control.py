#!/usr/bin/env python3
"""Create a separate PS-predecoded NPUPRE1/AFF1 model image.

Only descriptor/file processing is performed. No tensor execution, compiler,
RTL flow, quantization or frozen artifact mutation is involved. The original
instruction order and exact inner records remain; affine singleton removal and
three-pointer contiguous-axis merging reduce control work without graph-wide
expansion. The PS loaders independently validate this contract before DDR use.
The production entry point accepts only ResNet18 ID 1 and YOLOX ID 3.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import shutil
import struct
import sys

RUNTIME = Path(__file__).resolve().parent
sys.path.insert(0, str(RUNTIME))
from plan_manifest import (AFFINE_MARKER, PREDECODED_OFFSET, SECTION_NAMES,
                      check_image, crc, read_json, require, sha)


def model_record(folder, manifest, blob):
    inp = read_json(folder / "input_manifest.json")
    return dict(id=manifest["model_id"], image_bytes=len(blob), image_sha256=sha(blob),
                image_crc=crc(blob), plan_offset=manifest["plan_offset"],
                plan_bytes=manifest["plan_bytes"], workspace_bytes=manifest["workspace_bytes"],
                graph_operations=manifest["graph_operations"], input_offset=manifest["input_offset"],
                input_bytes=manifest["input_bytes"], output_offset=manifest["output_offset"],
                output_bytes=manifest["output_bytes"], output_dtype=manifest["output_dtype"],
                input_shape=inp["shape"], input_dtype=inp["dtype"],
                required_features=struct.unpack_from("<I", blob, manifest["plan_offset"]+128)[0])


def compact_record(words, coalesce_inner=False):
    """Preserve element order while optionally joining legal inner vectors."""
    w = list(words)
    rank = w[7]
    axes = [(w[24+i], [w[32+8*p+i] for p in range(3)])
            for i in range(rank) if w[24+i] != 1]
    cursor = len(axes)-2
    while cursor >= 0:
        outer_dim, outer_steps = axes[cursor]
        inner_dim, inner_steps = axes[cursor+1]
        if all(outer_steps[p] == inner_dim*inner_steps[p] for p in range(3)):
            axes[cursor:cursor+2] = [(outer_dim*inner_dim, inner_steps)]
        cursor -= 1
    if coalesce_inner and w[0] in (1, 4):
        used = (0, 1, 2) if w[0] == 1 and w[3] in (4, 5) else (0, 2)
        # A larger job checks the complete source/output envelope. Only join
        # independent regions or exactly matching in-place traversals.
        dtype_bytes = {1: 1, 2: 2, 3: 4, 4: 8}
        safe = True
        for lane in used:
            if lane == 2:
                continue
            source_base, output_base = w[8+lane], w[10]
            source_span = sum((d-1)*s[lane] for d, s in axes)
            output_span = sum((d-1)*s[2] for d, s in axes)
            source_end = source_base+source_span+(w[64]-1)*w[65+lane]+dtype_bytes[w[4+lane]]
            output_end = output_base+output_span+(w[64]-1)*w[67]+dtype_bytes[w[6]]
            same_region = source_base >> 31 == output_base >> 31
            overlap = same_region and source_base < output_end and output_base < source_end
            inplace = (source_base == output_base and w[4+lane] == w[6] and
                       w[65+lane] == w[67] and
                       all(s[lane] == s[2] for _, s in axes))
            safe &= not overlap or inplace
        while safe and axes:
            dim, steps = axes[-1]
            count = w[64]*dim
            if count > 0xFFFFFFFF or not all(steps[p] == w[64]*w[65+p] for p in used):
                break
            w[64] = count
            axes.pop()
    require(len(axes) <= 8 and math.prod(d for d, _ in axes) <= 0xFFFFFFFF,
            "compacted outer iteration overflow")
    w[7] = len(axes)
    w[24:56] = [0]*32
    w[91:128] = [0]*37
    for i, (dim, steps) in enumerate(axes):
        w[24+i] = dim
        for lane, step in enumerate(steps):
            rewind = (dim-1)*step
            require(rewind <= 0xFFFFFFFF, "compacted rewind overflow")
            w[32+8*lane+i] = step
            w[91+8*lane+i] = rewind
    for lane in range(3):
        span = sum(w[91+8*lane:99+8*lane])
        require(span <= 0xFFFFFFFF, "compacted span overflow")
        w[115+lane] = span
    w[118:120] = [AFFINE_MARKER, math.prod(d for d, _ in axes)]
    return w


def prepare_model(source_dir, output_dir, coalesce_inner=False):
    source, output = Path(source_dir).resolve(), Path(output_dir).resolve()
    require(source.is_dir() and not output.exists() and output.parent.is_dir() and
            source != output and source not in output.parents, "new separate output directory required")
    original = read_json(source / "execution_manifest.json")
    require(original["model_id"] in (1, 3), "production model IDs must be 1 and 3")
    old = (source / "ddr.bin").read_bytes()
    require(sha(old) == original["ddr_sha256"] and len(old) == original["ddr_bytes"], "source DDR identity")
    check_image(old, model_record(source, original, old))
    h = list(struct.unpack_from("<64I", old))
    old_package = old[:h[8]]
    require((source / "model.aipkg").read_bytes() == old_package, "source package/DDR identity")
    plan = bytearray(old[original["plan_offset"]:])
    require((source / "execution_plan.bin").read_bytes() == plan, "source plan/DDR identity")
    p = list(struct.unpack_from("<64I", plan))
    require(not p[32] & 2, "source is already predecoded; use the original immutable source")
    image = bytearray(old_package)
    require(not any(image[PREDECODED_OFFSET:PREDECODED_OFFSET+128]), "NPUPRE1 padding is occupied")
    sections = {}
    for i in range(5):
        name, offset, size = struct.unpack_from("<16sQQ", image, 256+64*i)
        sections[name.rstrip(b"\0")] = (offset, size)
    q = [*struct.unpack("<2I", b"NPUPRE1\0"), 1, 128, h[4], 2, h[8], p[31],
         h[12], h[13], h[17], p[7]]
    for name in SECTION_NAMES:
        q.extend(sections[name])
    q.extend([0]*10)
    descriptor = bytearray(struct.pack("<32I", *q))
    struct.pack_into("<I", descriptor, 124, crc(descriptor))
    image[PREDECODED_OFFSET:PREDECODED_OFFSET+128] = descriptor
    h[16] = crc(image[256:]); h[14] = 0
    struct.pack_into("<64I", image, 0, *h)
    h[14] = crc(image[:256]); struct.pack_into("<64I", image, 0, *h)
    ranks_before, ranks_after = Counter(), Counter()
    iterations = 0
    for index in range(p[8]):
        offset = p[11]+512*index
        w = list(struct.unpack_from("<128I", plan, offset))
        ranks_before[w[7]] += 1
        v = compact_record(w, coalesce_inner=coalesce_inner)
        ranks_after[v[7]] += 1
        iterations += v[119]
        # All numerical fields, operands and record ownership remain identical.
        require(w[:7] == v[:7] and w[8:24] == v[8:24] and w[56:64] == v[56:64] and
                w[65:91] == v[65:91] and (coalesce_inner or w[64] == v[64]),
                "numerical record changed")
        struct.pack_into("<128I", plan, offset, *v)
    p[14], p[15], p[32] = h[16], h[8], p[32] | 2
    p[16], p[17] = crc(plan[256:]), 0
    struct.pack_into("<64I", plan, 0, *p)
    p[17] = crc(plan[:256]); struct.pack_into("<64I", plan, 0, *p)
    bundle = bytes(image)+bytes(original["plan_offset"]-len(image))+bytes(plan)
    derived = dict(original)
    derived.update(source_package=str(output / "model.aipkg"), source_model_dir=str(source),
                   source_sha256=sha(image), source_derived_sha256=sha(image),
                   source_parent_package_sha256=sha(old_package), source_body_crc32=f"0x{h[16]:08X}",
                   ddr_sha256=sha(bundle), ddr_bytes=len(bundle), plan_feature_bits=p[32],
                   required_features=(["exact_silu_fusion_v1"] if p[32] & 1 else [])+["ps_predecoded_control_v1"]+
                                     (["exact_conv_fusion_v1"] if p[32] & 4 else []),
                   predecoded_control=dict(format="NPUPRE1", version=1, offset=PREDECODED_OFFSET,
                                           bytes=128, affine_format="AFF1", records=p[8],
                                           outer_ranks_before=dict(ranks_before), outer_ranks_after=dict(ranks_after),
                                           inner_jobs=iterations, full_graph_expanded=False,
                                           contiguous_inner_coalescing=coalesce_inner),
                   status="source_only_unverified", rtl_verified=False, board_verified=False,
                   integer_reference_executed=False, accuracy_validated=False,
                   frozen_sources_modified=False, numerical_records_preserved=True)
    check_image(bundle, model_record(source, derived, bundle))
    temporary = output.with_name(output.name+".preparing")
    require(not temporary.exists(), "unfinished .preparing directory exists; inspect before retry")
    # No links: derived metadata must never modify an immutable source file.
    require(not any(path.is_symlink() for path in source.rglob("*")), "source model links are not supported")
    shutil.copytree(source, temporary)
    for name, payload in (("model.aipkg", image), ("execution_plan.bin", plan), ("ddr.bin", bundle)):
        (temporary / name).write_bytes(payload)
    (temporary / "execution_manifest.json").write_text(json.dumps(derived, ensure_ascii=False, indent=2)+"\n", "utf-8")
    for path in temporary.rglob("input_manifest.json"):
        metadata = read_json(path)
        metadata.update(package_sha256=sha(image), predecoded_parent_package_sha256=sha(old_package))
        path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n", "utf-8")
    for filename in ("specialization_manifest.json",):
        path = temporary / filename
        if path.is_file():
            metadata = read_json(path)
            for key in ("package_sha256", "source_sha256", "source_derived_sha256"):
                if metadata.get(key) == sha(old_package): metadata[key] = sha(image)
            metadata.update(predecoded_control=True, predecoded_parent_package_sha256=sha(old_package))
            path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n", "utf-8")
    configs = dict(MODEL_NAME=original["model"], MODEL_ID=h[4], DDR_SHA256=sha(bundle),
                   INPUT_SHA256=sha((source / "input.bin").read_bytes()), DDR_BYTES=len(bundle), DDR_CRC=crc(bundle),
                   WORKSPACE_BYTES=p[31], PLAN_OFFSET=original["plan_offset"], PLAN_BYTES=len(plan),
                   INPUT_OFFSET=derived["input_offset"], INPUT_BYTES=derived["input_bytes"],
                   INPUT_CRC=crc((source / "input.bin").read_bytes()), OUTPUT_OFFSET=derived["output_offset"],
                   OUTPUT_BYTES=derived["output_bytes"], OUTPUT_DTYPE=derived["output_dtype"], REQUIRED_FEATURES=p[32])
    (temporary / "model_config.tcl").write_text("".join(f"set ::NPUG_{key} {value}\n" for key, value in configs.items()), "utf-8")
    prefix = original["model"].upper()
    (temporary / "model_config.h").write_text("#pragma once\n"+"".join(
        f"#define {prefix}_{key} {value}u\n" for key, value in configs.items() if isinstance(value, int)), "utf-8")
    require((temporary / "input.bin").read_bytes() == (source / "input.bin").read_bytes(), "input bytes changed")
    temporary.rename(output)
    return derived


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--coalesce-inner", action="store_true")
    args = parser.parse_args()
    print(json.dumps(prepare_model(args.source, args.output, args.coalesce_inner), ensure_ascii=False, indent=2))
