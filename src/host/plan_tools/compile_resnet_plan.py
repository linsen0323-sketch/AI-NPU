"""Adapt the frozen 48-op ResNet image to the shared NPUPLN1 backend.

Only deterministic package construction occurs: copy original parameters,
remove zero weight padding and reorder tile-packed INT8 weights to OIHW. No
training, quantization, model execution or Golden generation is performed.
The original AIPKG3/DDR files are read-only. Output requires new hardware with
LEGACY_R18 support and cannot run on the old ResNet or flags-zero-only loader.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import zlib

import numpy as np

from legacy_plan_abi import LEGACY_R18

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]
DEFAULT_SOURCE = PROJECT/'data/models/intermediate/resnet18_legacy/model.aipkg'
DEFAULT_LEGACY = PROJECT/'data/models/intermediate/resnet18_legacy_image'
DEFAULT_OUTPUT = PROJECT/'work/resnet18_unified'
OPCODE = {1: (5, 2), 2: (1, 11), 3: (1, 4), 4: (6, 19), 5: (2, 20), 6: (5, 3)}
OP_NAME = {1: 'CONV', 2: 'RELU', 3: 'ADD', 4: 'MAXPOOL', 5: 'GAP', 6: 'LINEAR'}


def align(value, boundary=4096):
    return (value + boundary - 1) // boundary * boundary


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parse_source(path):
    blob = path.read_bytes()
    require(len(blob) >= 256 and blob[:8] == b'AIPKG3\0\0', 'source AIPKG3 magic')
    h = list(struct.unpack_from('<64I', blob))
    require(h[2:7] == [3, 256, 1, 1, 2] and h[8] == len(blob), 'frozen ResNet source profile/size')
    header = bytearray(blob[:256]); header[56:60] = bytes(4)
    require(zlib.crc32(header) & 0xffffffff == h[14], 'source header CRC')
    require(zlib.crc32(blob[256:]) & 0xffffffff == h[16], 'source body CRC')
    directory = blob[256:384]
    require(zlib.crc32(directory) & 0xffffffff == h[7], 'source directory CRC')
    sections = {}; previous_end = 4096
    for pos in range(0, 128, 64):
        name, offset, length, crc, alignment = struct.unpack_from('<16sQQII', directory, pos)
        name = name.rstrip(b'\0').decode('ascii')
        require(name not in sections and alignment == 4096 and offset % 4096 == 0 and
                previous_end <= offset and offset + length <= len(blob), 'source section bounds')
        data = blob[offset:offset+length]
        require(zlib.crc32(data) & 0xffffffff == crc, 'source section CRC')
        sections[name] = data; previous_end = offset + length
    require(set(sections) == {'META', 'LEGACY_IMAGE'}, 'source sections')
    return blob, sections['LEGACY_IMAGE'], json.loads(sections['META'])


def assemble(sections, workspace, input_id, output_id):
    """Create a new profile-2 package; never rewrite the frozen profile-1 image."""
    offset = 4096; directory = bytearray(); parts = []; offsets = {}
    for name, data in sections.items():
        offsets[name] = offset
        directory += struct.pack('<16sQQII24s', name.encode('ascii'), offset, len(data),
                                 zlib.crc32(data) & 0xffffffff, 4096, bytes(24))
        parts.append((offset, data)); offset = align(offset + len(data))
    image = bytearray(offset); image[256:256+len(directory)] = directory
    for offset, data in parts:
        image[offset:offset+len(data)] = data
    h = [0] * 64
    h[:2] = struct.unpack('<II', b'AIPKG3\0\0')
    h[2:14] = [3, 256, 1, 2, 5, zlib.crc32(directory) & 0xffffffff,
                len(image), 0, workspace, 0, input_id, output_id]
    h[16:18] = [zlib.crc32(image[256:]) & 0xffffffff, 0xffffffff]
    image[:256] = struct.pack('<64I', *h)
    h[14] = zlib.crc32(image[:256]) & 0xffffffff
    image[:256] = struct.pack('<64I', *h)
    return bytes(image), h, offsets


def compile_model(source, legacy_dir, output):
    source = source.resolve(); legacy_dir = legacy_dir.resolve(); output = output.resolve()
    require(output != source.parent and output != legacy_dir and legacy_dir not in output.parents,
            'output must be a separate derived-model folder')
    frozen_paths = [source, legacy_dir/'ddr.bin', legacy_dir/'layout.json']
    original_hashes = {str(p): sha(p.read_bytes()) for p in frozen_paths}
    original_package, legacy, meta = parse_source(source)
    require(legacy == (legacy_dir/'ddr.bin').read_bytes(), 'AIPKG3 legacy payload differs from frozen project DDR')
    layout = json.loads((legacy_dir/'layout.json').read_text(encoding='utf-8'))
    require(layout == meta['layout'] and sha(legacy) == meta['legacy_payload_sha256'], 'legacy layout/payload provenance')
    descriptors = layout['descriptors']
    require(layout['descriptor_count'] == len(descriptors) == 48 and layout['descriptor_bytes'] == 128,
            'expected frozen 48-op descriptor schema')
    require(len(legacy) == layout['ddr_bytes'], 'legacy image size')
    for index, descriptor in enumerate(descriptors):
        require(list(struct.unpack_from('<32I', legacy, index*128)) == descriptor, 'legacy descriptor bytes')

    tensors = list(layout['tensors'].items())
    ids = {int(t['offset']): i for i, (_, t) in enumerate(tensors)}
    require(len(ids) == len(tensors), 'distinct frozen tensor addresses')
    input_offset = layout['input_offset']; output_offset = layout['output_offset']
    require(input_offset in ids and output_offset in ids, 'input/output tensor addresses')
    tensor_end = max(int(t['offset']) + int(t['bytes']) for _, t in tensors)
    scratch_offset = align(tensor_end)
    scratch_bytes = max((d[7]*d[8]*32*8 for d in descriptors
                         if d[0] in (1, 6) and d[6]*d[10]*d[11] > 1024), default=0)
    workspace = align(scratch_offset + scratch_bytes)
    constants = bytearray(); records = []; instructions = bytearray(); audit = []

    def parameter(data):
        constants.extend(bytes(align(len(constants), 64)-len(constants)))
        offset = len(constants); constants.extend(data)
        require(offset + len(data) < 2**31, 'constant tagged pointer range')
        return 0x80000000 | offset

    for index, d in enumerate(descriptors):
        oldop, inp, inp2, dst, ih, iw, ic, oh, ow, oc, kh, kw, sh, sw, pt, pl = d[:16]
        require(oldop in OPCODE and inp in ids and dst in ids and (oldop != 3 or inp2 in ids), 'legacy operand addresses')
        engine, opcode = OPCODE[oldop]
        require(d[27] == oh*ow*oc, 'legacy output count')
        w = [0]*128
        w[:11] = [engine, index, LEGACY_R18, opcode, 1, 1, 1, 0, inp, inp2 if oldop == 3 else inp, dst]
        # Unused pointers remain zero offsets within the workspace. Iterator
        # resolves words 8..16; only conv word17 is a scratch pointer.
        if oldop in (1, 6):
            blocks_o, blocks_i = (oc+15)//16, (ic+7)//8
            size = blocks_o*blocks_i*kh*kw*128
            require(d[16] + size <= len(legacy), 'legacy packed weight range')
            packed = np.frombuffer(legacy, np.int8, count=size, offset=d[16]).reshape(blocks_o, blocks_i, kh, kw, 16, 8)
            padded = packed.transpose(0, 4, 1, 5, 2, 3).reshape(blocks_o*16, blocks_i*8, kh, kw)
            require(not np.any(padded[oc:]) and not np.any(padded[:, ic:]), 'frozen padded lanes must be zero')
            canonical = np.ascontiguousarray(padded[:oc, :ic]).tobytes()
            w[11] = parameter(canonical)
            for field in (17, 18, 19):
                require(d[field] % 4 == 0 and d[field] + oc*4 <= len(legacy), 'frozen per-channel parameter bounds')
                w[field-5] = parameter(legacy[d[field]:d[field]+oc*4])
            full_k = ic*kh*kw
            w[17] = scratch_offset if full_k > 1024 else 0
            w[20] = 8
            w[64:80] = [ic, ih, iw, oc, oh, ow, kh, kw, sh, sw, pt, pl, 1, 1, 1, int(oldop == 6)]
            w[80:83] = [3, 3, 3]
            w[84:89] = [ic, oc, full_k, ih*iw, oh*ow]
            audit.append(dict(index=index, opcode=OP_NAME[oldop], original_weight_offset=d[16],
                              original_weight_bytes=size, canonical_weight_pointer=w[11],
                              canonical_weight_bytes=len(canonical), canonical_weight_sha256=sha(canonical)))
        elif oldop == 4:
            w[7] = 2; w[24:26] = [1, ic]; w[32:34] = [ic*ih*iw, ih*iw]
            w[48:50] = [oc*oh*ow, oh*ow]
            w[64:74] = [ih, iw, oh, ow, kh, kw, sh, sw, pt, pl]
        elif oldop == 5:
            w[7] = 2; w[24:26] = [1, ic]; w[32:34] = [ic*ih*iw, ih*iw]
            w[48:50] = [oc*oh*ow, oh*ow]
            w[17] = d[25]; w[19] = d[26] & 0xff
            w[64:68] = [ih*iw, 1, 0, 1]
        else:
            w[64:68] = [d[27], 1, 1 if oldop == 3 else 0, 1]
            if oldop == 3:
                w[17:20] = [d[20], d[21], d[24] & 0xff]
                w[21:23] = [d[22], d[23]]
        records.append(struct.pack('<128I', *w))
        ins = [opcode, 0, 2 if oldop == 3 else 1, 1,
               ids[inp], ids[inp2] if oldop == 3 else 0xffffffff, 0xffffffff, 0xffffffff,
               ids[dst], 0xffffffff, 0xffffffff, 0xffffffff, 0, 0, 0] + [0]*17
        instructions += struct.pack('<32I', *ins)

    # ResNet never executes a LUT opcode. A shared zero descriptor nevertheless
    # satisfies the existing generic configuration port's nonempty table rule.
    unused_lut = parameter(bytes(8193*4)) & 0x7fffffff
    tensor_bytes = bytearray()
    for i, (_, tensor) in enumerate(tensors):
        shape = tensor['shape']; require(tensor['dtype'] == 'int8' and len(shape) <= 8, 'frozen tensor type/rank')
        w = [i, 0, 1, 0, len(shape), 0, tensor['offset'], 0, tensor['bytes'], 0, 0, 47,
             *shape, *([0]*(8-len(shape))), 64] + [0]*11
        tensor_bytes += struct.pack('<32I', *w)
    package_meta = dict(format='AIPKG3_R18_UNIFIED', program=dict(name='resnet18_unified'),
        tensor_ids={name: i for i, (name, _) in enumerate(tensors)},
        execution_contract='NPUPLN1 record flag bit0 LEGACY_R18; compiled plan is mandatory',
        source_package=str(source), source_package_sha256=sha(original_package),
        source_legacy_sha256=sha(legacy), source_layout_sha256=original_hashes[str(legacy_dir/'layout.json')],
        original_weight_layout=layout['weight_layout'], constant_weight_layout='OIHW, no padded channels',
        frozen_quantization_preserved=True, inactive_lut_is_zero=True,
        source_input_quantization=layout.get('input_quantization'), class_map=layout.get('class_map'))
    sections = dict(META=json.dumps(package_meta, ensure_ascii=False, separators=(',', ':')).encode('utf-8'),
                    TENSORS=bytes(tensor_bytes), INSTRUCTIONS=bytes(instructions), ATTRIBUTES=bytes(16), CONSTANTS=bytes(constants))
    image, source_header, section_offsets = assemble(sections, workspace, ids[input_offset], ids[output_offset])
    index_table = b''.join(struct.pack('<II', i, 1) for i in range(48))
    record_offset = align(4096+len(index_table)); plan_bytes = align(record_offset+48*512)
    plan = bytearray(plan_bytes); plan[4096:4096+len(index_table)] = index_table
    plan[record_offset:record_offset+48*512] = b''.join(records)
    h = [0]*64; h[:2] = struct.unpack('<II', b'NPUPLN1\0')
    h[2:16] = [1, 256, 1, 2, 512, 48, 48, 4096, len(index_table), record_offset, 48*512,
                plan_bytes, source_header[16], len(image)]
    h[16] = zlib.crc32(plan[256:]) & 0xffffffff
    h[18:20] = [section_offsets['CONSTANTS'], len(constants)]
    h[20:29] = [unused_lut, 8193, 3, unused_lut, 8193, 3, unused_lut, 4097, 3]
    h[29:32] = [ids[input_offset], ids[output_offset], workspace]
    plan[:256] = struct.pack('<64I', *h); h[17] = zlib.crc32(plan[:256]) & 0xffffffff
    plan[:256] = struct.pack('<64I', *h)
    plan_offset = align(len(image)); bundle = image + bytes(plan_offset-len(image)) + plan
    example = source.parent/'input_example'
    input_data = (example/'input.bin').read_bytes()
    input_info = json.loads((example/'input_manifest.json').read_text(encoding='utf-8'))
    input_bytes = int(tensors[ids[input_offset]][1]['bytes']); output_bytes = int(tensors[ids[output_offset]][1]['bytes'])
    require(input_info['package_sha256'] == sha(original_package) and input_info['sha256'] == sha(input_data)
            and len(input_data) == input_bytes and input_info['offset'] == input_offset, 'frozen input provenance')
    manifest = dict(format='NPUPLN1', model='resnet18_unified', model_id=1, profile=2,
        source_package=str(source), source_sha256=sha(original_package), source_body_crc32=f'0x{source_header[16]:08X}',
        source_legacy_sha256=sha(legacy), source_image_bytes=len(image), source_derived_sha256=sha(image),
        plan_offset=plan_offset, plan_bytes=plan_bytes, ddr_bytes=len(bundle), ddr_sha256=sha(bundle),
        graph_operations=48, plan_records=48, records_per_opcode=dict(Counter(OP_NAME[d[0]] for d in descriptors)),
        legacy_record_flag=LEGACY_R18, workspace_bytes=workspace, original_workspace_bytes=scratch_offset,
        conv_scratch_offset=scratch_offset, conv_scratch_bytes=scratch_bytes,
        input_tensor_id=ids[input_offset], input_offset=input_offset, input_bytes=input_bytes,
        input_shape=tensors[ids[input_offset]][1]['shape'], input_dtype=1,
        output_tensor_id=ids[output_offset], output_offset=output_offset, output_bytes=output_bytes,
        output_shape=tensors[ids[output_offset]][1]['shape'], output_dtype=1,
        rtl_verified=False, board_verified=False, integer_reference_executed=False,
        compatible_with_legacy_loader=False, frozen_sources_modified=False)
    configs = dict(MODEL_NAME='resnet18_unified', MODEL_ID=1, DDR_SHA256=sha(bundle), INPUT_SHA256=sha(input_data),
        DDR_BYTES=len(bundle), DDR_CRC=zlib.crc32(bundle)&0xffffffff, WORKSPACE_BYTES=workspace,
        PLAN_OFFSET=plan_offset, PLAN_BYTES=plan_bytes, INPUT_OFFSET=input_offset, INPUT_BYTES=input_bytes,
        INPUT_CRC=zlib.crc32(input_data)&0xffffffff, OUTPUT_OFFSET=output_offset, OUTPUT_BYTES=output_bytes, OUTPUT_DTYPE=1)
    # Publication is last, after all bounds/provenance checks. Output artifacts
    # are derived data; no protected source or previously accepted Golden is touched.
    output.mkdir(parents=True, exist_ok=True)
    for filename, data in (('ddr.bin', bundle), ('model.aipkg', image), ('execution_plan.bin', plan), ('input.bin', input_data)):
        (output/filename).write_bytes(data)
    for filename, data in (('execution_manifest.json', manifest), ('weight_relayout_manifest.json', audit)):
        (output/filename).write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    input_info = dict(input_info, package_sha256=sha(image), source_package_sha256=sha(original_package))
    (output/'input_manifest.json').write_text(json.dumps(input_info, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    (output/'model_config.tcl').write_text(''.join(f'set ::NPUG_{k} {v}\n' for k, v in configs.items()), encoding='utf-8')
    (output/'model_config.h').write_text('#pragma once\n'+''.join(f'#define RESNET18_UNIFIED_{k} {v}u\n'
        for k, v in configs.items() if isinstance(v, int)), encoding='utf-8')
    for filename in ('load_graph.tcl', 'read_graph_result.tcl'):
        (output/filename).write_bytes((HERE/filename).read_bytes())
    require(all(sha(Path(p).read_bytes()) == digest for p, digest in original_hashes.items()), 'frozen source changed during compilation')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--legacy-dir', type=Path, default=DEFAULT_LEGACY)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    print(json.dumps(compile_model(args.source, args.legacy_dir, args.output), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
