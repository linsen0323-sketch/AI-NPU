"""Lower a frozen AIPKG3 graph into relocatable hardware execution records.

No training, requantization, Golden execution or model-file mutation occurs.
The output ddr.bin contains the original package byte-for-byte, followed by a
separately checksummed NPUPLN1 plan. It is NOT compatible with the old loader.
"""
from __future__ import annotations
import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import zlib

DTYPE = {1: (1, 'b'), 2: (2, 'h'), 3: (4, 'i'), 4: (8, 'q')}
OP = dict(zip(range(1, 21), ('QUANT CONV LINEAR ADD MUL MATMUL LAYERNORM '
    'SOFTMAX SIGMOID EXP RELU RESHAPE TRANSPOSE CONCAT SLICE SPLIT EXPAND '
    'RESIZE_NEAREST MAXPOOL GAP').split()))
FIELDS = dict(enumerate(('multiplier shift bits weight bias activation_bits '
    'strides pads dilations group gamma beta epsilon_q48 axis shape perm starts '
    'ends axes steps sizes kernel').split(), 1))
RECORD_BYTES = 512
ENG_ELEMENT, ENG_REDUCE, ENG_MATMUL, ENG_COPY, ENG_CONV, ENG_POOL = range(1, 7)


def align(x, n=4096):
    return (x+n-1)//n*n


def require(ok, why):
    if not ok:
        raise ValueError(why)


def strides(shape, width):
    result = [0]*len(shape)
    for i in reversed(range(len(shape))):
        result[i] = width
        width *= shape[i]
    return result


@dataclass
class Tensor:
    tid: int
    const: bool
    dtype: int
    offset: int
    nbytes: int
    shape: list[int]

    @property
    def width(self):
        return DTYPE[self.dtype][0]

    @property
    def ptr(self):
        require(0 <= self.offset < 2**31, 'pointer exceeds tagged-offset range')
        return self.offset | (0x80000000 if self.const else 0)

    @property
    def step(self):
        return strides(self.shape, self.width)


class Graph:
    def __init__(self, source):
        self.source = Path(source)
        self.blob = self.source.read_bytes()
        b = self.blob
        require(len(b) >= 256 and b[:8] == b'AIPKG3\0\0', 'AIPKG3 magic')
        h = list(struct.unpack_from('<64I', b))
        require(h[2:4] == [3, 256] and h[5] == 2 and h[4] in (2, 3), 'graph profile')
        require(h[9] == h[11] == 0 and h[8] == len(b), 'image/workspace size')
        hc = bytearray(b[:256]); hc[56:60] = bytes(4)
        require(zlib.crc32(hc) & 0xffffffff == h[14], 'header CRC')
        require(zlib.crc32(b[256:]) & 0xffffffff == h[16], 'body CRC')
        require(h[6] == 5, 'section count')
        directory = b[256:256+64*h[6]]
        require(zlib.crc32(directory) & 0xffffffff == h[7], 'directory CRC')
        self.header = h
        self.sections = {}; self.section_offsets = {}
        ranges = []
        for i in range(h[6]):
            name, off, nb, crc, alignment = struct.unpack_from('<16sQQII', directory, i*64)
            name = name.rstrip(b'\0').decode('ascii')
            require(off % 4096 == 0 and alignment == 4096 and off >= 4096 and off+nb <= len(b), 'section range')
            require(all(off+nb <= a or end <= off for a, end in ranges), 'overlapping sections')
            require(name not in self.sections and zlib.crc32(b[off:off+nb]) & 0xffffffff == crc, 'section CRC/name')
            self.sections[name] = b[off:off+nb]; self.section_offsets[name] = off
            ranges.append((off, off+nb))
        require(set(self.sections) == {'META','TENSORS','INSTRUCTIONS','ATTRIBUTES','CONSTANTS'}, 'sections')
        self.meta = json.loads(self.sections['META'])
        self.names = {int(tid): name for name, tid in self.meta['tensor_ids'].items()}
        self.tensors = {}
        tb = self.sections['TENSORS']
        require(len(tb) % 128 == 0, 'tensor record size')
        for pos in range(0, len(tb), 128):
            w = struct.unpack_from('<32I', tb, pos)
            tid, const, dtype, frac, rank, selector = w[:6]
            require(tid == pos//128 and const in (0, 1) and dtype in DTYPE and rank <= 8, 'tensor schema')
            require(selector == const and not w[7] and not w[9] and w[20] == 64 and not any(w[21:]), 'tensor metadata')
            require(frac == (0 if const or dtype < 3 else 16) and not any(w[12+rank:20]), 'tensor fractional bits')
            shape = list(w[12:12+rank])
            require(all(x > 0 for x in shape) and math.prod(shape)*DTYPE[dtype][0] == w[8], 'tensor shape')
            region = len(self.sections['CONSTANTS']) if const else h[10]
            require(w[6] % 64 == 0 and w[6]+w[8] <= region, 'tensor bounds')
            self.tensors[tid] = Tensor(tid, bool(const), dtype, w[6], w[8], shape)
        self.ops = []
        ib = self.sections['INSTRUCTIONS']; ab = self.sections['ATTRIBUTES']
        require(len(ib) % 128 == 0, 'instruction record size')
        for pos in range(0, len(ib), 128):
            w = struct.unpack_from('<32I', ib, pos)
            require(w[0] in OP and w[1] == 0 and 1 <= w[2] <= 4 and 1 <= w[3] <= 4 and not any(w[15:]), 'instruction schema')
            ii, oo = list(w[4:4+w[2]]), list(w[8:8+w[3]])
            require(all(x in self.tensors for x in ii+oo) and all(x == 0xffffffff for x in w[4+w[2]:8]+w[8+w[3]:12]), 'instruction IDs')
            cursor = begin = w[12]; end = begin+w[13]
            require(begin % 16 == 0 and end <= len(ab), 'attribute range')
            attrs = {}; previous = 0
            while cursor < end:
                require(cursor+16 <= end, 'partial TLV')
                field, kind, count, value = struct.unpack_from('<IHHq', ab, cursor)
                require(previous < field and field in FIELDS and kind in (1, 2, 3), 'TLV schema/order')
                previous = field
                if kind == 3:
                    end = min(end, value)
                    require(cursor+16 <= end and value % 8 == 0 and value+count*8 <= begin+w[13] and count <= 8, 'TLV vector')
                    value = list(struct.unpack_from('<'+'q'*count, ab, value))
                else:
                    require(count == 1 and (kind != 2 or value in self.tensors and self.tensors[value].const), 'TLV scalar/ref')
                    if kind == 2:
                        value = self.tensors[value]
                attrs[FIELDS[field]] = value; cursor += 16
            require(cursor == end, 'TLV boundary')
            self.ops.append((w[0], ii, oo, attrs))

    def values(self, t):
        require(t.const, 'parameter must be constant')
        return [x[0] for x in struct.iter_unpack('<'+DTYPE[t.dtype][1], self.sections['CONSTANTS'][t.offset:t.offset+t.nbytes])]

    def named_lut(self, kind):
        found = [self.tensors[tid] for tid, name in self.names.items()
                 if name.endswith('_'+kind+'_lut') and
                 (kind != 'exp' or not name.endswith('_softmax_exp_lut'))]
        require(len(found) == 1 and found[0].const and found[0].dtype in (3, 4), 'LUT descriptor '+kind)
        return found[0]


class Lowerer:
    def __init__(self, graph):
        self.g = graph; self.records = []; self.index = []; self.counts = Counter(); self.scratch_bytes = 0

    def record(self, engine, opcode, index, x, y, b=None):
        require(not y.const, 'constant destination')
        w = [0]*128
        w[:8] = [engine, index, 0, opcode, x.dtype, b.dtype if b else x.dtype, y.dtype, 0]
        w[8:11] = [x.ptr, b.ptr if b else x.ptr, y.ptr]
        return w

    def emit(self, w, dims=(), ast=(), bst=(), yst=()):
        require(len(dims) <= 8 and len(ast) == len(yst) == len(dims), 'outer rank')
        require(not bst or len(bst) == len(dims), 'outer B rank')
        require(all(0 < d <= 0xffffffff for d in dims), 'outer dimension')
        require(math.prod(dims) <= 0xffffffff, 'outer iteration count')
        w[7] = len(dims)
        for off, values in ((24,dims),(32,ast),(40,bst or [0]*len(dims)),(48,yst)):
            w[off:off+len(values)] = values
        require(all(isinstance(v, int) and 0 <= v <= 0xffffffff for v in w), 'record word range')
        self.records.append(struct.pack('<128I', *w)); self.counts[OP[w[3]]] += 1

    @staticmethod
    def broadcast(t, shape):
        require(len(t.shape) <= len(shape), 'broadcast rank')
        padded = [1]*(len(shape)-len(t.shape))+t.shape
        steps = [0]*(len(shape)-len(t.shape))+t.step
        require(all(a == 1 or a == b for a, b in zip(padded, shape)), 'broadcast shape')
        return [0 if a == 1 else s for a, s in zip(padded, steps)]

    def affine(self, opcode, i, x, y, shape, asteps, ysteps, aoffset=0, yoffset=0):
        require((x.dtype == y.dtype or x.dtype in (3,4) and y.dtype in (3,4)) and
                all(s >= 0 for s in asteps+ysteps), 'copy type/positive steps')
        require(math.prod(shape) == 0 or all(v > 0 for v in shape), 'copy shape')
        w = self.record(ENG_COPY, opcode, i, x, y)
        w[8] += aoffset; w[10] += yoffset
        require((w[8] >> 31) == x.const and w[10] < 2**31, 'tagged offset carry')
        if not shape:
            shape = [1]; asteps = [x.width]; ysteps = [y.width]
        w[64:68] = [shape[-1], asteps[-1], 0, ysteps[-1]]
        self.emit(w, shape[:-1], asteps[:-1], (), ysteps[:-1])

    def lower(self):
        for i, (code, ii, oo, a) in enumerate(self.g.ops):
            first = len(self.records)
            ins = [self.g.tensors[j] for j in ii]; outs = [self.g.tensors[j] for j in oo]
            x, y = ins[0], outs[0]; op = OP[code]
            if op in ('QUANT','ADD','MUL','SIGMOID','EXP','RELU'):
                b = ins[1] if len(ins) == 2 else None
                require(len(outs) == 1 and x.dtype in (3,4), 'elementwise boundary')
                shape = y.shape or [1]
                ast = self.broadcast(x, shape); bst = self.broadcast(b, shape) if b else [0]*len(shape)
                w = self.record(ENG_ELEMENT, code, i, x, y, b)
                w[64:68] = [shape[-1],ast[-1],bst[-1],y.width]
                if op == 'QUANT':
                    require(y.dtype == (2 if a['bits'] == 16 else 1) and 0 < a['multiplier'] < 2**31 and 0 <= a['shift'] <= 62, 'quant parameters')
                    w[17:20] = [a['multiplier'], 0, a['shift']]
                self.emit(w,shape[:-1],ast[:-1],bst[:-1],y.step[:-1] if y.shape else [])
            elif op in ('CONV','LINEAR'):
                weight, bias, mult, shift = (a[k] for k in ('weight','bias','multiplier','shift'))
                require(all(isinstance(t, Tensor) and t.const for t in (weight,bias,mult,shift)), 'conv parameters')
                require(weight.dtype == 1 and x.dtype in (1,2) and y.dtype == 3 and a['activation_bits'] == x.width*8, 'conv dtypes')
                w = self.record(ENG_CONV, code, i, x, y)
                w[11:15] = [weight.ptr,bias.ptr,mult.ptr,shift.ptr]
                w[20] = a['activation_bits']; w[80:83] = [bias.dtype,mult.dtype,shift.dtype]
                if op == 'CONV':
                    require(len(x.shape) == len(y.shape) == len(weight.shape) == 4, 'conv rank')
                    n, ic, ih, iw = x.shape; ny, oc, oh, ow = y.shape
                    wo, wi, kh, kw = weight.shape; group = a['group']
                    sh, sw = a['strides']; pt, pl, pb, pr = a['pads']; dh, dw = a['dilations']
                    require(n == ny and oc == wo and ic % group == oc % group == 0 and wi == ic//group, 'conv channels/groups')
                    require(oh == (ih+pt+pb-dh*(kh-1)-1)//sh+1 and ow == (iw+pl+pr-dw*(kw-1)-1)//sw+1, 'conv output geometry')
                    w[64:80] = [ic,ih,iw,oc,oh,ow,kh,kw,sh,sw,pt,pl,dh,dw,group,0]
                    dims, ast, yst = [n],[x.step[0]],[y.step[0]]
                else:
                    require(len(weight.shape) == 2 and weight.shape[1] == x.shape[-1] and y.shape == x.shape[:-1]+[weight.shape[0]], 'linear geometry')
                    oc, ic = weight.shape
                    w[64:80] = [ic,1,1,oc,1,1,1,1,1,1,0,0,1,1,1,1]
                    dims, ast, yst = x.shape[:-1],x.step[:-1],y.step[:-1]
                require(all(t.shape == [oc] and t.dtype in (3,4) for t in (bias,mult,shift)), 'per-channel params')
                require(all(0 < v < 2**31 for v in self.g.values(mult)) and all(0 <= v <= 62 for v in self.g.values(shift)), 'requant domains')
                require(all(0 < w[j] < 65536 for j in range(64,74)) and all(0 <= w[j] < 65536 for j in (74,75)), 'conv hardware dimensions')
                ic,ih,iw,oc,oh,ow,kh,kw,sh,sw,pt,pl,dh,dw,group,_ = w[64:80]
                require(ic <= 4096 and oc <= 4096 and max(ih,iw,oh,ow) <= 4096 and
                        max(kh,kw) <= 31 and max(sh,sw,dh,dw) <= 64, 'conv engine limits')
                full_k = ic//group*kh*kw
                if full_k > 1024:
                    self.scratch_bytes = max(self.scratch_bytes, oh*ow*32*8)
                    w[17] = self.g.header[10]
                w[84:89] = [ic//group,oc//group,full_k,ih*iw*x.width,oh*ow*y.width]
                self.emit(w,dims,ast,(),yst)
            elif op == 'MATMUL':
                b = ins[1]
                require(x.dtype in (3,4) and b.dtype in (3,4) and y.dtype in (3,4), 'matmul dtypes')
                m,k = x.shape[-2:]; kb,n = b.shape[-2:]
                require(k == kb and y.shape[-2:] == [m,n], 'matmul geometry')
                lead = y.shape[:-2]
                ast = self.broadcast_batch(x, lead); bst = self.broadcast_batch(b, lead)
                w = self.record(ENG_MATMUL, code, i, x, y, b)
                w[64:73] = [m,n,k,x.step[-2],x.step[-1],b.step[-2],b.step[-1],y.step[-2],y.step[-1]]
                self.emit(w,lead,ast,bst,y.step[:-2])
            elif op in ('LAYERNORM','SOFTMAX','GAP'):
                w = self.record(ENG_REDUCE, code, i, x, y)
                require(x.dtype in (3,4) and y.dtype in (3,4), 'reduction dtypes')
                if op == 'GAP':
                    require(y.shape == x.shape[:2]+[1]*(len(x.shape)-2), 'GAP shape')
                    w[64:68] = [math.prod(x.shape[2:]),x.width,0,y.width]
                    dims, ast, yst = x.shape[:2],x.step[:2],y.step[:2]
                else:
                    require(x.shape == y.shape, 'reduction shape')
                    axis = (a.get('axis',-1)+len(x.shape)) % len(x.shape)
                    dims = x.shape[:axis]+x.shape[axis+1:]
                    ast = x.step[:axis]+x.step[axis+1:]; yst = y.step[:axis]+y.step[axis+1:]
                    w[64:68] = [x.shape[axis],x.step[axis],0,y.step[axis]]
                    if op == 'LAYERNORM':
                        require(axis == len(x.shape)-1, 'LayerNorm last axis')
                        gamma,beta = a['gamma'],a['beta']
                        require(gamma.dtype == beta.dtype and gamma.dtype in (3,4) and math.prod(gamma.shape) == math.prod(beta.shape) == x.shape[-1], 'LayerNorm params')
                        w[15:17] = [gamma.ptr,beta.ptr]; w[21] = gamma.dtype
                        eps = a['epsilon_q48']; require(0 <= eps < 2**63, 'epsilon domain')
                        w[22:24] = [eps & 0xffffffff, eps >> 32]
                self.emit(w,dims,ast,(),yst)
            elif op == 'RESHAPE':
                require(math.prod(x.shape) == math.prod(y.shape), 'reshape element count')
                self.affine(code,i,x,y,[math.prod(y.shape)],[x.width],[y.width])
            elif op == 'TRANSPOSE':
                perm = a['perm']
                require(sorted(perm) == list(range(len(x.shape))) and y.shape == [x.shape[p] for p in perm], 'transpose shape')
                self.affine(code,i,x,y,y.shape,[x.step[p] for p in perm],y.step)
            elif op in ('CONCAT','SPLIT'):
                axis = a['axis'] % len(x.shape); start = 0
                pairs = ((t,y) for t in ins) if op == 'CONCAT' else ((x,t) for t in outs)
                for src,dst in pairs:
                    shape = src.shape if op == 'CONCAT' else dst.shape
                    require(all(src.shape[j] == dst.shape[j] for j in range(len(shape)) if j != axis), 'concat/split dimensions')
                    ao = start*src.step[axis] if op == 'SPLIT' else 0
                    yo = start*dst.step[axis] if op == 'CONCAT' else 0
                    self.affine(code,i,src,dst,shape,src.step,dst.step,ao,yo)
                    start += shape[axis]
                require(start == (y.shape[axis] if op == 'CONCAT' else x.shape[axis]), 'concat/split extent')
            elif op == 'SLICE':
                ast = x.step.copy(); offset = 0; expected = x.shape.copy()
                for axis,beg,end,step in zip(a['axes'],a['starts'],a['ends'],a['steps']):
                    axis %= len(x.shape)
                    beg,end,step = slice(beg,end,step).indices(x.shape[axis])
                    require(step > 0, 'negative slice unsupported by this hardware plan')
                    offset += beg*ast[axis]; ast[axis] *= step; expected[axis] = len(range(beg,end,step))
                require(expected == y.shape, 'slice shape')
                self.affine(code,i,x,y,y.shape,ast,y.step,offset)
            elif op == 'EXPAND':
                self.affine(code,i,x,y,y.shape,self.broadcast(x,y.shape),y.step)
            elif op == 'RESIZE_NEAREST':
                require(len(x.shape) == len(y.shape) == 4 and x.shape[:2] == y.shape[:2], 'resize rank')
                ih,iw = x.shape[-2:]; oh,ow = y.shape[-2:]
                require(oh % ih == ow % iw == 0, 'integer nearest upsample required')
                sh,sw = oh//ih,ow//iw
                shape = [*x.shape[:2],ih,sh,iw,sw]
                ast = [*x.step[:2],x.step[2],0,x.step[3],0]
                yst = [*y.step[:2],y.step[2]*sh,y.step[2],y.step[3]*sw,y.step[3]]
                self.affine(code,i,x,y,shape,ast,yst)
            elif op == 'MAXPOOL':
                require(len(x.shape) == len(y.shape) == 4 and x.dtype == y.dtype == 3 and x.shape[:2] == y.shape[:2], 'pool boundary')
                ih,iw = x.shape[-2:]; oh,ow = y.shape[-2:]
                kh,kw = a['kernel']; sh,sw = a['strides']; pt,pl,pb,pr = a['pads']
                require(oh == (ih+pt+pb-kh)//sh+1 and ow == (iw+pl+pr-kw)//sw+1, 'pool shape')
                w = self.record(ENG_POOL,code,i,x,y)
                w[64:74] = [ih,iw,oh,ow,kh,kw,sh,sw,pt,pl]
                self.emit(w,x.shape[:2],x.step[:2],(),y.step[:2])
            else:
                raise NotImplementedError(op)
            require(len(self.records) > first, 'empty operation lowering')
            self.index.append(struct.pack('<II', first, len(self.records)-first))
        return self

    @staticmethod
    def broadcast_batch(t, lead):
        shape = t.shape[:-2]
        require(len(shape) <= len(lead), 'matmul batch rank')
        shape = [1]*(len(lead)-len(shape))+shape
        steps = [0]*(len(lead)-len(t.shape[:-2]))+t.step[:-2]
        require(all(a == 1 or a == b for a,b in zip(shape,lead)), 'matmul batch broadcast')
        return [0 if a == 1 else st for a,st in zip(shape,steps)]

    def image(self):
        index = b''.join(self.index); records = b''.join(self.records)
        record_offset = align(4096+len(index)); total = align(record_offset+len(records))
        result = bytearray(total)
        result[4096:4096+len(index)] = index; result[record_offset:record_offset+len(records)] = records
        h = [0]*64
        h[:2] = struct.unpack('<II',b'NPUPLN1\0')
        h[2:16] = [1,256,self.g.header[4],2,512,len(self.index),len(self.records),4096,len(index),record_offset,len(records),total,self.g.header[16],self.g.header[8]]
        h[16] = zlib.crc32(result[256:]) & 0xffffffff
        h[18:20] = [self.g.section_offsets['CONSTANTS'],len(self.g.sections['CONSTANTS'])]
        for off,kind in ((20,'sigmoid'),(23,'exp'),(26,'softmax_exp')):
            t = self.g.named_lut(kind); h[off:off+3] = [t.offset,math.prod(t.shape),t.dtype]
        h[29:32] = [self.g.header[12],self.g.header[13],align(self.g.header[10]+self.scratch_bytes)]
        result[:256] = struct.pack('<64I',*h)
        h[17] = zlib.crc32(result[:256]) & 0xffffffff
        result[:256] = struct.pack('<64I',*h)
        return bytes(result)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--fuse-silu', action='store_true', help='OPT1 exact SiLU/optional QUANT fusion; requires new hardware')
    args = p.parse_args()
    lower_type = Lowerer
    if args.fuse_silu:
        # Preserve one Tensor class when invoked as a script and imported by
        # the separately maintained optimization pass.
        sys.modules.setdefault('compile_graph_plan', sys.modules[__name__])
        from compile_optimized_plan import OptimizedLowerer
        lower_type = OptimizedLowerer
    g = Graph(args.model); lower = lower_type(g).lower(); plan = lower.image()
    out = args.output.resolve(); out.mkdir(parents=True,exist_ok=True)
    require(args.model.resolve() not in (out/'ddr.bin',out/'execution_plan.bin'), 'refuse model overwrite')
    plan_offset = align(len(g.blob))
    bundle = g.blob+bytes(plan_offset-len(g.blob))+plan
    example_dir = g.source.parent/'input_example'
    input_data = (example_dir/'input.bin').read_bytes()
    input_info = json.loads((example_dir/'input_manifest.json').read_text(encoding='utf-8'))
    source_sha = hashlib.sha256(g.blob).hexdigest()
    input_tensor,output_tensor = g.tensors[g.header[12]],g.tensors[g.header[13]]
    require(input_info['package_sha256'] == source_sha and input_info['sha256'] == hashlib.sha256(input_data).hexdigest()
            and len(input_data) == input_tensor.nbytes and input_info['offset'] == input_tensor.offset, 'frozen input provenance')
    (out/'execution_plan.bin').write_bytes(plan); (out/'ddr.bin').write_bytes(bundle)
    manifest = dict(format='NPUPLN1',model=g.meta['program']['name'],model_id=g.header[4],
        source_package=str(g.source.resolve()),source_sha256=hashlib.sha256(g.blob).hexdigest(),
        source_body_crc32=f'0x{g.header[16]:08X}',ddr_bytes=len(bundle),plan_offset=plan_offset,
        plan_bytes=len(plan),graph_operations=len(g.ops),plan_records=len(lower.records),
        records_per_opcode=dict(lower.counts),workspace_bytes=align(g.header[10]+lower.scratch_bytes),
        original_workspace_bytes=g.header[10],conv_scratch_bytes=lower.scratch_bytes,
        source_image_bytes=len(g.blob),input_tensor_id=g.header[12],output_tensor_id=g.header[13],
        input_offset=input_tensor.offset,input_bytes=input_tensor.nbytes,input_shape=input_tensor.shape,
        output_offset=output_tensor.offset,output_bytes=output_tensor.nbytes,output_shape=output_tensor.shape,output_dtype=output_tensor.dtype,
        ddr_sha256=hashlib.sha256(bundle).hexdigest(),
        fusion_groups=getattr(lower,'fusions',[]), absorbed_operations=getattr(lower,'absorbed_operations',[]),
        plan_feature_bits=struct.unpack_from('<I',plan,128)[0],
        required_features=['exact_silu_fusion_v1'] if getattr(lower,'fusions',[]) else [],
        accuracy_validated=False,rtl_verified=False,board_verified=False,compatible_with_legacy_loader=False)
    (out/'execution_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (out/'input.bin').write_bytes(input_data)
    (out/'input_manifest.json').write_text(json.dumps(input_info,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    configs = dict(MODEL_NAME=g.meta['program']['name'],MODEL_ID=g.header[4],
        DDR_SHA256=manifest['ddr_sha256'],INPUT_SHA256=hashlib.sha256(input_data).hexdigest(),DDR_BYTES=len(bundle),
        DDR_CRC=zlib.crc32(bundle)&0xffffffff,WORKSPACE_BYTES=manifest['workspace_bytes'],PLAN_OFFSET=plan_offset,PLAN_BYTES=len(plan),
        INPUT_OFFSET=input_tensor.offset,INPUT_BYTES=input_tensor.nbytes,INPUT_CRC=zlib.crc32(input_data)&0xffffffff,
        OUTPUT_OFFSET=output_tensor.offset,OUTPUT_BYTES=output_tensor.nbytes,OUTPUT_DTYPE=output_tensor.dtype)
    (out/'model_config.tcl').write_text('\n'.join(f'set ::NPUG_{k} {v}' for k,v in configs.items())+'\n',encoding='utf-8')
    prefix=g.meta['program']['name'].upper()
    (out/'model_config.h').write_text('#pragma once\n'+''.join(f'#define {prefix}_{k} {v}u\n' for k,v in configs.items() if isinstance(v,int)),encoding='utf-8')
    for filename in ('load_graph.tcl','read_graph_result.tcl'):
        (out/filename).write_bytes((Path(__file__).parent/filename).read_bytes())
    print(json.dumps(manifest,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    main()
