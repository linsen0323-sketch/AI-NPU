"""Derive a 160/128 ResNet package from the immutable unified 224 package.

This tool performs offline file construction only. It does not run a model,
compile RTL, produce a Golden, train, or validate accuracy. Tensor allocation
offsets and every CONSTANTS byte stay unchanged. Spatial tensor shapes, plan
geometry and the GAP gain change. The example input is a nearest-neighbor
resize of an already quantized diagnostic tensor, not camera preprocessing.
"""
from __future__ import annotations

import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import zlib

from compile_resnet_plan import align, assemble, require


def sha(data):
    return hashlib.sha256(data).hexdigest()


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def read_package(blob):
    require(len(blob) >= 256 and blob[:8] == b'AIPKG3\0\0', 'unified package magic')
    h = list(struct.unpack_from('<64I', blob))
    require(h[2:7] == [3, 256, 1, 2, 5] and h[8] == len(blob), 'unified ResNet profile/size')
    hc = bytearray(blob[:256]); hc[56:60] = bytes(4)
    require(zlib.crc32(hc) & 0xffffffff == h[14], 'package header CRC')
    require(zlib.crc32(blob[256:]) & 0xffffffff == h[16], 'package body CRC')
    directory = blob[256:256 + 64 * h[6]]
    require(zlib.crc32(directory) & 0xffffffff == h[7], 'package directory CRC')
    sections, spans = {}, []
    for pos in range(0, len(directory), 64):
        name, offset, length, crc, alignment = struct.unpack_from('<16sQQII', directory, pos)
        name = name.rstrip(b'\0').decode('ascii')
        require(name not in sections and alignment == 4096 and offset % 4096 == 0 and
                offset >= 4096 and offset + length <= len(blob), 'package section range')
        require(all(offset + length <= a or b <= offset for a, b in spans), 'package section overlap')
        data = blob[offset:offset + length]
        require(zlib.crc32(data) & 0xffffffff == crc, 'package section CRC')
        sections[name] = data; spans.append((offset, offset + length))
    require(set(sections) == {'META', 'TENSORS', 'INSTRUCTIONS', 'ATTRIBUTES', 'CONSTANTS'}, 'package sections')
    return h, sections


def read_plan(blob, package_header):
    require(len(blob) >= 256 and blob[:8] == b'NPUPLN1\0', 'plan magic')
    h = list(struct.unpack_from('<64I', blob))
    require(h[2:9] == [1, 256, 1, 2, 512, 48, 48] and h[13] == len(blob), '48-op ResNet plan')
    require(h[14] == package_header[16] and h[15] == package_header[8], 'plan/package identity')
    hc = bytearray(blob[:256]); hc[68:72] = bytes(4)
    require(zlib.crc32(hc) & 0xffffffff == h[17] and
            zlib.crc32(blob[256:]) & 0xffffffff == h[16], 'plan CRC')
    require(h[9] == 4096 and h[10] == 48 * 8 and h[12] == 48 * 512 and
            h[11] >= h[9] + h[10] and h[11] + h[12] <= len(blob) and
            not any(h[32:]), 'plan ranges/features')
    require(all(struct.unpack_from('<II', blob, h[9] + i * 8) == (i, 1) for i in range(48)), 'one record per instruction')
    records = [list(struct.unpack_from('<128I', blob, h[11] + i * 512)) for i in range(48)]
    return h, records


def power_of_two(shift):
    return Fraction(1 << shift, 1) if shift >= 0 else Fraction(1, 1 << -shift)


def rne_fraction(value):
    negative = value < 0
    q, r = divmod(abs(value.numerator), value.denominator)
    if 2 * r > value.denominator or (2 * r == value.denominator and q & 1):
        q += 1
    return -q if negative else q


def resize_gap_gain(multiplier, shift, old_area, new_area):
    # The original gain includes the old average-pool area. Retain the
    # original scale ratio while replacing SUM(oldArea) by SUM(newArea).
    target = Fraction(multiplier * old_area, new_area) / power_of_two(shift)
    if target == 0:
        return 0, 0, target, Fraction(0)
    best = None
    for candidate_shift in range(-128, 128):
        candidate = rne_fraction(target * power_of_two(candidate_shift))
        candidate = min((1 << 31) - 1, max(-(1 << 31), candidate))
        realized = Fraction(candidate, 1) / power_of_two(candidate_shift)
        error = abs(realized - target)
        # Exact rational comparison, no float/log2 approximation. Among
        # equally accurate encodings retain the finest binary denominator.
        key = (error, -candidate_shift)
        if best is None or key < best[0]:
            best = (key, candidate, candidate_shift, realized)
    return best[1], best[2], target, best[3]


def spatial_output(length, kernel, stride, padding, dilation=1):
    require(length > 0 and kernel > 0 and stride in (1, 2) and dilation == 1, 'supported spatial geometry')
    result = (length + 2 * padding - dilation * (kernel - 1) - 1) // stride + 1
    require(result > 0, 'nonempty spatial output')
    return result


def nearest_quantized_input(data, old_shape, new_shape):
    require(old_shape[:2] == new_shape[:2] and len(old_shape) == len(new_shape) == 4, 'diagnostic input NCHW')
    n, c, ih, iw = old_shape; _, _, oh, ow = new_shape
    require(len(data) == math.prod(old_shape), 'diagnostic input extent')
    result = bytearray(math.prod(new_shape))
    for plane in range(n * c):
        for y in range(oh):
            for x in range(ow):
                result[(plane * oh + y) * ow + x] = data[(plane * ih + y * ih // oh) * iw + x * iw // ow]
    return bytes(result)


def build(model_dir: Path, output: Path, size: int):
    model_dir, output = model_dir.resolve(), output.resolve()
    require(size in (128, 160), 'supported input size is 128 or 160')
    require(output != model_dir and model_dir not in output.parents, 'derived output must be outside immutable source directory')
    require(not output.exists() or output.is_dir() and not any(output.iterdir()), 'derived output must be new or empty')
    names = ('model.aipkg', 'execution_plan.bin', 'ddr.bin', 'execution_manifest.json', 'input.bin', 'input_manifest.json')
    frozen = {name: (model_dir / name).read_bytes() for name in names}
    fingerprints = {name: sha(data) for name, data in frozen.items()}
    old = json.loads(frozen['execution_manifest.json'])
    require(old['model_id'] == 1 and old['input_shape'] == [1, 3, 224, 224], 'immutable unified 224 source')
    require(sha(frozen['ddr.bin']) == old['ddr_sha256'], 'source bundle provenance')
    ph, sections = read_package(frozen['model.aipkg'])
    plan_header, records = read_plan(frozen['execution_plan.bin'], ph)
    require(frozen['ddr.bin'][:len(frozen['model.aipkg'])] == frozen['model.aipkg'] and
            frozen['ddr.bin'][old['plan_offset']:old['plan_offset'] + old['plan_bytes']] == frozen['execution_plan.bin'],
            'bundle/package/plan identity')
    tb, ib = sections['TENSORS'], sections['INSTRUCTIONS']
    require(len(tb) % 128 == 0 and len(ib) == 48 * 128, 'tensor/instruction schema')
    tensors = [list(struct.unpack_from('<32I', tb, p)) for p in range(0, len(tb), 128)]
    old_shapes = {}
    for tid, t in enumerate(tensors):
        require(t[0] == tid and t[1:4] == [0, 1, 0] and 0 < t[4] <= 8 and
                t[8] == math.prod(t[12:12 + t[4]]) and t[6] + t[8] <= ph[10], 'INT8 workspace tensor')
        old_shapes[tid] = list(t[12:12 + t[4]])
    input_id, output_id = ph[12:14]
    require(old_shapes[input_id] == [1, 3, 224, 224], 'source package input shape')
    shapes = {input_id: [1, 3, size, size]}
    gap_changes, counts = [], Counter()
    opcode_names = {2: 'CONV', 3: 'LINEAR', 4: 'ADD', 11: 'RELU', 19: 'MAXPOOL', 20: 'GAP'}
    for index, w in enumerate(records):
        ins = list(struct.unpack_from('<32I', ib, index * 128))
        opcode = ins[0]
        require(opcode in opcode_names and ins[1] == 0 and ins[3] == 1 and
                ins[2] == (2 if opcode == 4 else 1) and ins[12:15] == [0, 0, 0], 'ResNet instruction form')
        inputs, destination = ins[4:4 + ins[2]], ins[8]
        require(all(t in shapes for t in inputs) and destination not in shapes, 'topological single-assignment tensors')
        x, xo, yo = shapes[inputs[0]], old_shapes[inputs[0]], old_shapes[destination]
        require(w[1:4] == [index, 1, opcode] and w[4:7] == [1, 1, 1] and
                w[8] == tensors[inputs[0]][6] and w[10] == tensors[destination][6], 'plan instruction identity')
        if opcode == 2:
            require(len(x) == len(xo) == len(yo) == 4 and x[0] == 1 and w[0] == 5, 'single-image Conv')
            ic, _, _, oc, old_oh, old_ow, kh, kw, sh, sw, pt, pl, dh, dw, groups, linear = w[64:80]
            require(x[1] == xo[1] == ic and groups == 1 and linear == 0 and
                    old_oh == yo[2] == spatial_output(xo[2], kh, sh, pt, dh) and
                    old_ow == yo[3] == spatial_output(xo[3], kw, sw, pl, dw), 'symmetric Conv geometry')
            oh, ow = spatial_output(x[2], kh, sh, pt, dh), spatial_output(x[3], kw, sw, pl, dw)
            y = [1, oc, oh, ow]
            w[65:67] = x[2:4]; w[68:70] = [oh, ow]
            w[84:89] = [ic, oc, ic * kh * kw, x[2] * x[3], oh * ow]
        elif opcode == 3:
            require(w[0] == 5 and len(x) == 2 and x == xo and x[0] == 1 and
                    w[64] == x[1] and w[79] == 1, 'unchanged FC input features')
            y = [1, w[67]]
            require(y == yo, 'unchanged classifier output')
        elif opcode in (4, 11):
            require(w[0] == 1 and (opcode != 4 or shapes[inputs[1]] == x), 'elementwise branch shape')
            y = list(x); w[64:68] = [math.prod(y), 1, int(opcode == 4), 1]
        elif opcode == 19:
            require(w[0] == 6 and len(x) == 4 and x[0] == 1, 'single-image maxpool')
            _, _, old_oh, old_ow, kh, kw, sh, sw, pt, pl = w[64:74]
            require(old_oh == yo[2] == spatial_output(xo[2], kh, sh, pt) and
                    old_ow == yo[3] == spatial_output(xo[3], kw, sw, pl), 'symmetric pool geometry')
            oh, ow = spatial_output(x[2], kh, sh, pt), spatial_output(x[3], kw, sw, pl)
            y = [1, x[1], oh, ow]
            w[24:26] = [1, x[1]]; w[32:34] = [math.prod(x), x[2] * x[3]]
            w[48:50] = [math.prod(y), oh * ow]
            w[64:74] = [x[2], x[3], oh, ow, kh, kw, sh, sw, pt, pl]
        else:
            require(w[0] == 2 and len(x) == 4 and x[0] == 1 and yo == [1, x[1]], 'GAP-to-FC boundary')
            old_area, new_area = xo[2] * xo[3], x[2] * x[3]
            old_multiplier, old_shift = signed(w[17], 32), signed(w[19] & 255, 8)
            multiplier, shift, target_gain, realized_gain = resize_gap_gain(old_multiplier, old_shift, old_area, new_area)
            y = [1, x[1]]
            w[24:26] = [1, x[1]]; w[32:34] = [math.prod(x), new_area]; w[48:50] = [x[1], 1]
            w[64:68] = [new_area, 1, 0, 1]; w[17] = multiplier & 0xffffffff; w[19] = shift & 255
            gap_changes.append(dict(operation=index, old_area=old_area, new_area=new_area,
                                    old_multiplier=old_multiplier, old_shift=old_shift,
                                    multiplier=multiplier, shift=shift,
                                    target_gain=str(target_gain), realized_gain=str(realized_gain),
                                    absolute_gain_error=str(abs(target_gain - realized_gain))))
        require(len(y) <= 8 and all(d > 0 for d in y) and math.prod(y) <= tensors[destination][8], 'derived tensor fits original allocation')
        shapes[destination] = y; counts[opcode_names[opcode]] += 1
    require(len(shapes) == len(tensors) and len(gap_changes) == 1, 'all tensors propagated and one GAP updated')
    for tid, t in enumerate(tensors):
        shape = shapes[tid]
        t[4], t[8] = len(shape), math.prod(shape)
        t[12:20] = shape + [0] * (8 - len(shape))
    meta = json.loads(sections['META'])
    model_name = f'resnet18_unified_{size}'
    meta['program']['name'] = model_name
    meta.update(derived_from_package_sha256=sha(frozen['model.aipkg']), derived_input_size=size,
                input_quantization_preserved=True, constant_weight_bytes_preserved=True,
                frozen_quantization_preserved=False, gap_gain_derivation=gap_changes,
                accuracy_validated=False, status='source_only_unverified')
    sections['META'] = json.dumps(meta, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    sections['TENSORS'] = b''.join(struct.pack('<32I', *t) for t in tensors)
    image, new_header, offsets = assemble(sections, ph[10], input_id, output_id)
    plan = bytearray(frozen['execution_plan.bin'])
    for index, w in enumerate(records):
        struct.pack_into('<128I', plan, plan_header[11] + index * 512, *w)
    plan_header[14:16] = [new_header[16], len(image)]
    plan_header[18:20] = [offsets['CONSTANTS'], len(sections['CONSTANTS'])]
    plan_header[16] = zlib.crc32(plan[256:]) & 0xffffffff; plan_header[17] = 0
    plan[:256] = struct.pack('<64I', *plan_header)
    plan_header[17] = zlib.crc32(plan[:256]) & 0xffffffff
    plan[:256] = struct.pack('<64I', *plan_header)
    plan_offset = align(len(image)); bundle = image + bytes(plan_offset - len(image)) + bytes(plan)
    input_info = json.loads(frozen['input_manifest.json'])
    require(input_info['sha256'] == sha(frozen['input.bin']) and input_info['package_sha256'] == sha(frozen['model.aipkg']), 'source diagnostic input provenance')
    input_data = nearest_quantized_input(frozen['input.bin'], old_shapes[input_id], shapes[input_id])
    manifest = dict(old)
    manifest.update(model=model_name, source_package=str(output / 'model.aipkg'), source_sha256=sha(image),
                    source_derived_sha256=sha(image), source_body_crc32=f'0x{new_header[16]:08X}',
                    source_parent_package_sha256=sha(frozen['model.aipkg']), source_model_dir=str(model_dir),
                    source_image_bytes=len(image), plan_offset=plan_offset, plan_bytes=len(plan),
                    ddr_bytes=len(bundle), ddr_sha256=sha(bundle), records_per_opcode=dict(counts),
                    input_shape=shapes[input_id], input_bytes=len(input_data), output_shape=shapes[output_id],
                    output_bytes=math.prod(shapes[output_id]), gap_gain_derivation=gap_changes,
                    constants_sha256=sha(sections['CONSTANTS']), constant_weight_bytes_preserved=True,
                    tensor_allocation_offsets_preserved=True, accuracy_validated=False,
                    rtl_verified=False, board_verified=False, integer_reference_executed=False,
                    frozen_sources_modified=False, status='source_only_unverified',
                    diagnostic_input_kind='synthetic resized quantized diagnostic input; not Golden')
    input_info.update(name=model_name, shape=shapes[input_id], bytes=len(input_data), sha256=sha(input_data),
                      package_sha256=sha(image), source_package_sha256=sha(frozen['model.aipkg']),
                      source=str(model_dir / 'input.bin'), source_tensor_sha256=sha(frozen['input.bin']),
                      resize_method='NCHW INT8 nearest floor mapping; quantized bytes copied without requantization',
                      diagnostic_only=True, is_golden=False, accuracy_validated=False)
    config = dict(MODEL_NAME=model_name, MODEL_ID=1, DDR_SHA256=sha(bundle), INPUT_SHA256=sha(input_data),
                  DDR_BYTES=len(bundle), DDR_CRC=zlib.crc32(bundle) & 0xffffffff,
                  WORKSPACE_BYTES=manifest['workspace_bytes'], PLAN_OFFSET=plan_offset, PLAN_BYTES=len(plan),
                  INPUT_OFFSET=manifest['input_offset'], INPUT_BYTES=len(input_data), INPUT_CRC=zlib.crc32(input_data) & 0xffffffff,
                  OUTPUT_OFFSET=manifest['output_offset'], OUTPUT_BYTES=manifest['output_bytes'], OUTPUT_DTYPE=1)
    require(all(sha((model_dir / name).read_bytes()) == digest for name, digest in fingerprints.items()), 'immutable source changed while preparing output')
    output.mkdir(parents=True, exist_ok=True)
    for name, data in (('model.aipkg', image), ('execution_plan.bin', bytes(plan)), ('ddr.bin', bundle), ('input.bin', input_data)):
        (output / name).write_bytes(data)
    for name, data in (('execution_manifest.json', manifest), ('input_manifest.json', input_info)):
        (output / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (output / 'model_config.tcl').write_text(''.join(f'set ::NPUG_{k} {v}\n' for k, v in config.items()), encoding='ascii')
    (output / 'model_config.h').write_text('#pragma once\n' + ''.join(f'#define RESNET18_UNIFIED_{k} {v}u\n' for k, v in config.items() if isinstance(v, int)), encoding='ascii')
    for name in ('load_graph.tcl', 'read_graph_result.tcl'):
        if (model_dir / name).is_file():
            shutil.copyfile(model_dir / name, output / name)
    (output / 'README.md').write_text(
        f'# {model_name}\n\nDerived offline from `{model_dir}`. Input is {size} x {size}; weights and all CONSTANTS bytes are preserved. '
        'Tensor allocation offsets and workspace capacity are preserved. Spatial plan geometry and the GAP SUM gain change.\n\n'
        'The input.bin is a synthetic nearest-neighbor resize of the frozen INT8 diagnostic input. It is not a Golden, camera preprocessing reference, '
        'classification accuracy result, or proof of numerical equivalence. Accuracy, RTL, timing, resources and board operation are unverified.\n', encoding='utf-8')
    require(all(sha((model_dir / name).read_bytes()) == digest for name, digest in fingerprints.items()), 'immutable source changed during publication')
    return manifest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model-dir', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--size', type=int, choices=(128, 160), required=True)
    args = p.parse_args()
    manifest = build(args.model_dir, args.output, args.size)
    print(json.dumps(dict(output=str(args.output.resolve()), model=manifest['model'],
                          input_shape=manifest['input_shape'], gap_gain_derivation=manifest['gap_gain_derivation'],
                          executed_model=False, accuracy_validated=False, status='source_only_unverified')))


if __name__ == '__main__':
    main()
