#!/usr/bin/env python3
"""Stage three existing npu100 packages in a NEW directory; never write a device.

This copies frozen artifacts and validates bytes/descriptors. It does not run a
model, generator, compiler or FPGA flow. Source directories are always read-only.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import struct
from manifest import (ABI, CATALOG, DDR_BYTES, RESERVED_BASE, RESERVED_BYTES,
                      WORKSPACE_BASE, WORKSPACE_MAX, check_image, check_manifest,
                      read_json, require, sha, crc, FIELDS, model_path)


def binary_manifest(manifest):
    """Keep standalone's two-record NPUSDM1; COCO uses coco80/model.bin.

    Linux consumes schema-2 JSON with all three records. Standalone consumes
    IDs 1/3 here and validates the separate COCO file against its local catalog.
    """
    body = bytearray()
    models = [m for m in manifest["models"] if m["id"] in (1, 3)]
    require({m["id"] for m in models} == {1, 3}, "baremetal records 1/3")
    for m in sorted(models, key=lambda item: item["id"]):
        record = bytearray(320)
        struct.pack_into("<16I", record, 0, *[m[k] for k in FIELDS], m["required_features"])
        record[64:96] = bytes.fromhex(m["image_sha256"])
        record[96:128] = bytes.fromhex(m["input_sha256"])
        for offset, capacity, value in ((128, 80, m["name"]), (208, 112, m["file"])):
            encoded = value.encode("ascii")
            require(len(encoded) < capacity, "binary manifest string capacity")
            record[offset:offset+len(encoded)] = encoded
        body.extend(record)
    head = bytearray(256)
    head[:8] = b"NPUSDM1\0"
    struct.pack_into("<11I", head, 8, 1, 256, 320, 2, DDR_BYTES, RESERVED_BASE,
                     RESERVED_BYTES, WORKSPACE_BASE, WORKSPACE_MAX, crc(body), 0)
    struct.pack_into("<I", head, 48, crc(head))
    return bytes(head+body)


def pack(model_directories, destination):
    """model_directories maps logical ID 1/3/4 to existing artifact folders."""
    destination = Path(destination).absolute()
    require(not destination.exists(), "destination must be new")
    require(destination.name not in ("", ".", "..") and destination.parent.is_dir(),
            "ordinary staging directory with existing parent required")
    require(set(model_directories) == {1, 3, 4}, "all three source directories required")
    manifest = dict(format="npu100-sd", schema=2, version="2.0.0",
                    profile="npu100-three-model-256", status="source_only_unverified",
                    accuracy_validated=False, rtl_verified=False, board_verified=False,
                    created_utc=datetime.now(timezone.utc).isoformat(), abi=dict(ABI),
                    ddr_bytes=DDR_BYTES, reserved={"base": RESERVED_BASE, "bytes": RESERVED_BYTES},
                    raw_slots={"base": 0x12000000, "count": 8, "stride": 0x400000,
                               "frame_bytes": 1280*720*2},
                    workspace_base=WORKSPACE_BASE, workspace_capacity=WORKSPACE_MAX, models=[])
    artifacts = []
    for model_id in (1, 3, 4):
        folder = Path(model_directories[model_id]).resolve(strict=True)
        require(folder.is_dir() and not destination.resolve().is_relative_to(folder),
                "destination must be outside immutable source tree")
        image = (folder / "ddr.bin").read_bytes()
        inp = (folder / "input.bin").read_bytes()
        m = dict(CATALOG[model_id])
        m.update(file=model_path(model_id, "model.bin"),
                 golden_input=model_path(model_id, "input.bin"),
                 input_shape=[1, 3, m["input_height"], m["input_width"]],
                 input_dtype="int8" if model_id == 1 else "int32",
                 input_sha256=sha(inp), input_kind="frozen_sample",
                 input_reference_validated=False)
        require(len(inp) == m["input_bytes"], "source input length differs from npu100 catalog")
        im_path = folder / "input_manifest.json"
        if im_path.exists():
            im = read_json(im_path)
            require(im["bytes"] == len(inp) and im["sha256"] == sha(inp) and
                    im["dtype"] == m["input_dtype"] and im["shape"] == m["input_shape"],
                    "input manifest drift")
        check_image(image, m)
        manifest["models"].append(m)
        artifacts.append((m, image, inp, folder))
    check_manifest(manifest)
    temporary = destination.with_name(destination.name + ".packing")
    require(not temporary.exists(), "unfinished .packing directory exists; inspect before retry")
    temporary.mkdir()
    # Failure preserves staging evidence; source folders remain read-only.
    for m, image, inp, folder in artifacts:
        out = temporary / Path(m["file"]).parent
        out.mkdir(parents=True)
        (out / "model.bin").write_bytes(image)
        (out / "input.bin").write_bytes(inp)
        for name in ("execution_manifest.json", "input_manifest.json", "model_config.tcl"):
            if (folder / name).is_file():
                shutil.copyfile(folder / name, out / name)
    encoded = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    (temporary / "manifest.json").write_bytes(encoded)
    (temporary / "manifest.sha256").write_text(sha(encoded) + "  manifest.json\n", "ascii")
    (temporary / "manifest.bin").write_bytes(binary_manifest(manifest))
    (temporary / "BUNDLE_VERSION").write_text("npu100-sd/2\n", "ascii")
    temporary.rename(destination)
    print(f"Created three-model staging bundle: {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model1", type=Path, required=True, help="ResNet artifact folder")
    parser.add_argument("--model3", type=Path, required=True, help="NEU6 artifact folder")
    parser.add_argument("--model4", type=Path, required=True, help="COCO80 artifact folder")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pack({1: args.model1, 3: args.model3, 4: args.model4}, args.output)
