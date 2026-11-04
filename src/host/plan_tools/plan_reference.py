"""Functional NPUPLN1 interpreter, independent of graph lowering.

Reads the emitted binary records, addresses and strides into a poisoned DDR
workspace. This checks lowering and integer semantics, NOT RTL handshakes,
DSP mapping, timing or hardware execution. CUDA is used only for exact INT8
GEMM; all other arithmetic is NumPy integer arithmetic. No Golden functions
or Lowerer methods are used here.
"""
from __future__ import annotations

import hashlib
import math
from pathlib import Path
import struct
import zlib

import numpy as np
import torch

from legacy_plan_abi import LEGACY_R18, requant_i8, residual_i8

DT = {1: np.dtype('i1'), 2: np.dtype('<i2'), 3: np.dtype('<i4'), 4: np.dtype('<i8')}
LIMIT = np.iinfo(np.int64)


def check(ok, message):
    if not ok:
        raise ValueError(message)


def rne_div(x, d):
    x = np.asarray(x, dtype=np.int64)
    d = np.asarray(d, dtype=np.int64)
    check(bool(np.all(d > 0)), 'nonpositive RNE divisor')
    check(not bool(np.any(x == LIMIT.min)), 'INT64_MIN magnitude unsupported')
    a = np.abs(x)
    q, r = a // d, a % d
    q = q + ((r > d-r) | ((r == d-r) & ((q & 1) != 0)))
    return np.where(x < 0, -q, q)


def rne_shift(x, shift):
    s = np.asarray(shift, dtype=np.int64)
    check(bool(np.all((s >= 0) & (s <= 62))), 'RNE shift range')
    return rne_div(x, np.left_shift(np.int64(1), s))


def mul_checked(a, b):
    a, b = np.broadcast_arrays(np.asarray(a, dtype=np.int64), np.asarray(b, dtype=np.int64))
    check(not bool(np.any(a == LIMIT.min) or np.any(b == LIMIT.min)), 'INT64_MIN product')
    check(bool(np.all(np.abs(a) <= LIMIT.max // np.maximum(np.abs(b), 1))), 'INT64 product overflow')
    return a*b


def add_checked(a, b):
    a, b = np.broadcast_arrays(np.asarray(a, dtype=np.int64), np.asarray(b, dtype=np.int64))
    # Operand-aware bounds avoid performing an overflowing intermediate.
    check(not bool(np.any(a[b > 0] > LIMIT.max-b[b > 0])), 'INT64 addition overflow')
    check(not bool(np.any(a[b < 0] < LIMIT.min-b[b < 0])), 'INT64 addition underflow')
    return a+b


def sum_checked(a, axis=-1, keepdims=False):
    a = np.asarray(a, dtype=np.int64)
    n = a.shape[axis]
    check(not bool(np.any(a == LIMIT.min)), 'INT64_MIN sum')
    bound = int(np.max(np.abs(a), initial=0))*n
    check(bound <= LIMIT.max, 'INT64 reduction bound')
    return a.sum(axis=axis, keepdims=keepdims, dtype=np.int64)


def isqrt_array(x):
    """Exact integer Newton square root; no floating point seed."""
    x = np.asarray(x, dtype=np.int64)
    check(bool(np.all(x >= 0)), 'negative isqrt')
    probe = x.copy()
    bits = np.zeros(x.shape, dtype=np.int64)
    for shift in (32, 16, 8, 4, 2, 1):
        take = (probe >> shift) != 0
        probe = np.where(take, probe >> shift, probe)
        bits += take.astype(np.int64)*shift
    bits += (x != 0)
    root = np.left_shift(np.int64(1), (bits+1)//2)
    for _ in range(8):
        root = (root + x//np.maximum(root, 1)) >> 1
    # Division-based correction avoids squaring a rounded-up 2**32 seed.
    return root - (root > x//np.maximum(root, 1))


class PlanReference:
    def __init__(self, model_dir, device='cuda', poison=0xa5):
        self.folder = Path(model_dir)
        self.bundle = (self.folder/'ddr.bin').read_bytes()
        self.device = torch.device(device)
        b = self.bundle
        check(b[:8] == b'AIPKG3\0\0' and len(b) >= 256, 'original package magic')
        self.source_words = struct.unpack_from('<64I', b)
        source_size = self.source_words[8]
        self.plan_offset = (source_size+4095)//4096*4096
        check(self.plan_offset+256 <= len(b), 'missing appended plan')
        p = b[self.plan_offset:]
        check(p[:8] == b'NPUPLN1\0', 'plan magic')
        h = self.header = struct.unpack_from('<64I', p)
        check(h[2:7] == (1, 256, self.source_words[4], 2, 512), 'plan ABI')
        check(h[13] == len(p) and h[13] % 4096 == 0, 'plan length')
        head = bytearray(p[:256]); head[68:72] = bytes(4)
        check(zlib.crc32(head) & 0xffffffff == h[17], 'plan header CRC')
        check(zlib.crc32(p[256:]) & 0xffffffff == h[16], 'plan body CRC')
        check(h[14:16] == (self.source_words[16], source_size), 'plan source binding')
        check(zlib.crc32(b[256:source_size]) & 0xffffffff == h[14], 'source body CRC')
        check(h[10] == 8*h[7] and h[12] == 512*h[8], 'table lengths')
        check(4096 <= h[9] and h[9]+h[10] <= h[11] and h[11]+h[12] <= len(p), 'table extents')
        check(h[18]+h[19] <= source_size and h[31] >= self.source_words[10], 'memory capacities')
        self.constants = b[h[18]:h[18]+h[19]]
        self.workspace = bytearray([poison])*h[31]
        self.records = [struct.unpack_from('<128I', p, h[11]+512*i) for i in range(h[8])]
        self.index = [struct.unpack_from('<II', p, h[9]+8*i) for i in range(h[7])]
        cursor = 0
        for op, (first, count) in enumerate(self.index):
            check(first == cursor and count > 0 and first+count <= len(self.records), 'index coverage')
            check(all(r[1] == op for r in self.records[first:first+count]), 'record operation owner')
            cursor += count
        check(cursor == len(self.records), 'unowned records')
        self.stats = dict(records=0, original_operations=0, conv_k_tiles=0, a16_k_tiles=0,
                          conv_records=0, a16_conv_records=0, depthwise_records=0,
                          max_conv_k=0, attention_matmuls=0, workspace_poison=poison)

    def view(self, pointer, dtype, shape, strides=None, write=False):
        check(dtype in DT, 'dtype')
        dt = DT[dtype]; const = bool(pointer & 0x80000000); offset = pointer & 0x7fffffff
        check(not (write and const), 'constant write')
        region = self.constants if const else self.workspace
        shape = tuple(int(v) for v in shape)
        if strides is None:
            step = dt.itemsize; strides = []
            for dim in reversed(shape):
                strides.insert(0, step); step *= dim
        strides = tuple(int(v) for v in strides)
        check(len(shape) == len(strides) and all(v > 0 for v in shape) and all(v >= 0 for v in strides), 'affine dimensions')
        end = offset + dt.itemsize + sum((dim-1)*step for dim, step in zip(shape, strides))
        check(offset % dt.itemsize == 0 and all(v % dt.itemsize == 0 for v in strides), 'unaligned typed view')
        check(end <= len(region), f'DDR bounds {offset}:{end}/{len(region)}')
        return np.ndarray(shape, dtype=dt, buffer=region, offset=offset, strides=strides)

    def put(self, pointer, dtype, shape, strides, value):
        value = np.asarray(value)
        info = np.iinfo(DT[dtype])
        check(not bool(np.any(value < info.min) or np.any(value > info.max)), 'output narrowing overflow')
        self.view(pointer, dtype, shape, strides, write=True)[...] = value

    def lut(self, x, kind):
        offset, entries, dtype = self.header[20+3*kind:23+3*kind]
        table = self.view(0x80000000 | offset, dtype, (entries,)).astype(np.int64)
        check(entries == (4097 if kind == 2 else 8193), 'LUT domain')
        z = np.clip(np.asarray(x, dtype=np.int64), -1048576, 0 if kind == 2 else 1048576)+1048576
        index = np.minimum(z >> 8, entries-2)
        frac = z-(index << 8)
        return add_checked(table[index], rne_shift(mul_checked(table[index+1]-table[index], frac), 8))

    def dot_i8(self, a, weights, bits):
        """Integer CUDA GEMM in K<=1024 chunks, accumulating signed INT64.

        The two byte planes reconstruct A16 exactly. This models arithmetic
        and K chunking, not pair unpack wires, PE cycles or ping-pong timing.
        """
        a = np.asarray(a); weights = np.asarray(weights)
        m, k = a.shape; oc = weights.shape[0]
        output = np.empty((m, oc), dtype=np.int64)
        self.stats['max_conv_k'] = max(self.stats['max_conv_k'], k)
        for row in range(0, m, 4096):
            rows = min(4096, m-row)
            total = torch.zeros((rows, oc), dtype=torch.int64, device=self.device)
            for start in range(0, k, 1024):
                aa = torch.as_tensor(np.array(a[row:row+rows, start:start+1024], copy=True), device=self.device)
                ww = torch.as_tensor(np.array(weights[:, start:start+1024], copy=True), device=self.device, dtype=torch.int8)
                def mm8(left):
                    # Explicit padding and column-major B satisfy CUDA INT8 GEMM.
                    rr, kk = left.shape; oo = ww.shape[0]
                    pr, pk, po = max(32, (rr+15)//16*16)-rr, (-kk) % 16, (-oo) % 8
                    left = torch.nn.functional.pad(left, (0, pk, 0, pr))
                    right = torch.nn.functional.pad(ww, (0, pk, 0, po))
                    return torch._int_mm(left.contiguous(), right.contiguous().t())[:rr, :oo].to(torch.int64)
                if bits == 8:
                    part = mm8(aa.to(torch.int8))
                else:
                    z = aa.to(torch.int32)
                    part = mm8(((z & 255)-128).to(torch.int8))
                    part += mm8((z >> 8).to(torch.int8)) << 8
                    part += ww.to(torch.int64).sum(1)[None, :] << 7
                    self.stats['a16_k_tiles'] += 1
                total += part
                self.stats['conv_k_tiles'] += 1
            output[row:row+rows] = total.cpu().numpy()
        return output

    def conv(self, w, outer, ast, yst):
        ic, ih, iw, oc, oh, ow, kh, kw, sh, sw, pt, pl, dh, dw, groups, _ = w[64:80]
        self.stats['conv_records'] += 1
        self.stats['a16_conv_records'] += int(w[20] == 16)
        self.stats['depthwise_records'] += int(ic == oc == groups)
        check(ic % groups == 0 and oc % groups == 0, 'conv groups')
        ab, yb = DT[w[4]].itemsize, DT[w[6]].itemsize
        inp = self.view(w[8], w[4], outer+(ic, ih, iw), ast+(ih*iw*ab, iw*ab, ab))
        inp = np.array(inp, copy=True).reshape(-1, ic, ih, iw)
        if w[120]:
            check(w[120] == 0x314b5057 and groups == 1 and kh == kw == 3 and
                  w[121] == ((ic+7)//8)*72, 'WPK1 convolution geometry')
            packed = self.view(w[11], 1, (oc, (ic+7)//8, 9, 8))
            weights = packed.transpose(0, 1, 3, 2).reshape(oc, ((ic+7)//8)*8, kh, kw)[:, :ic]
        else:
            weights = self.view(w[11], 1, (oc, ic//groups, kh, kw))
        bias, mult, shift = [self.view(w[j], w[80+j-12], (oc,)).astype(np.int64) for j in (12, 13, 14)]
        bottom = max(0, (oh-1)*sh+(kh-1)*dh+1-ih-pt)
        right = max(0, (ow-1)*sw+(kw-1)*dw+1-iw-pl)
        padded = np.pad(inp, ((0, 0), (0, 0), (pt, bottom), (pl, right)))
        ns, cs, hs, ws = padded.strides
        patches = np.lib.stride_tricks.as_strided(padded,
            shape=(len(inp), ic, oh, ow, kh, kw),
            strides=(ns, cs, hs*sh, ws*sw, hs*dh, ws*dw), writeable=False)
        result = np.empty((len(inp), oc, oh, ow), dtype=np.int64)
        for group in range(groups):
            ai, oi = group*(ic//groups), group*(oc//groups)
            aa = patches[:, ai:ai+ic//groups].transpose(0, 2, 3, 1, 4, 5).reshape(-1, ic//groups*kh*kw)
            ww = weights[oi:oi+oc//groups].reshape(oc//groups, -1)
            if ic == oc == groups:
                raw = sum_checked(mul_checked(aa, ww[0]), axis=-1)[:, None]
            else:
                raw = self.dot_i8(aa, ww, w[20])
            raw = add_checked(raw, bias[oi:oi+oc//groups])
            if w[2] == LEGACY_R18:
                # Preserve the original 40-bit accumulator and 72-bit product.
                # Python-int scalar arithmetic is intentional: an INT64 product
                # would truncate legal legacy numerators and shifts up to 127.
                q = np.frompyfunc(requant_i8, 3, 1)
                raw = q(raw, mult[oi:oi+oc//groups], shift[oi:oi+oc//groups]).astype(np.int64)
            else:
                check(bool(np.all(np.abs(raw) <= 2147483647)), 'conv requant INT32 operand')
                raw = rne_shift(mul_checked(raw, mult[oi:oi+oc//groups]), shift[oi:oi+oc//groups])
            result[:, oi:oi+oc//groups] = raw.reshape(len(inp), oh, ow, oc//groups).transpose(0, 3, 1, 2)
        self.put(w[10], w[6], outer+(oc, oh, ow), yst+(oh*ow*yb, ow*yb, yb), result.reshape(outer+(oc, oh, ow)))

    def execute_record(self, w):
        engine, _, flags, op, adt, bdt, ydt, rank = w[:8]
        check(flags in (0, LEGACY_R18) and 0 <= rank <= 8, 'record flags/rank')
        legacy = flags == LEGACY_R18
        if legacy:
            check(self.header[4] == 1 and adt == bdt == ydt == 1 and
                  (engine, op) in ((5, 2), (5, 3), (1, 4), (1, 11), (6, 19), (2, 20)),
                  'ResNet legacy numerical profile')
        outer = tuple(w[24:24+rank]); ast = tuple(w[32:32+rank])
        bst = tuple(w[40:40+rank]); yst = tuple(w[48:48+rank])
        count = w[64]
        shape = outer+(count,)
        if engine == 5:
            self.conv(w, outer, ast, yst)
        elif engine in (1, 2, 4):
            a = self.view(w[8], adt, shape, ast+(w[65],)).astype(np.int64)
            if engine == 4:
                result = a
            elif engine == 1:
                if op == 1:
                    check(bool(np.all(np.abs(a) <= 2147483647)), 'QUANT operand')
                    mult = w[17] | w[18] << 32
                    result = rne_shift(mul_checked(a, mult), w[19])
                    check(ydt in (1, 2), 'QUANT destination type')
                    maximum = np.iinfo(DT[ydt]).max
                    result = np.clip(result, -maximum, maximum)
                elif op in (4, 5):
                    b = self.view(w[9], bdt, shape, bst+(w[66],)).astype(np.int64)
                    if legacy:
                        # Two exact 8x64 products, one 73-bit sum, ONE RNE.
                        ma = w[17] | w[18] << 32
                        mb = w[21] | w[22] << 32
                        add_i8 = np.frompyfunc(lambda aa, bb: residual_i8(aa, bb, ma, mb, w[19]), 2, 1)
                        result = add_i8(a, b).astype(np.int64)
                    else:
                        result = add_checked(a, b) if op == 4 else rne_shift(mul_checked(a, b), 16)
                elif op in (9, 10):
                    result = self.lut(a, 0 if op == 9 else 1)
                elif op == 11:
                    result = np.maximum(a, 0)
                else:
                    raise ValueError(f'elementwise opcode {op}')
            elif op == 20:
                total = sum_checked(a, keepdims=True)
                if legacy:
                    # The frozen GAP multiplier already includes its spatial
                    # normalization. A separate division would change results.
                    q = np.frompyfunc(lambda value: requant_i8(value, w[17], w[19]), 1, 1)
                    result = q(total).astype(np.int64)
                else:
                    result = rne_div(total, count)
            elif op == 8:
                e = self.lut(a-a.max(axis=-1, keepdims=True), 2)
                result = rne_div(mul_checked(e, 65536), np.maximum(sum_checked(e, keepdims=True), 1))
            elif op == 7:
                mean = rne_div(sum_checked(a, keepdims=True), count)
                centered = a-mean
                check(int(np.max(np.abs(centered), initial=0))**2*count < 1 << 62, 'LN variance bound')
                var = rne_div(sum_checked(mul_checked(centered, centered), keepdims=True), count)
                check(bool(np.all(var < 1 << 46)), 'LN Q48 bound')
                den = np.maximum(isqrt_array(add_checked(mul_checked(var, 65536), w[22] | w[23] << 32)), 1)
                normal = rne_div(mul_checked(centered, 1 << 24), den)
                gamma = self.view(w[15], w[21], (count,)).astype(np.int64)
                beta = self.view(w[16], w[21], (count,)).astype(np.int64)
                result = add_checked(rne_shift(mul_checked(normal, gamma), 16), beta)
            else:
                raise ValueError(f'reduction opcode {op}')
            out_shape = outer+(1 if engine == 2 and op == 20 else count,)
            self.put(w[10], ydt, out_shape, yst+(w[67],), result)
        elif engine == 3:
            m, n, k = w[64:67]
            a = self.view(w[8], adt, outer+(m, k), ast+(w[67], w[68])).astype(np.int64)
            b = self.view(w[9], bdt, outer+(k, n), bst+(w[69], w[70])).astype(np.int64)
            check(int(np.max(np.abs(a), initial=0))*int(np.max(np.abs(b), initial=0))*k < 1 << 62, 'MatMul bound')
            # Strict CPU integer product; no floating-point attention carrier.
            result = rne_shift(np.matmul(a, b), 16)
            self.put(w[10], ydt, outer+(m, n), yst+(w[71], w[72]), result)
            self.stats['attention_matmuls'] += 1
        elif engine == 6:
            ih, iw, oh, ow, kh, kw, sh, sw, pt, pl = w[64:74]
            ab, yb = DT[adt].itemsize, DT[ydt].itemsize
            a = self.view(w[8], adt, outer+(ih, iw), ast+(iw*ab, ab))
            pb, pr = max(0, (oh-1)*sh+kh-ih-pt), max(0, (ow-1)*sw+kw-iw-pl)
            padded = np.pad(a, ((0, 0),)*rank+((pt, pb), (pl, pr)), constant_values=np.iinfo(DT[adt]).min)
            windows = np.lib.stride_tricks.sliding_window_view(padded, (kh, kw), axis=(-2, -1))
            result = windows[..., ::sh, ::sw, :, :][..., :oh, :ow, :, :].max(axis=(-1, -2))
            self.put(w[10], ydt, outer+(oh, ow), yst+(ow*yb, yb), result)
        else:
            raise ValueError(f'engine {engine}')
        self.stats['records'] += 1

    def execute_op(self, op_index):
        check(op_index == self.stats['original_operations'], 'out-of-order graph step')
        first, count = self.index[op_index]
        for record in self.records[first:first+count]:
            self.execute_record(record)
        self.stats['original_operations'] += 1

    def sha256(self):
        return hashlib.sha256(self.bundle).hexdigest()
