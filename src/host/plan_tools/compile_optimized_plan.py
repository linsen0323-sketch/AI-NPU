"""Compile exact SiLU/quant fusion without changing frozen AIPKG3 tensors.

This is a file compiler, not a numerical/RTL test. NPUPLN1 word32 bit0 opts
into OPT1 execution: flags 2/6 on a SIGMOID record execute x*sigmoid(x),
optionally followed by the original QUANT. Absorbed instructions have zero
records. All original integer rounding and intermediate I32 checks remain.
Only adjacent, single-consumer patterns with safe output aliasing are fused.
The production file entry point accepts only YOLOX model ID 3.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import shutil
import struct
import zlib

from compile_graph_plan import Graph, Lowerer, OP, align, require


def same_extent_or_disjoint(x, y):
    if x.const:
        return True
    return (x.offset + x.nbytes <= y.offset or y.offset + y.nbytes <= x.offset or
            (x.offset == y.offset and x.dtype == y.dtype and x.shape == y.shape))


def overlaps(x, y):
    return (x.const == y.const and x.offset < y.offset + y.nbytes and
            y.offset < x.offset + x.nbytes)


class OptimizedLowerer(Lowerer):
    def lower(self):
        super().lower()
        original_records, original_index = self.records, self.index
        self.records, self.index, self.counts = [], [], Counter()
        self.fusions, absorbed = [], set()
        consumers = defaultdict(list)
        producers = defaultdict(list)
        for i, (_, inputs, _, _) in enumerate(self.g.ops):
            for tid in inputs:
                consumers[tid].append(i)
            for tid in self.g.ops[i][2]:
                producers[tid].append(i)
        graph_output = self.g.header[13]

        def elidable(tid, first_op, last_op, internal_ids):
            # Tensor IDs alone do not prove memory liveness. The package
            # schema permits different IDs to name overlapping workspace.
            # Removing a store must not change a live alias observable by
            # another instruction or by the graph's published output.
            if tid == graph_output or len(producers[tid]) != 1:
                return False
            tensor = self.g.tensors[tid]
            for alias_id, alias in self.g.tensors.items():
                if alias_id in internal_ids or not overlaps(tensor, alias):
                    continue
                definitions = producers[alias_id]
                if len(definitions) > 1:
                    return False
                born = definitions[0] if definitions else -1
                used = consumers[alias_id]
                last_use = len(self.g.ops) if alias_id == graph_output else max(used, default=-1)
                if born <= last_op and last_use >= first_op:
                    return False
            return True
        replacements = {}
        for i, (op, inputs, outputs, _) in enumerate(self.g.ops[:-1]):
            if i in absorbed or op != 9 or len(inputs) != 1 or len(outputs) != 1:
                continue
            mulop, mulin, mulout, _ = self.g.ops[i + 1]
            if (mulop != 5 or len(mulin) != 2 or len(mulout) != 1 or
                    sorted(mulin) != sorted([inputs[0], outputs[0]]) or
                    consumers[outputs[0]] != [i + 1]):
                continue
            x, sig, mul = (self.g.tensors[t] for t in (inputs[0], outputs[0], mulout[0]))
            if x.dtype != 3 or sig.dtype != 3 or mul.dtype != 3 or x.shape != sig.shape or x.shape != mul.shape:
                continue
            # The original MUL reads x after SIGMOID has finished. If the
            # SIGMOID overwrites x, it is no longer the x*sigmoid(x) pattern.
            # Preserve the original kernels' partial-overlap rejection too.
            if (overlaps(x, sig) or not same_extent_or_disjoint(x, mul) or
                    not same_extent_or_disjoint(sig, mul) or
                    producers[outputs[0]] != [i] or producers[mulout[0]] != [i + 1] or
                    not elidable(outputs[0], i, i + 1, {outputs[0], mulout[0]})):
                continue
            target, quant, stop = mul, None, i + 1
            if i + 2 < len(self.g.ops) and consumers[mulout[0]] == [i + 2]:
                qop, qin, qout, qa = self.g.ops[i + 2]
                if qop == 1 and qin == mulout and len(qout) == 1:
                    q = self.g.tensors[qout[0]]
                    if (q.dtype in (1, 2) and q.shape == x.shape and
                            same_extent_or_disjoint(x, q) and same_extent_or_disjoint(mul, q) and
                            elidable(mulout[0], i + 1, i + 2, {outputs[0], mulout[0], qout[0]})):
                        target, quant, stop = q, qa, i + 2
            if not same_extent_or_disjoint(x, target):
                continue
            first, count = struct.unpack('<II', original_index[i])
            fused = []
            for record in original_records[first:first + count]:
                w = list(struct.unpack('<128I', record))
                require(w[0] == 1 and w[3] == 9, 'SiLU source engine')
                w[2], w[6], w[10] = (6 if quant else 2), target.dtype, target.ptr
                w[67] = target.width
                w[48:56] = target.step[:-1] + [0] * (8 - len(target.step[:-1]))
                if quant:
                    require(0 < quant['multiplier'] < 2**31 and 0 <= quant['shift'] <= 62, 'fused quantizer')
                    w[17:20] = [quant['multiplier'], 0, quant['shift']]
                fused.append(struct.pack('<128I', *w))
            replacements[i] = fused
            absorbed.update(range(i + 1, stop + 1))
            self.fusions.append(dict(first_op=i, last_op=stop, quantized=bool(quant),
                                     output_tensor=target.tid, records=count))
        for i, index in enumerate(original_index):
            first_new = len(self.records)
            if i not in absorbed:
                first, count = struct.unpack('<II', index)
                for record in replacements.get(i, original_records[first:first + count]):
                    self.records.append(record)
                    self.counts[OP[struct.unpack_from('<I', record, 12)[0]]] += 1
            self.index.append(struct.pack('<II', first_new, len(self.records) - first_new))
        self.absorbed_operations = sorted(absorbed)
        return self

    def image(self):
        result = bytearray(super().image())
        struct.pack_into('<I', result, 32 * 4, 1 if self.fusions else 0)
        struct.pack_into('<I', result, 17 * 4, 0)
        struct.pack_into('<I', result, 17 * 4, zlib.crc32(result[:256]) & 0xffffffff)
        return bytes(result)


def build(model_dir: Path, output: Path, lowerer_class=OptimizedLowerer):
    model_dir, output = model_dir.resolve(), output.resolve()
    require(model_dir != output and model_dir not in output.parents, 'write outside immutable model directory')
    require(not output.exists() or not any(output.iterdir()), 'output must be new or empty')
    old = json.loads((model_dir / 'execution_manifest.json').read_text('utf-8'))
    require(old['model_id'] == 3, 'production SiLU fusion is restricted to YOLOX model ID 3')
    blob = (model_dir / 'ddr.bin').read_bytes()
    source_bytes = struct.unpack_from('<I', blob, 8 * 4)[0]
    output.mkdir(parents=True, exist_ok=True)
    source = output / 'model.aipkg'
    source.write_bytes(blob[:source_bytes])
    graph = Graph(source)
    lower = lowerer_class(graph).lower()
    plan = lower.image()
    offset = align(len(graph.blob))
    bundle = graph.blob + bytes(offset - len(graph.blob)) + plan
    manifest = dict(old)
    manifest.update(source_package=str(source), source_sha256=hashlib.sha256(graph.blob).hexdigest(),
                    source_model_dir=str(model_dir), ddr_bytes=len(bundle), plan_offset=offset,
                    plan_bytes=len(plan), plan_records=len(lower.records),
                    records_per_opcode=dict(lower.counts), fusion_groups=lower.fusions,
                    absorbed_operations=lower.absorbed_operations,
                    required_features=([name for bit,name in ((1,'exact_silu_fusion_v1'),(4,'exact_conv_fusion_v1'))
                                        if struct.unpack_from('<I',plan,128)[0] & bit]),
                    plan_feature_bits=struct.unpack_from('<I',plan,128)[0],
                    ddr_sha256=hashlib.sha256(bundle).hexdigest(),
                    rtl_verified=False, board_verified=False, accuracy_changed=False,
                    status='source_only_unverified')
    (output / 'execution_plan.bin').write_bytes(plan)
    (output / 'ddr.bin').write_bytes(bundle)
    (output / 'execution_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    for name in ('input.bin', 'input_manifest.json', 'program.json'):
        if (model_dir / name).is_file():
            shutil.copyfile(model_dir / name, output / name)
    # Keep the existing download helpers usable for this separately named image.
    for name in ('load_graph.tcl', 'read_graph_result.tcl'):
        if (model_dir / name).is_file():
            shutil.copyfile(model_dir / name, output / name)
    config = dict(MODEL_NAME=old['model'], MODEL_ID=old['model_id'],
                  DDR_SHA256=manifest['ddr_sha256'], DDR_BYTES=len(bundle),
                  DDR_CRC=zlib.crc32(bundle) & 0xffffffff)
    for field in ('plan_offset', 'plan_bytes', 'workspace_bytes', 'input_offset',
                  'input_bytes', 'output_offset', 'output_bytes', 'output_dtype'):
        config[field.upper()] = manifest[field]
    inp = (output / 'input.bin').read_bytes()
    config.update(INPUT_SHA256=hashlib.sha256(inp).hexdigest(), INPUT_CRC=zlib.crc32(inp) & 0xffffffff)
    (output / 'model_config.tcl').write_text(''.join(f'set ::NPUG_{k} {v}\n' for k, v in config.items()), encoding='ascii')
    print(json.dumps(dict(output=str(output), fusions=len(lower.fusions),
                         absorbed_operations=len(lower.absorbed_operations), plan_records=len(lower.records),
                         executed_model=False, verified=False)))
    return manifest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model-dir', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    build(a.model_dir, a.output)


if __name__ == '__main__':
    main()
