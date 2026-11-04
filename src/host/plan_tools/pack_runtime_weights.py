"""Derive a separate WPK1 runtime image; frozen OIHW and Golden stay intact.

3x3 weights use [OC][ceil(IC/8)][9][8], exactly the existing WBUF row order.
AFF1 words120/121 hold WPK1 and padded bank stride. Plan feature bit3 gates
the format. Original constants stay byte-identical; packed copies are appended
inside an extended CONSTANTS section. No arithmetic or quantization changes.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from plan_manifest import check_image

MAGIC = 0x314b5057
FEATURE = 8
sha = lambda b: hashlib.sha256(b).hexdigest()
crc = lambda b: zlib.crc32(b) & 0xffffffff
align = lambda n, a=4096: (n + a - 1) // a * a


def model_record(folder, manifest, blob):
    inp = json.loads((folder / 'input_manifest.json').read_text())
    return dict(id=manifest['model_id'], image_bytes=len(blob), image_sha256=sha(blob),
                image_crc=crc(blob), plan_offset=manifest['plan_offset'],
                plan_bytes=manifest['plan_bytes'], workspace_bytes=manifest['workspace_bytes'],
                graph_operations=manifest['graph_operations'], input_offset=manifest['input_offset'],
                input_bytes=manifest['input_bytes'], output_offset=manifest['output_offset'],
                output_bytes=manifest['output_bytes'], output_dtype=manifest['output_dtype'],
                input_shape=inp['shape'], input_dtype=inp['dtype'],
                required_features=struct.unpack_from('<I', blob, manifest['plan_offset'] + 128)[0])


def pack_tensor(raw, ic, oc):
    groups = (ic + 7) // 8
    out = bytearray(oc * groups * 72)
    for o in range(oc):
        for c in range(ic):
            group, lane = divmod(c, 8)
            start = (o * groups + group) * 72 + lane
            out[start:start + 72:8] = raw[(o * ic + c) * 9:(o * ic + c + 1) * 9]
    # Independently reconstruct every original OIHW channel, then check all
    # padded channel lanes. This proves permutation identity, not model accuracy.
    for o in range(oc):
        for c in range(groups * 8):
            group, lane = divmod(c, 8)
            start = (o * groups + group) * 72 + lane
            got = bytes(out[start:start + 72:8])
            expected = raw[(o * ic + c) * 9:(o * ic + c + 1) * 9] if c < ic else bytes(9)
            assert got == expected, 'OIHW reconstruction/padding mismatch'
    return bytes(out)


def derive(source, output):
    source, output = source.resolve(), output.resolve()
    if output.exists() or source == output or source in output.parents:
        raise ValueError('A new, separate output directory is required')
    original = json.loads((source / 'execution_manifest.json').read_text())
    old = (source / 'ddr.bin').read_bytes()
    assert original['model_id'] in (1, 3), 'WPK1 targets the ResNet/YOLO convolution backend'
    assert sha(old) == original['ddr_sha256']
    check_image(old, model_record(source, original, old))
    h = list(struct.unpack_from('<64I', old))
    package = bytearray(old[:h[8]])
    assert bytes(package) == (source / 'model.aipkg').read_bytes()
    plan = bytearray(old[original['plan_offset']:])
    ph = list(struct.unpack_from('<64I', plan))
    assert ph[32] & 2 and not ph[32] & FEATURE
    directories = [struct.unpack_from('<16sQQII24s', package, 256 + i * 64) for i in range(h[6])]
    ci = next(i for i, entry in enumerate(directories) if entry[0].rstrip(b'\0') == b'CONSTANTS')
    constants_offset, old_constants_bytes = directories[ci][1:3]
    assert max(e[1] + e[2] for e in directories) == constants_offset + old_constants_bytes
    dedup, tensors, patched = {}, [], []
    for record_index in range(ph[8]):
        offset = ph[11] + record_index * 512
        w = list(struct.unpack_from('<128I', plan, offset))
        assert not any(w[120:]), 'Reserved AFF1 extension words are occupied'
        if w[0] != 5 or w[70:72] != [3, 3]:
            continue
        ic, oc = w[64], w[67]
        raw_offset = w[11] & 0x7fffffff
        assert w[11] & 0x80000000 and raw_offset + oc * ic * 9 <= old_constants_bytes
        key = (raw_offset, ic, oc)
        if key not in dedup:
            raw = old[constants_offset + raw_offset:constants_offset + raw_offset + oc * ic * 9]
            packed = pack_tensor(raw, ic, oc)
            package.extend(bytes(align(len(package), 64) - len(package)))
            new_offset = len(package) - constants_offset
            package.extend(packed)
            dedup[key] = new_offset
            tensors.append(dict(original_constant_offset=raw_offset, packed_constant_offset=new_offset,
                                ic=ic, oc=oc, original_bytes=len(raw), packed_bytes=len(packed),
                                bank_stride=((ic + 7) // 8) * 72,
                                original_sha256=sha(raw), packed_sha256=sha(packed)))
        old_words = list(w)
        w[11], w[120], w[121] = 0x80000000 | dedup[key], MAGIC, ((ic + 7) // 8) * 72
        assert all(a == b for i, (a, b) in enumerate(zip(w, old_words)) if i not in (11, 120, 121))
        struct.pack_into('<128I', plan, offset, *w)
        patched.append(dict(record=record_index, original_op=w[1], bank_stride=w[121], packed_pointer=w[11]))
    assert patched
    package.extend(bytes(align(len(package)) - len(package)))
    h[8] = len(package)
    new_constants_bytes = len(package) - constants_offset
    struct.pack_into('<Q', package, 256 + ci * 64 + 24, new_constants_bytes)
    struct.pack_into('<I', package, 256 + ci * 64 + 32, crc(package[constants_offset:]))
    # Update the checked NPUPRE1 section descriptor before binding body CRCs.
    q = list(struct.unpack_from('<32I', package, 0x400))
    assert struct.pack('<2I', *q[:2]) == b'NPUPRE1\0'
    q[6], q[13 + ci * 2], q[31] = h[8], new_constants_bytes, 0
    struct.pack_into('<32I', package, 0x400, *q)
    q[31] = crc(package[0x400:0x480])
    struct.pack_into('<32I', package, 0x400, *q)
    h[7], h[16], h[14] = crc(package[256:256 + h[6] * 64]), crc(package[256:]), 0
    struct.pack_into('<64I', package, 0, *h)
    h[14] = crc(package[:256])
    struct.pack_into('<64I', package, 0, *h)
    assert package[constants_offset:constants_offset + old_constants_bytes] == old[constants_offset:constants_offset + old_constants_bytes]
    ph[14], ph[15], ph[19], ph[32] = h[16], h[8], new_constants_bytes, ph[32] | FEATURE
    ph[16], ph[17] = crc(plan[256:]), 0
    struct.pack_into('<64I', plan, 0, *ph)
    ph[17] = crc(plan[:256])
    struct.pack_into('<64I', plan, 0, *ph)
    blob = bytes(package) + bytes(plan)
    # ResNet slot 0x14000000 ends at NEU 0x18000000; NEU ends at the shared
    # workspace 0x1A000000. COCO uses its own checked generated configuration.
    assert len(blob) <= (0x04000000 if original['model_id'] == 1 else 0x02000000)
    updated = dict(original, source_package=str(output / 'model.aipkg'),
                   source_model_dir=str(source), source_sha256=sha(package), source_derived_sha256=sha(package),
                   source_parent_package_sha256=sha(old[:struct.unpack_from('<I', old, 32)[0]]),
                   source_body_crc32=f'0x{h[16]:08X}', source_image_bytes=len(package),
                   plan_offset=len(package), ddr_bytes=len(blob), ddr_sha256=sha(blob),
                   plan_feature_bits=ph[32], required_features=original.get('required_features', []) + ['packed_3x3_weights_v1'],
                   packed_weights=dict(format='WPK1', order='OC,Cin_group,kernel,Cin_lane',
                                       layout_marker_word=120, bank_stride_word=121, plan_feature_bit=3,
                                       parent_ddr_sha256=sha(old), tensors=tensors, records=patched,
                                       reconstructed_OIHW_bytes=sum(t['original_bytes'] for t in tensors)),
                   status='runtime_layout_candidate', board_verified=False, rtl_verified=False,
                   accuracy_validated=False, accuracy_changed=False, frozen_sources_modified=False)
    check_image(blob, model_record(source, updated, blob))
    output.mkdir(parents=True)
    for src in source.iterdir():
        if src.is_file() and (src.suffix in ('.json', '.tcl', '.h') or src.name == 'input.bin'):
            shutil.copyfile(src, output / src.name)
    for name, data in [('model.aipkg', package), ('execution_plan.bin', plan), ('ddr.bin', blob)]:
        (output / name).write_bytes(data)
    (output / 'execution_manifest.json').write_text(json.dumps(updated, indent=2) + '\n')
    inp = json.loads((output / 'input_manifest.json').read_text())
    inp.update(package_sha256=sha(package), packed_weights_parent_package_sha256=sha(old[:struct.unpack_from('<I', old, 32)[0]]))
    (output / 'input_manifest.json').write_text(json.dumps(inp, indent=2) + '\n')
    config = dict(MODEL_NAME=original['model'], MODEL_ID=original['model_id'], DDR_SHA256=sha(blob),
                  INPUT_SHA256=sha((source / 'input.bin').read_bytes()), DDR_BYTES=len(blob), DDR_CRC=crc(blob),
                  WORKSPACE_BYTES=updated['workspace_bytes'], PLAN_OFFSET=len(package), PLAN_BYTES=len(plan),
                  INPUT_OFFSET=updated['input_offset'], INPUT_BYTES=updated['input_bytes'],
                  INPUT_CRC=crc((source / 'input.bin').read_bytes()), OUTPUT_OFFSET=updated['output_offset'],
                  OUTPUT_BYTES=updated['output_bytes'], OUTPUT_DTYPE=updated['output_dtype'], REQUIRED_FEATURES=ph[32])
    (output / 'model_config.tcl').write_text(''.join(f'set ::NPUG_{k} {v}\n' for k, v in config.items()))
    prefix = original['model'].upper()
    (output / 'model_config.h').write_text('#pragma once\n' + ''.join(f'#define {prefix}_{k} {v}u\n' for k, v in config.items() if isinstance(v, int)))
    assert (output / 'input.bin').read_bytes() == (source / 'input.bin').read_bytes()
    return dict(model=updated['model'], feature_bits=ph[32], packed_records=len(patched),
                distinct_weight_tensors=len(tensors), reconstructed_OIHW_bytes=sum(t['original_bytes'] for t in tensors),
                original_ddr_bytes=len(old), packed_ddr_bytes=len(blob), parent_sha256=sha(old), candidate_sha256=sha(blob))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(derive(args.source, args.output), indent=2))
