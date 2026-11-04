"""Executable integer golden for AIGRAPH_INTEGER_V1.

Conv/Linear dot products use integer CUDA GEMM, with exact byte decomposition
for A16. Attention offers a strict CPU INT64 dot backend and an accelerated
FP64 carrier backend. The latter is allowed only after proving integer products
and all partial sums fit 53 bits; it is audited against the strict backend.
All requantization, normalization, sqrt, LUT, pooling and glue are integer.
"""
from __future__ import annotations
import json
import math
import time
from pathlib import Path
from collections import Counter
import numpy as np
import torch
from torch.nn import functional as TF
from compiler import ART,F,Q


def rdiv(n,d):
    """Signed round-to-nearest ties-to-even division, positive denominator."""
    n=n.to(torch.int64);d=torch.as_tensor(d,device=n.device,dtype=torch.int64)
    a=n.abs();v=torch.div(a,d,rounding_mode='floor');r=a-v*d
    v=v+((r>d-r)|((r==d-r)&((v&1)!=0))).to(torch.int64)
    return torch.where(n<0,-v,v)


def rshift(x,s):
    return rdiv(x,torch.ones_like(torch.as_tensor(s,device=x.device,dtype=torch.int64))<<torch.as_tensor(s,device=x.device,dtype=torch.int64))


def requant(x,m,s):
    # x is bounded to INT32 for all compiled uses; x*m fits signed INT64.
    x=x.to(torch.int64)
    if int(x.abs().max())>2147483647:raise OverflowError('requant operand exceeds INT32 contract')
    return rshift(x*torch.as_tensor(m,device=x.device,dtype=torch.int64),s)


def isqrt(x):
    """Integer bit-length initialization and Newton sqrt, corrected to floor."""
    x=x.to(torch.int64)
    if bool((x<0).any()):raise OverflowError('negative square-root input')
    shifted=x.clone();bits=torch.zeros_like(x)
    for step in [32,16,8,4,2,1]:
        take=(shifted>>step)!=0
        shifted=torch.where(take,shifted>>step,shifted)
        bits=bits+take.to(torch.int64)*step
    bits=bits+(x!=0).to(torch.int64)
    root=torch.ones_like(x)<<((bits+1)//2)
    for _ in range(8):root=(root+torch.div(x,root.clamp_min(1),rounding_mode='floor'))>>1
    return root-(root*root>x).to(torch.int64)


def _i8mm(a,b):
    """MxK @ KxN -> INT32, tensor-core aligned without changing arithmetic."""
    m,k=a.shape;kk,n=b.shape;assert k==kk
    pm=max(32,((m+15)//16)*16)-m;pk=(-k)%16;pn=(-n)%8
    if pm or pk:a=TF.pad(a,(0,pk,0,pm))
    if pk or pn:b=TF.pad(b,(0,pn,0,pk))
    # cuBLAS INT8 supports a broader shape set with B column-major (TN GEMM).
    return torch._int_mm(a.contiguous(),b.t().contiguous().t())[:m,:n]


def int_weight_mm(x,w,bits):
    """x [...,IC] integer, w [OC,IC] INT8, exact INT64 result."""
    shape=x.shape[:-1];k=x.shape[-1];a=x.reshape(-1,k)
    b=w.t().contiguous().to(torch.int8)
    results=[]
    for start in range(0,len(a),8192):
        block=a[start:start+8192]
        if bits==8:out=_i8mm(block.to(torch.int8),b).to(torch.int64)
        else:
            z=block.to(torch.int32)
            low=((z&255)-128).to(torch.int8);high=(z>>8).to(torch.int8)
            out=_i8mm(low,b).to(torch.int64)+(_i8mm(high,b).to(torch.int64)<<8)+(w.to(torch.int64).sum(1)[None,:]<<7)
        results.append(out)
    return torch.cat(results).reshape(*shape,w.shape[0])


class Runtime:
    def __init__(self,name=None,program=None,parameters=None,device='cuda',strict_attention=False):
        self.device=torch.device(device)
        self.strict_attention=strict_attention
        if program is None:
            p=ART/name
            program=json.loads((p/'program.json').read_text(encoding='utf-8'))
            parameters=dict(np.load(p/'parameters.npz'))
        self.program=program
        self.params={k:torch.from_numpy(np.array(v,copy=True)).to(self.device) for k,v in parameters.items()}
        self.luts={kind:next(v for k,v in self.params.items() if k.endswith('_'+kind+'_lut')) for kind in ['sigmoid','exp','softmax_exp']}
        self.refs=Counter(i for op in program['operators'] for i in op['inputs'])
        self.stats={'calls':0,'fp64_carrier_matmuls':0,'max_attention_dot_bound':0,'saturation_counts':Counter(),'ranges':{}}
        self.trace={}

    def eval(self):return self

    def parameters(self):return iter(())

    def lut(self,x,kind):
        table=self.luts[kind]
        x=x.to(torch.int64)
        if kind=='softmax_exp':
            z=x.clamp(-16*Q,0)+16*Q
        else:z=x.clamp(-16*Q,16*Q)+16*Q
        index=(z>>8).clamp_max(len(table)-2)
        fraction=z-(index<<8)
        return table[index].to(torch.int64)+rshift((table[index+1].to(torch.int64)-table[index].to(torch.int64))*fraction,8)

    def narrow(self,x,name,dtype='int32'):
        if dtype=='int64':return x.to(torch.int64)
        if bool(((x<-2147483648)|(x>2147483647)).any()):
            self.stats['saturation_counts'][name]+=int(((x<-2147483648)|(x>2147483647)).sum())
            raise OverflowError(f'Q16 INT32 overflow: {name}')
        return x.to(torch.int32)

    def convolution(self,x,a):
        w=self.params[a['weight']];b=self.params[a['bias']]
        st=a['strides'];pad=a['pads'];dil=a['dilations'];groups=a['group']
        if pad[:2]!=pad[2:]:raise NotImplementedError('asymmetric conv padding')
        kh,kw=w.shape[-2:]
        # FP32 unfold only copies integer values/padding, no float arithmetic.
        patches=TF.unfold(x.to(torch.float32),[kh,kw],dilation=dil,padding=pad[:2],stride=st).to(x.dtype)
        oh=(x.shape[-2]+pad[0]+pad[2]-dil[0]*(kh-1)-1)//st[0]+1
        ow=(x.shape[-1]+pad[1]+pad[3]-dil[1]*(kw-1)-1)//st[1]+1
        if groups==x.shape[1] and w.shape[0]==groups:
            raw=(patches.reshape(x.shape[0],groups,kh*kw,-1).to(torch.int64)*w.reshape(1,groups,kh*kw,1).to(torch.int64)).sum(2).transpose(1,2)
        else:
            assert groups==1,'grouped convolution other than depthwise is not in these models'
            raw=int_weight_mm(patches.transpose(1,2),w.flatten(1),a['activation_bits'])
        raw=raw+b[None,None,:]
        out=requant(raw,self.params[a['multiplier']][None,None,:],self.params[a['shift']][None,None,:])
        return out.transpose(1,2).reshape(x.shape[0],w.shape[0],oh,ow)

    def matmul(self,a,b):
        bound=int(a.to(torch.int64).abs().max())*int(b.to(torch.int64).abs().max())*a.shape[-1]
        if bound>=(1<<62):raise OverflowError('attention INT64 dot bound')
        if self.strict_attention:
            out=np.matmul(a.cpu().numpy().astype(np.int64),b.cpu().numpy().astype(np.int64))
            raw=torch.from_numpy(out).to(self.device)
        else:
            if bound>=(1<<53):raise OverflowError('FP64 integer carrier would not be exact')
            raw=torch.matmul(a.to(torch.float64),b.to(torch.float64)).to(torch.int64)
            self.stats['fp64_carrier_matmuls']+=1
        self.stats['max_attention_dot_bound']=max(bound,self.stats['max_attention_dot_bound'])
        return rshift(raw,F)

    def layernorm(self,x,a):
        z=x.to(torch.int64);n=z.shape[-1]
        mean=rdiv(z.sum(-1,keepdim=True),n)
        centered=z-mean
        max_abs=int(centered.abs().max())
        if max_abs*max_abs*n >=(1<<62):raise OverflowError('LayerNorm variance sum bound')
        var=rdiv((centered*centered).sum(-1,keepdim=True),n)
        if int(var.max()) >=(1<<46):raise OverflowError('LayerNorm Q48 bound')
        den=isqrt((var<<16)+a['epsilon_q48']).clamp_min(1)
        normalized=rdiv(centered<<24,den)
        return rshift(normalized*self.params[a['gamma']].to(torch.int64),F)+self.params[a['beta']]

    @torch.inference_mode()
    def run(self,images,trace=False,input_fixed=False):
        if input_fixed:
            inp=torch.as_tensor(images,device=self.device)
            if inp.dtype!=torch.int32:
                raise ValueError('Fixed input must already be INT32 Q16')
        else:
            # The model input boundary is explicitly outside integer execution.
            inp=torch.round(torch.as_tensor(images,device=self.device)*Q).to(torch.int32)
        if list(inp.shape)!=self.program['input_shape']:
            raise ValueError('Input shape differs from the static model contract')
        values={self.program['input']:inp}
        refs=self.refs.copy();self.trace={}
        for index,op in enumerate(self.program['operators']):
            kind=op['op'];a=op['attrs'];names=op['outputs']
            ins=[values[i] if i in values else self.params[i] for i in op['inputs']]
            x=ins[0] if ins else None
            if kind=='QUANT':
                maximum=(1<<(a['bits']-1))-1
                z=requant(x,a['multiplier'],a['shift'])
                out=z.clamp(-maximum,maximum).to(torch.int16 if a['bits']==16 else torch.int8)
            elif kind=='CONV':out=self.convolution(x,a)
            elif kind=='LINEAR':
                raw=int_weight_mm(x,self.params[a['weight']],a['activation_bits'])+self.params[a['bias']]
                out=requant(raw,self.params[a['multiplier']],self.params[a['shift']])
            elif kind=='ADD':out=ins[0].to(torch.int64)+ins[1].to(torch.int64)
            elif kind=='MUL':out=rshift(ins[0].to(torch.int64)*ins[1].to(torch.int64),F)
            elif kind=='MATMUL':out=self.matmul(*ins)
            elif kind=='LAYERNORM':out=self.layernorm(x,a)
            elif kind=='SOFTMAX':
                z=x.to(torch.int64)-x.to(torch.int64).amax(a['axis'],keepdim=True)
                e=self.lut(z,'softmax_exp')
                out=rdiv(e*Q,e.sum(a['axis'],keepdim=True).clamp_min(1))
            elif kind=='SIGMOID':out=self.lut(x,'sigmoid')
            elif kind=='EXP':out=self.lut(x,'exp')
            elif kind=='RELU':out=x.clamp_min(0)
            elif kind=='RESHAPE':out=x.reshape(a['shape'])
            elif kind=='TRANSPOSE':out=x.permute(a['perm'])
            elif kind=='CONCAT':out=torch.cat(ins,dim=a['axis'])
            elif kind=='SLICE':
                ss=[slice(None)]*x.ndim
                for k,b,e,st in zip(a['axes'],a['starts'],a['ends'],a['steps']):ss[k]=slice(b,e,st)
                out=x[tuple(ss)]
            elif kind=='SPLIT':out=list(torch.split(x,a['sizes'],dim=a['axis']))
            elif kind=='EXPAND':out=x.expand(a['shape'])
            elif kind=='RESIZE_NEAREST':
                hh=torch.div(torch.arange(a['shape'][-2],device=x.device)*x.shape[-2],a['shape'][-2],rounding_mode='floor')
                ww=torch.div(torch.arange(a['shape'][-1],device=x.device)*x.shape[-1],a['shape'][-1],rounding_mode='floor')
                out=x[:,:,hh[:,None],ww[None,:]]
            elif kind=='MAXPOOL':
                # Max of copied INT32 values is exact, independent of magnitude.
                pad=a['pads'];kh,kw=a['kernel'];sh,sw=a['strides']
                z=TF.pad(x,(pad[1],pad[3],pad[0],pad[2]),value=-2147483648)
                out=z.unfold(2,kh,sh).unfold(3,kw,sw).amax((-1,-2))
            elif kind=='GAP':out=rdiv(x.to(torch.int64).sum(tuple(range(2,x.ndim)),keepdim=True),math.prod(x.shape[2:]))
            else:raise NotImplementedError(kind)
            outs=out if isinstance(out,list) else [out]
            for n,y in zip(names,outs):
                dtype=self.program['tensors'][n]['dtype']
                if kind!='QUANT':y=self.narrow(y,n,dtype)
                assert list(y.shape)==self.program['tensors'][n]['shape'],(kind,n,y.shape,self.program['tensors'][n]['shape'])
                values[n]=y
                if trace:self.trace[n]=y.detach().cpu().clone()
                if trace or self.stats['calls']==0:
                    self.stats['ranges'][n]=[int(y.min()),int(y.max())]
            for n in op['inputs']:
                refs[n]-=1
                if refs[n]==0 and n!=self.program['output']:values.pop(n,None)
        self.stats['calls']+=1
        return values[self.program['output']]

    def __call__(self,x):return self.run(x).to(torch.float32)/Q


if __name__=='__main__':
    raise SystemExit('This module is an integer-reference library. The historical 640-pixel CLI is disabled in the final 160/256 submission. Use build/scripts/models/verify_models.py or rebuild_runtime_models.py; see docs/model_pipeline.md.')
