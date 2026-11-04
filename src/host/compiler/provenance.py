"""Content-addressed evidence for the offline release; never trusts timestamps."""
import hashlib
import importlib.metadata
import json
import platform
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
TOOLS = REPO/"src/host/quantization/neu6"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def hashes(paths):
    return {str(p.resolve()): digest(p) for p in sorted(set(map(Path, paths)))}


def sources():
    paths = list(ROOT.glob('*.py')) + [ROOT/'abi.md', ROOT/'aipkg3_abi.h']
    paths += list(TOOLS.glob('*.py'))
    paths += [REPO/'data/reference/resnet18/verify_full_resnet18_int8.py']
    return hashes(paths)


def environment():
    result = {'python': platform.python_version(), 'platform': platform.platform()}
    for name in ['numpy', 'torch', 'torchvision', 'onnx', 'Pillow',
                 'opencv-python', 'timm', 'pycocotools']:
        try:
            result[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            result[name] = 'not installed'
    return result


def write_report(path, result, inputs=()):
    from compiler import jsdump
    result = dict(result)
    result['evidence'] = {
        'schema': 'HOST_V1_EVIDENCE1',
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'sources': sources(), 'inputs': hashes(inputs), 'environment': environment(),
    }
    jsdump(path, result)
    return result


def verify_report(path, required=()):
    report = json.loads(Path(path).read_text(encoding='utf-8'))
    ev = report.get('evidence', {})
    if ev.get('schema') != 'HOST_V1_EVIDENCE1' or ev.get('sources') != sources():
        raise ValueError(f'Stale or missing source evidence: {path}')
    for name, expected in ev['inputs'].items():
        if digest(name) != expected:
            raise ValueError(f'Evidence input changed: {name}')
    for item in required:
        key = str(Path(item).resolve())
        if key not in ev['inputs']:
            raise ValueError(f'Report does not bind required input: {item}')
    return report
