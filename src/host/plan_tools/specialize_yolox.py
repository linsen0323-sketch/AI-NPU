"""Specialize the frozen integer YOLOX graph to 320, without training.

Writes a separate yolox_s_a_320 package/plan; never overwrites the 640 release.
Weights, biases, multipliers, shifts and LUTs are copied exactly. Only tensor
geometry, reshape/resize attributes, decode grids and strides are specialized.
No Vivado, simulator, synthesis, ELF build or hardware access is performed.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[3]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def decode_constants(size):
    grids, strides = [], []
    for stride in (8, 16, 32):
        y, x = np.meshgrid(np.arange(size // stride), np.arange(size // stride), indexing='ij')
        grids.append(np.stack((x, y), -1).reshape(1, -1, 2))
        strides.append(np.full((1, (size // stride) ** 2, 1), stride))
    return (np.concatenate(grids, 1) * 65536).astype('<i4'), \
        (np.concatenate(strides, 1) * 65536).astype('<i4')


def specialize(original, original_parameters, size):
    program = copy.deepcopy(original)
    parameters = {k: v.copy() for k, v in original_parameters.items()}
    grid, stride = decode_constants(size)
    old_grid, old_stride = decode_constants(640)
    replacements = {'p0332_constant': (old_grid, grid),
                    'p0333_constant': (old_stride, stride),
                    'p0334_constant': (old_stride, stride)}
    for name, (expected, replacement) in replacements.items():
        require(name in parameters and np.array_equal(parameters[name], expected),
                f'unexpected frozen decode constant: {name}')
        parameters[name] = replacement.copy()
        program['tensors'][name]['shape'] = list(replacement.shape)
    shapes = {k: list(v.shape) for k, v in parameters.items()}
    shapes[program['input']] = [1, 3, size, size]
    program['tensors'][program['input']]['shape'] = shapes[program['input']]
    for operator in program['operators']:
        op, a = operator['op'], operator['attrs']
        ins = [shapes[k] for k in operator['inputs']]
        x = ins[0]
        if op in ('QUANT', 'SIGMOID', 'EXP', 'RELU'):
            outputs = [x.copy()]
        elif op == 'CONV':
            weight = parameters[a['weight']]
            sy, sx = a['strides']; pt, pl, pb, pr = a['pads']; dy, dx = a['dilations']
            require(x[1] == weight.shape[1] * a['group'], 'conv channels')
            outputs = [[x[0], weight.shape[0],
                        (x[2]+pt+pb-dy*(weight.shape[2]-1)-1)//sy+1,
                        (x[3]+pl+pr-dx*(weight.shape[3]-1)-1)//sx+1]]
        elif op in ('ADD', 'MUL'):
            outputs = [list(np.broadcast_shapes(*ins))]
        elif op == 'SLICE':
            y = x.copy()
            for axis, begin, end, step in zip(a['axes'], a['starts'], a['ends'], a['steps']):
                axis %= len(x)
                y[axis] = len(range(*slice(begin, end, step).indices(x[axis])))
            outputs = [y]
        elif op == 'CONCAT':
            axis = a['axis'] % len(x)
            require(all(len(s) == len(x) and all(s[j] == x[j] for j in range(len(x)) if j != axis)
                        for s in ins), 'concat dimensions')
            y = x.copy(); y[axis] = sum(s[axis] for s in ins); outputs = [y]
        elif op == 'MAXPOOL':
            sy, sx = a['strides']; pt, pl, pb, pr = a['pads']; ky, kx = a['kernel']
            outputs = [[x[0], x[1], (x[2]+pt+pb-ky)//sy+1, (x[3]+pl+pr-kx)//sx+1]]
        elif op == 'RESIZE_NEAREST':
            old_x = original['tensors'][operator['inputs'][0]]['shape']
            old_y = original['tensors'][operator['outputs'][0]]['shape']
            require(old_y[:2] == old_x[:2] and all(old_y[j] == old_x[j]*2 for j in (2, 3)),
                    'only the two frozen nearest 2x upsampling nodes are supported')
            outputs = [[x[0], x[1], x[2]*2, x[3]*2]]; a['shape'] = outputs[0]
        elif op == 'RESHAPE':
            require(len(x) == 4 and len(a['shape']) == 3 and a['shape'][:2] == x[:2],
                    'only frozen detector head spatial flatten is supported')
            outputs = [[x[0], x[1], math.prod(x[2:])]]; a['shape'] = outputs[0]
        elif op == 'TRANSPOSE':
            outputs = [[x[j] for j in a['perm']]]
        else:
            raise ValueError(f'unsupported specialization: {op}')
        require(len(outputs) == len(operator['outputs']), 'output count')
        for name, shape in zip(operator['outputs'], outputs):
            require(all(int(d) > 0 for d in shape), f'invalid tensor shape: {name}')
            shapes[name] = [int(d) for d in shape]
            program['tensors'][name]['shape'] = shapes[name]
    program['input_shape'] = shapes[program['input']]
    program['output_shape'] = shapes[program['output']]
    require(program['output_shape'] == [1, sum((size//s)**2 for s in (8,16,32)), 11], 'output contract')
    program['preprocessing']['size'] = [size, size]
    return program, parameters


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-root', type=Path, default=ROOT/'src/host/compiler')
    parser.add_argument('--output', type=Path, default=ROOT/'work/neu6_256')
    parser.add_argument('--size', type=int, choices=(192,224,256,320,416,640), default=320)
    parser.add_argument('--fuse-silu', action='store_true')
    parser.add_argument('--source', type=Path, default=ROOT/'data/models/intermediate/neu6_integer/model.aipkg')
    parser.add_argument('--image', type=Path, default=ROOT/'data/samples/neu6/scratches_105.jpg')
    args = parser.parse_args()
    sys.path.insert(0, str(args.host_root.resolve()))
    from package import load_program, encode_graph, assemble, parse
    from compile_graph_plan import Graph
    import cv2

    source = args.source
    source_blob = source.read_bytes()
    original, parameters, _ = load_program(source)
    require(original['input_shape'] == [1,3,640,640], 'source must be frozen 640 model')
    # Source-only identity gate: the same shape rules must reconstruct 640
    # exactly before they are allowed to specialize any geometry.
    unchanged, same_parameters = specialize(original, parameters, 640)
    require(unchanged == original and all(np.array_equal(v, same_parameters[k]) for k,v in parameters.items()),
            '640 identity reconstruction failed')
    size=args.size
    program, new_parameters = specialize(original, parameters, size)
    program['name'] = f'yolox_s_a_{size}'
    sections, _, iid, oid, workspace = encode_graph(program, new_parameters)
    package = assemble(3, 2, sections, workspace, iid, oid)
    parse(package)
    out = args.output.resolve()
    require(out != source.parent.resolve() and out != (ROOT/'data/models/yolox_s_a').resolve(), 'preserve 640 release')
    require(not out.exists() or not any(out.iterdir()), 'output must be new or empty; preserve existing packages')
    out.mkdir(parents=True, exist_ok=True)
    (out/'model.aipkg').write_bytes(package)
    (out/'program.json').write_text(json.dumps(program, indent=2)+'\n', encoding='utf-8')
    info = json.loads((source.parent/'input_example/input_manifest.json').read_text('utf-8'))
    image = cv2.imread(str(args.image), cv2.IMREAD_COLOR)
    require(image is not None, f'cannot read source example image: {info["source"]}')
    height, width = image.shape[:2]; ratio = min(size/height, size/width)
    resized = cv2.resize(image, (int(width*ratio), int(height*ratio)), interpolation=cv2.INTER_LINEAR)
    pixels = np.full((size,size,3), 114, np.uint8)
    pixels[:resized.shape[0], :resized.shape[1]] = resized
    fixed = (pixels.transpose(2,0,1).astype('<i4')[None] << 16)
    data = fixed.tobytes(); example = out/'input_example'; example.mkdir(exist_ok=True)
    graph = Graph(out/'model.aipkg')
    input_info = dict(name=program['name'], shape=[1,3,size,size], dtype='int32', fractional_bits=16,
                      offset=graph.tensors[iid].offset, source=info['source'], original_hw=[height,width],
                      letterbox_ratio=ratio, letterbox_pad_xy=[0,0], bytes=len(data), sha256=digest(data),
                      package_sha256=digest(package))
    (example/'input.bin').write_bytes(data)
    (example/'input_manifest.json').write_text(json.dumps(input_info,indent=2)+'\n',encoding='utf-8')
    command=[sys.executable,str(Path(__file__).resolve().parent/'compile_graph_plan.py'),'--model',str(out/'model.aipkg'),'--output',str(out)]
    if args.fuse_silu:command.append('--fuse-silu')
    subprocess.run(command,check=True)
    changed = [k for k,v in parameters.items() if not np.array_equal(v,new_parameters[k])]
    require(set(changed) == {'p0332_constant','p0333_constant','p0334_constant'}, 'unexpected parameter change')
    require(source.read_bytes() == source_blob, 'source package changed')
    report = dict(source_package=str(source), source_sha256=digest(source_blob),
                  package_sha256=digest(package), changed_parameters=changed,
                  unchanged_parameter_count=len(parameters)-len(changed), input_shape=[1,3,size,size],
                  output_shape=program['output_shape'], identity_640_reconstructed=True,
                  training_performed=False, accuracy_validated=False, golden_validated=False,
                  rtl_simulated=False, synthesized=False, board_verified=False)
    (out/'specialization_manifest.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
