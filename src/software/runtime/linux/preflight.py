#!/usr/bin/env python3
"""Read-only Linux DT/SD checks. Never opens the NPU device or accesses MMIO."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import struct
import sys
from manifest import (RESERVED_BASE, RESERVED_BYTES, child_file, check_image,
                      check_manifest, parse_json, require, sha)

MAX_DT_PROPERTY = 65536


def cells(node, name, default):
    prop = node / name
    if not prop.exists():
        return default
    data = bounded_property(node, name)
    require(len(data) == 4, "invalid DT " + str(prop))
    value = struct.unpack(">I", data)[0]
    require(0 <= value <= 3, "unsupported DT cell width " + str(prop))
    return value


def bounded_property(node, name):
    prop = node / name
    require(prop.stat().st_size <= MAX_DT_PROPERTY, "oversized DT property " + str(prop))
    data = prop.read_bytes()
    require(len(data) <= MAX_DT_PROPERTY, "oversized DT property " + str(prop))
    return data


def ranges(node):
    parent = node.parent
    address_cells = cells(parent, "#address-cells", 2)
    size_cells = cells(parent, "#size-cells", 1)
    require(address_cells in (1, 2) and size_cells in (1, 2),
            "target MMIO requires 1/2 address and size cells: " + str(node))
    data = bounded_property(node, "reg")
    stride = 4 * (address_cells + size_cells)
    require(bool(data) and len(data) % stride == 0, "invalid DT reg " + str(node))
    result = []
    for offset in range(0, len(data), stride):
        split = offset + address_cells * 4
        base = int.from_bytes(data[offset:split], "big")
        size = int.from_bytes(data[split:offset + stride], "big")
        require(size > 0 and base + size <= 1 << 64, "invalid DT register extent " + str(node))
        result.append((base, size))
    return result


def root_mmio_ranges(node, root):
    """Translate only memory-address buses to root physical addresses.

    CPU/I2C/SPI zero-size cells and PCI 3-cell address identifiers are not MMIO
    physical intervals. A bus without ranges is not presumed identity-mapped.
    Target runtime/reserved nodes are parsed strictly separately below.
    """
    parent = node.parent
    ac, sc = cells(parent, "#address-cells", 2), cells(parent, "#size-cells", 1)
    if ac not in (1, 2) or sc not in (1, 2):
        return []
    intervals = ranges(node)
    bus = parent
    while bus != root:
        if not bus.is_relative_to(root) or not (bus / "ranges").is_file():
            return []
        child_ac = cells(bus, "#address-cells", 2)
        parent_ac = cells(bus.parent, "#address-cells", 2)
        size_cells = cells(bus, "#size-cells", 1)
        if child_ac not in (1, 2) or parent_ac not in (1, 2) or size_cells not in (1, 2):
            return []
        raw = bounded_property(bus, "ranges")
        if raw:
            stride = (child_ac + parent_ac + size_cells) * 4
            require(len(raw) % stride == 0, "invalid memory bus ranges " + str(bus))
            translations = []
            for offset in range(0, len(raw), stride):
                first = offset + child_ac * 4
                second = first + parent_ac * 4
                child = int.from_bytes(raw[offset:first], "big")
                physical = int.from_bytes(raw[first:second], "big")
                length = int.from_bytes(raw[second:offset+stride], "big")
                require(length > 0 and child + length <= 1 << 64 and physical + length <= 1 << 64,
                        "overflow/empty memory bus range " + str(bus))
                translations.append((child, physical, length))
            translated = []
            for address, length in intervals:
                matches = [(physical + address - child, length) for child, physical, count in translations
                           if child <= address and address + length <= child + count]
                if len(matches) != 1:
                    return []
                translated.append(matches[0])
            intervals = translated
        # Empty ranges is the DT's explicit identity translation.
        bus = bus.parent
    return intervals


def phandle(node):
    values = []
    for name in ("phandle", "linux,phandle"):
        if (node / name).is_file():
            raw = bounded_property(node, name)
            require(len(raw) == 4, "invalid DT phandle " + str(node / name))
            value = struct.unpack(">I", raw)[0]
            require(value not in (0, 0xFFFFFFFF), "reserved DT phandle " + str(node))
            values.append(value)
    require(values and len(set(values)) == 1, "missing/conflicting DT phandle " + str(node))
    return values[0]


def enabled(node, root):
    while node.is_relative_to(root):
        status = node / "status"
        if status.exists() and status.read_bytes().rstrip(b"\0") not in (b"okay", b"ok"):
            return False
        if node == root:
            break
        node = node.parent
    return True


def check_dt(root):
    require(root.is_dir(), "live device tree absent: " + str(root))
    reserved = root / "reserved-memory"
    require(reserved.is_dir(), "base DT must reserve DDR before cold boot")
    matches = [node for node in reserved.iterdir() if node.is_dir() and
               (node / "reg").exists() and ranges(node) == [(RESERVED_BASE, RESERVED_BYTES)]]
    require(len(matches) == 1 and enabled(matches[0], root) and
            (matches[0] / "no-map").is_file() and not (matches[0] / "reusable").exists(),
            "need exact no-map [0x10000000,0x20000000) in boot-time DT")
    runtime = [prop.parent for prop in root.rglob("compatible")
               if b"local,npu100-runtime-v3" in prop.read_bytes().split(b"\0") and enabled(prop.parent, root)]
    require(len(runtime) == 1, "exactly one enabled npu100-runtime-v3 DT node required")
    node = runtime[0]
    expected = [(0x43C10000, 0x8000), (0x43C18000, 0x8000),
                (0x41200000, 0x10000), (0x41210000, 0x10000)]
    require(ranges(node) == expected, "runtime register window contract")
    require(root_mmio_ranges(node, root) == expected,
            "runtime register addresses must translate to the fixed physical MMIO windows")
    require(not (node / "dma-coherent").exists(), "HP ports must remain noncoherent")
    for name in ("memory-region", "clocks", "resnet-gpios", "neu-gpios"):
        require((node / name).is_file(), "missing DT property " + name)
    memory_region = bounded_property(node, "memory-region")
    require(len(memory_region) == 4 and struct.unpack(">I", memory_region)[0] == phandle(matches[0]),
            "runtime memory-region must point to the exact no-map reservation")
    require(bounded_property(node, "clock-names").split(b"\0")[:2] == [b"fclk0", b"fclk1"], "FCLK0/FCLK1 names")
    require(bounded_property(node, "assigned-clock-rates") == struct.pack(">II", 100000000, 100000000),
            "FCLK0 and FCLK1 must both be 100 MHz")
    conflicts = []
    # Translate root-addressable memory buses. Do not interpret CPU indices,
    # I2C addresses, SPI chip-selects, or PCI address flags as physical MMIO.
    for prop in root.rglob("reg"):
        other = prop.parent
        if other == node or not enabled(other, root) or not (other / "compatible").exists():
            continue
        for base, size in root_mmio_ranges(other, root):
            if any(base < b + count and b < base + size for b, count in expected):
                conflicts.append(str(other.relative_to(root)))
    require(not conflicts, "disable overlapping generated CSR/GPIO nodes: " + ", ".join(conflicts))
    return dict(reservation=str(matches[0]), runtime_node=str(node),
                pl_identity="not accessed; bootloader PL/XSA/FCLK/reset matching is required separately")


def check_bundle(root):
    raw = (root / "manifest.json").read_bytes()
    receipt = (root / "manifest.sha256").read_text("ascii").split()
    require(receipt == [sha(raw), "manifest.json"], "manifest SHA256 receipt")
    models = check_manifest(parse_json(raw))
    for model in models:
        check_image(child_file(root, model["file"]).read_bytes(), model)
        sample = child_file(root, model["golden_input"]).read_bytes()
        require(len(sample) == model["input_bytes"] and sha(sample) == model["input_sha256"], "sample tensor integrity")
    return dict(root=str(root), models=[m["id"] for m in models], integrity="PASS")


def check_boot_receipt(path):
    """Check deployed files only, never infer loaded PL from a disk hash."""
    lines = path.read_text("utf-8").splitlines()
    require(1 <= len(lines) <= 32, "boot receipt must name 1..32 absolute files")
    checked = []
    for line in lines:
        require(re.fullmatch(r"[0-9a-fA-F]{64} [ *]/[^\r\n]+", line) is not None,
                "boot receipt requires unescaped sha256sum lines and absolute paths")
        artifact = Path(line[66:])
        require(artifact.is_absolute() and artifact.is_file(), "missing boot artifact " + str(artifact))
        digest = hashlib.sha256()
        with artifact.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        require(digest.hexdigest() == line[:64].lower(), "boot file SHA256 mismatch " + str(artifact))
        checked.append(str(artifact))
    return dict(files=checked, integrity="PASS", loaded_pl_verified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--dt-root", type=Path, default=Path("/sys/firmware/devicetree/base"))
    parser.add_argument("--files-only", action="store_true", help="check SD files only, e.g. before copying from Windows")
    parser.add_argument("--boot-receipt", type=Path, help="absolute-path sha256sum receipt for actual deployed boot files")
    parser.add_argument("--device", type=Path, help="check device node presence without opening it")
    args = parser.parse_args()
    report = dict(scope="READ_ONLY_NO_MMIO", kernel=platform.release(), bundle=check_bundle(args.bundle))
    if not args.files_only:
        report["device_tree"] = check_dt(args.dt_root)
    if args.boot_receipt:
        report["boot_files"] = check_boot_receipt(args.boot_receipt)
    if args.device:
        require(args.device.is_char_device(), "NPU character device absent: " + str(args.device))
        report["device_present"] = str(args.device)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, struct.error) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
