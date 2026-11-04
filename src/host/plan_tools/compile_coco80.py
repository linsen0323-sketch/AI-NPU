"""Compile an independently named COCO80 candidate with the existing ABI3 compiler.

Never installs a model or changes a production catalog. Capability checks precede
integer lowering; numerical and RTL acceptance are separate mandatory gates.
"""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import sys
import traceback
import struct
import zlib

import numpy as np
import onnx
from onnx import numpy_helper


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audit(model):
    onnx.checker.check_model(model, full_check=True)
    producers = {o: n for n in model.graph.node for o in n.output}
    consumers = defaultdict(list)
    for i, node in enumerate(model.graph.node):
        for name in node.input:
            consumers[name].append(i)
    values = {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}
    for node in model.graph.node:
        if node.op_type == 'Constant':
            attr = next((a for a in node.attribute if a.name == 'value'), None)
            if attr:
                values[node.output[0]] = numpy_helper.to_array(attr.t)
        elif node.op_type == 'Identity' and node.input[0] in values:
            values[node.output[0]] = values[node.input[0]]
    unsupported = []
    quantizers = []
    for node in model.graph.node:
        if node.op_type not in ('QuantizeLinear', 'DequantizeLinear'):
            continue
        scale = values.get(node.input[1])
        zero = values.get(node.input[2]) if len(node.input) > 2 else None
        item = dict(name=node.name, op=node.op_type, shape=list(scale.shape) if scale is not None else None,
                    scale_min=float(np.min(scale)) if scale is not None else None,
                    scale_max=float(np.max(scale)) if scale is not None else None,
                    zero_dtype=str(zero.dtype) if zero is not None else None)
        quantizers.append(item)
        if scale is None or not np.all(np.isfinite(scale)) or not np.all(scale > 0):
            unsupported.append(dict(node=node.name, reason='nonconstant or nonpositive scale'))
        if zero is not None and np.any(zero != 0):
            unsupported.append(dict(node=node.name, reason='nonzero zero point is not supported'))
        if node.op_type == 'QuantizeLinear':
            if scale is None or scale.size != 1 or zero is None or zero.dtype not in (np.int8, np.int16):
                unsupported.append(dict(node=node.name, reason='activation must be scalar symmetric signed A8/A16'))
            clip = producers.get(node.input[0])
            if clip is None or clip.op_type != 'Clip':
                unsupported.append(dict(node=node.name, reason='missing checked narrow symmetric Clip'))
            elif scale is not None and zero is not None:
                maximum = np.iinfo(zero.dtype).max
                low, high = (values.get(clip.input[k]) for k in (1, 2))
                # Clip endpoints can be constant Mul nodes, checked by the lowerer below.
                item['clip_node'] = clip.name
                item['narrow_maximum'] = int(maximum)
                if low is not None and high is not None and not (
                        np.array_equal(low, -scale * maximum) and np.array_equal(high, scale * maximum)):
                    unsupported.append(dict(node=node.name, reason='Clip differs from narrow symmetric range'))
    return dict(onnx_nodes=dict(Counter(n.op_type for n in model.graph.node)), quantizers=quantizers,
                unsupported=unsupported, onnx_checker='PASS', consumer_counts=dict(consumers))


def compile_candidate(source, output, host_root):
    source, output = source.resolve(), output.resolve()
    if source == output or source in output.parents:
        raise ValueError('Candidate output must be outside immutable model directory')
    if output.exists() and any(output.iterdir()):
        raise ValueError('Candidate output must be empty')
    output.mkdir(parents=True, exist_ok=True)
    report = dict(source=str(source), model_sha256=digest((source / 'model_mixed_qdq.onnx' if (source / 'model_mixed_qdq.onnx').is_file() else Path(__file__).resolve().parents[3]/'data/models/onnx/yolox_s_coco80_qdq.onnx')),
                  status='IN_PROGRESS', integer_execution='NOT_RUN', rtl='NOT_RUN',
                  coco5000='NOT_RUN', installed=False)
    try:
        model = onnx.load((source / 'model_mixed_qdq.onnx' if (source / 'model_mixed_qdq.onnx').is_file() else Path(__file__).resolve().parents[3]/'data/models/onnx/yolox_s_coco80_qdq.onnx'))
        capabilities = audit(model)
        (output / 'onnx_capabilities.json').write_text(json.dumps(capabilities, indent=2) + '\n')
        if capabilities['unsupported']:
            raise ValueError(capabilities['unsupported'])
        sys.path.insert(0, str(host_root.resolve()))
        import compiler
        import package
        compiler.PTQ = source.parent
        compiler.ART = output / 'intermediate'
        lower = compiler.Compiler(source.name)
        program, parameters = lower.compile()
        identity_file=Path(__file__).resolve().parents[3]/'data/models/intermediate/coco80_integer/program.json'
        program['name']=json.loads(identity_file.read_text('utf-8'))['name']
        if program['input_shape'] != [1, 3, 256, 256] or program['output_shape'] != [1, 1344, 85]:
            raise ValueError('COCO80 static geometry mismatch')
        if len(program['classes']) != 80:
            raise ValueError('Expected 80 classes')
        # Check every activation Q/DQ pair after constant folding, including clips.
        for node in lower.nodes:
            if node.op_type != 'QuantizeLinear':
                continue
            clip = lower.prod[node.input[0]]
            scale = lower.const[node.input[1]]
            zero = lower.const[node.input[2]]
            maximum = np.iinfo(zero.dtype).max
            if not all(np.array_equal(lower.const[clip.input[k]], scale * sign * maximum)
                       for k, sign in ((1, -1), (2, 1))):
                raise ValueError('Folded Clip does not match signed narrow quantization: ' + node.name)
        sections, meta, iid, oid, workspace = package.encode_graph(program, parameters)
        image = package.assemble(3, 2, sections, workspace, iid, oid)
        package.parse(image)
        (output / 'model.aipkg').write_bytes(image)
        (output / 'program.json').write_text(json.dumps(program, indent=2) + '\n')
        np.savez(output / 'parameters.npz', **parameters)
        from compile_graph_plan import Graph, Lowerer, align
        from compile_conv_fused_plan import ConvFusedLowerer
        from prepare_predecoded_control import prepare_model
        from pack_runtime_weights import derive
        graph = Graph(output / 'model.aipkg')
        fused = ConvFusedLowerer(graph).lower()
        plan = fused.image()
        offset = align(len(image))
        bundle = image + bytes(offset-len(image)) + plan
        # Preserve detector hardware family ID 3. The optional PS selection 4
        # uses a separate immutable DDR slot, without replacing the NEU image.
        runtime = output / 'runtime'
        runtime.mkdir()
        (runtime / 'model.aipkg').write_bytes(image)
        (runtime / 'execution_plan.bin').write_bytes(plan)
        (runtime / 'ddr.bin').write_bytes(bundle)
        input_tensor = graph.tensors[graph.header[12]]
        output_tensor = graph.tensors[graph.header[13]]
        manifest = dict(format='NPUPLN1', model=program['name'], model_id=3,
            source_package=str(output / 'model.aipkg'), source_sha256=digest(output / 'model.aipkg'),
            source_image_bytes=len(image), ddr_bytes=len(bundle), plan_offset=offset,
            plan_bytes=len(plan), graph_operations=len(graph.ops), plan_records=len(fused.records),
            workspace_bytes=align(workspace+fused.scratch_bytes),
            original_workspace_bytes=workspace, conv_scratch_bytes=fused.scratch_bytes,
            input_offset=input_tensor.offset, input_bytes=input_tensor.nbytes,
            input_shape=input_tensor.shape, output_offset=output_tensor.offset,
            output_bytes=output_tensor.nbytes, output_shape=output_tensor.shape,
            output_dtype=output_tensor.dtype, fusion_groups=fused.fusions,
            absorbed_operations=fused.absorbed_operations, required_features=[],
            plan_feature_bits=struct.unpack_from('<I', plan, 128)[0],
            ddr_sha256=hashlib.sha256(bundle).hexdigest(),
            accuracy_validated=False, rtl_verified=False, board_verified=False)
        (runtime / 'execution_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
        sample = np.load(source / 'golden_sample_00.npz')
        fixed = np.rint(sample['images'] * 65536).astype('<i4')
        if list(fixed.shape) != input_tensor.shape or fixed.nbytes != input_tensor.nbytes:
            raise ValueError('Input example geometry mismatch')
        payload = fixed.tobytes()
        (runtime / 'input.bin').write_bytes(payload)
        (runtime / 'input_manifest.json').write_text(json.dumps(dict(
            name=program['name'], shape=input_tensor.shape, dtype='int32', fractional_bits=16,
            offset=input_tensor.offset, bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest(),
            package_sha256=digest(runtime / 'model.aipkg'), source=str(source / 'golden_sample_00.npz')
        ), indent=2)+'\n')
        prepare_model(runtime, output / 'predecoded', coalesce_inner=True)
        report['wpk1'] = derive(output / 'predecoded', output / 'wpk1')
        report.update(status='COMPILED_CANDIDATE_NOT_ACCEPTED', workspace_bytes=workspace,
                      operators=len(program['operators']),
                      precision=dict(Counter('W8A' + str(o['attrs']['activation_bits'])
                          for o in program['operators'] if o['op'] in ('CONV', 'LINEAR'))),
                      compiler_sha256=digest(host_root / 'compiler.py'),
                      package_sha256=digest(output / 'model.aipkg'))
    except Exception as error:
        report.update(status='FAIL', error=str(error), traceback=traceback.format_exc())
        (output / 'failure.txt').write_text(report['traceback'])
    finally:
        if digest((source / 'model_mixed_qdq.onnx' if (source / 'model_mixed_qdq.onnx').is_file() else Path(__file__).resolve().parents[3]/'data/models/onnx/yolox_s_coco80_qdq.onnx')) != report['model_sha256']:
            raise RuntimeError('Immutable source changed')
        (output / 'compile_report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return report['status'] != 'FAIL'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--host-root', type=Path, default=Path(__file__).resolve().parents[3]/'src/host/compiler')
    args = parser.parse_args()
    sys.exit(0 if compile_candidate(args.source, args.output, args.host_root) else 1)
