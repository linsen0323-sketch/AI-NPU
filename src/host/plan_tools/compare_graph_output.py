"""Exact comparison of a little-endian RTL/board output dump to frozen Golden.

No tolerances, dequantization, NMS or class-only comparison. A zero exit code
means this supplied dump matches; it does not certify the complete hardware.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zlib
import numpy as np

DT = {1: np.dtype('i1'), 2: np.dtype('<i2'), 3: np.dtype('<i4'), 4: np.dtype('<i8')}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def compare(model_dir, dump, golden_dir=None, metadata=None, frame=None, generation=None, source='raw'):
    folder = Path(model_dir)
    golden_dir = Path(golden_dir) if golden_dir else folder/'golden_validation'
    report = json.loads((golden_dir/'validation.json').read_text(encoding='utf-8'))
    manifest = json.loads((folder/'execution_manifest.json').read_text(encoding='utf-8'))
    def need(ok, why):
        if not ok:
            raise ValueError(why)
    need(report.get('passed') is True, 'Golden/plan validation did not complete successfully')
    need(report['ddr_sha256'] == sha((folder/'ddr.bin').read_bytes()) == manifest['ddr_sha256'], 'stale Golden: DDR package changed')
    need(report['output_shape'] == manifest['output_shape'] and report['output_dtype'] == manifest['output_dtype'], 'output schema changed')
    expected_bytes = (golden_dir/'output_golden.bin').read_bytes()
    actual_bytes = Path(dump).read_bytes()
    need(sha(expected_bytes) == report['output_sha256'], 'Golden output checksum mismatch')
    need(len(expected_bytes) == len(actual_bytes) == report['output_bytes'] == manifest['output_bytes'], 'output length mismatch')
    need(metadata is not None or source != 'board', 'board comparison requires output_metadata.json')
    info = json.loads(Path(metadata).read_text(encoding='utf-8')) if metadata else None
    if info is not None:
        need(info['format'] == 'NPUPLN1_RESULT_V1', 'result metadata format')
        need(info['model_id'] == report['model_id'] and info['fault'] == 0 and info['status'] == 2, 'wrong model, unfinished or failed result')
        need(info['ddr_sha256'] == report['ddr_sha256'] and info['input_sha256'] == report['input_sha256'], 'result package/input identity differs')
        need(info['output_dtype'] == report['output_dtype'] and info['output_bytes'] == report['output_bytes'], 'result schema differs')
        need(info['output_crc32'] == zlib.crc32(actual_bytes) & 0xffffffff, 'result dump CRC mismatch')
        if frame is not None:
            need(info['frame_id'] == frame, 'unexpected frame ID')
        if generation is not None:
            need(info['model_generation'] == generation, 'unexpected model generation')
    else:
        need(frame is None and generation is None, 'identity checks require metadata')
    expected = np.frombuffer(expected_bytes, dtype=DT[report['output_dtype']])
    actual = np.frombuffer(actual_bytes, dtype=expected.dtype)
    bad = np.flatnonzero(actual != expected)
    result = dict(passed=len(bad) == 0, source=source, model=report['model'],
        elements=int(expected.size), mismatches=int(len(bad)), tolerance=0,
        identity_metadata_checked=info is not None, input_sha256=report['input_sha256'],
        expected_sha256=sha(expected_bytes), actual_sha256=sha(actual_bytes),
        scope='exact values in the supplied dump; not a full hardware certification')
    if len(bad):
        at = int(bad[0])
        result['first_mismatch'] = dict(flat_index=at,
            coordinate=[int(v) for v in np.unravel_index(at, report['output_shape'])],
            expected=int(expected[at]), actual=int(actual[at]))
        # Python integers preserve differences across the whole signed INT64 range.
        result['max_absolute_error'] = max(abs(int(actual[i])-int(expected[i])) for i in bad)
    else:
        result['max_absolute_error'] = 0
    if info:
        result.update(task_id=info['task_id'], frame_id=info['frame_id'], model_generation=info['model_generation'])
    return result


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model-dir', type=Path, required=True)
    p.add_argument('--dump', type=Path, required=True)
    p.add_argument('--golden-dir', type=Path)
    p.add_argument('--metadata', type=Path)
    p.add_argument('--frame', type=lambda x: int(x, 0))
    p.add_argument('--generation', type=lambda x: int(x, 0))
    p.add_argument('--source', choices=['raw', 'rtl', 'board'], default='raw')
    p.add_argument('--report', type=Path)
    a = p.parse_args()
    try:
        result = compare(a.model_dir, a.dump, a.golden_dir, a.metadata, a.frame, a.generation, a.source)
    except (ValueError, KeyError, OSError) as exc:
        result = dict(passed=False, error=str(exc), source=a.source)
    if a.report:
        a.report.write_text(json.dumps(result, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0 if result['passed'] else 1)
