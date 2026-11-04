"""Exact Conv -> optional SiLU -> optional Quant, with frozen AIPKG3 payloads.

Flags 8/16/24 select Quant/SiLU/SiLUQuant. Original Conv output geometry and
epilogue stay intact. Word15 is final output, 18/19 are multiplier/shift,
21 is final dtype. Feature bit2 gates this contract. Only singleton outer
Conv jobs are eligible; other layouts retain the existing execution records.
"""
from collections import Counter, defaultdict
import argparse
from pathlib import Path
import struct
import zlib

from compile_optimized_plan import OptimizedLowerer, build, overlaps
from compile_graph_plan import OP


class ConvFusedLowerer(OptimizedLowerer):
    def lower(self):
        super().lower()
        records, indices = self.records, self.index
        uses, definitions = defaultdict(list), defaultdict(list)
        for i, (_, inputs, outputs, _) in enumerate(self.g.ops):
            for tid in inputs:
                uses[tid].append(i)
            for tid in outputs:
                definitions[tid].append(i)
        groups = {f['first_op']: f for f in self.fusions}
        replacements, absorbed, fused_groups = {}, set(self.absorbed_operations), []

        def safe_elision(tid, first, last, internal):
            if tid == self.g.header[13] or len(definitions[tid]) != 1:
                return False
            for aid, alias in self.g.tensors.items():
                if aid in internal or not overlaps(self.g.tensors[tid], alias):
                    continue
                born = definitions[aid][0] if definitions[aid] else -1
                end = len(self.g.ops) if aid == self.g.header[13] else max(uses[aid], default=-1)
                if len(definitions[aid]) > 1 or born <= last and end >= first:
                    return False
            return True

        for i, (opcode, inputs, outputs, _) in enumerate(self.g.ops[:-1]):
            if opcode != 2 or len(outputs) != 1 or len(definitions[outputs[0]]) != 1:
                continue
            x = outputs[0]
            op, qin, qout, qa = self.g.ops[i+1]
            quant, flags = None, 0
            if op == 1 and qin == [x] and len(qout) == 1 and uses[x] == [i+1]:
                stop, target, internal, flags, quant = i+1, qout[0], {x, qout[0]}, 8, qa
            elif i+1 in groups and qin == [x] and uses[x] == [i+1, i+2]:
                group = groups[i+1]
                stop, target = group['last_op'], group['output_tensor']
                quantized = group['quantized']
                # A standalone SiLU cannot quantize over its still-live x.
                # Conv fusion removes that intermediate entirely, so the
                # larger chain can be safe even when the smaller one is not.
                if not quantized and stop+1 < len(self.g.ops):
                    qop, qinputs, qoutputs, qattrs = self.g.ops[stop+1]
                    if (qop == 1 and qinputs == [target] and len(qoutputs) == 1 and
                            uses[target] == [stop+1]):
                        stop, target, quantized = stop+1, qoutputs[0], True
                internal = {x, target}
                for j in range(i+1, stop+1):
                    internal.update(self.g.ops[j][2])
                flags = 24 if quantized else 16
                if quantized:
                    quant = self.g.ops[stop][3]
            else:
                continue
            if not all(safe_elision(t, i, stop, internal) for t in internal if t != target):
                continue
            y = self.g.tensors[target]
            if y.const or y.shape != self.g.tensors[x].shape or y.dtype not in ((3,) if flags == 16 else (1, 2)):
                continue
            # Tile order differs from scalar order: require final output to be
            # disjoint from all Conv inputs, coefficients and its own scratch.
            first, count = struct.unpack('<II', indices[i])
            new = []
            for record in records[first:first+count]:
                w = list(struct.unpack('<128I', record))
                if any(d != 1 for d in w[24:24+w[7]]) or any(overlaps(y, self.g.tensors[t]) for t in inputs):
                    break
                scratch_bytes = w[68]*w[69]*32*8 if w[86] > 1024 else 0
                if scratch_bytes and y.offset < w[17]+scratch_bytes and w[17] < y.offset+y.nbytes:
                    break
                w[2], w[15], w[21] = flags, y.ptr, y.dtype
                if quant:
                    w[18], w[19] = quant['multiplier'], quant['shift']
                new.append(struct.pack('<128I', *w))
            if len(new) != count:
                continue
            replacements[i] = new
            absorbed.update(range(i+1, stop+1))
            fused_groups.append(dict(first_op=i, last_op=stop, flags=flags,
                                     output_tensor=target, records=count,
                                     eliminated_ddr_bytes=sum(self.g.tensors[t].nbytes*2 for t in internal if t != target)))
        self.records, self.index, self.counts = [], [], Counter()
        for i, index in enumerate(indices):
            begin = len(self.records)
            if i not in absorbed:
                first, count = struct.unpack('<II', index)
                for record in replacements.get(i, records[first:first+count]):
                    self.records.append(record)
                    self.counts[OP[struct.unpack_from('<I', record, 12)[0]]] += 1
            self.index.append(struct.pack('<II', begin, len(self.records)-begin))
        self.fusions = [f for f in self.fusions if f['first_op'] not in absorbed] + fused_groups
        self.conv_fusions = fused_groups
        self.absorbed_operations = sorted(absorbed)
        return self

    def image(self):
        result = bytearray(super().image())
        features = (1 if any(f.get('flags', 0) == 0 for f in self.fusions) else 0) | (4 if self.conv_fusions else 0)
        struct.pack_into('<I', result, 128, features)
        struct.pack_into('<I', result, 68, 0)
        struct.pack_into('<I', result, 68, zlib.crc32(result[:256]) & 0xffffffff)
        return bytes(result)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    build(args.model_dir, args.output, lowerer_class=ConvFusedLowerer)
