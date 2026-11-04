"""Standalone integer interpreter for the preserved 48-op ResNet DDR payload."""
import struct
import numpy as np
import torch
from torch.nn import functional as F


def rne(x,shift):
    if shift==0:return x
    if shift<0:raise ValueError('Negative shifts are absent from this frozen R18 image')
    if shift>=64:return torch.zeros_like(x)
    magnitude=x.abs()
    if shift==63:
        rounded=(magnitude>(1<<62)).to(torch.int64)
    else:
        quotient=magnitude>>shift;mask=(1<<shift)-1;remainder=magnitude&mask;half=1<<(shift-1)
        rounded=quotient+((remainder>half)|((remainder==half)&((quotient&1)!=0))).to(torch.int64)
    return torch.where(x<0,-rounded,rounded)


def execute(memory,layout):
    outputs=[]
    for index,d in enumerate(layout['descriptors']):
        if list(struct.unpack_from('<32I',memory,index*128))!=d:raise ValueError('Legacy descriptor bytes mismatch')
        op,inp,inp2,dst,ih,iw,cin,oh,ow,cout,kh,kw,sh,sw,pt,pl=d[:16]
        x=torch.from_numpy(np.frombuffer(memory,np.int8,count=cin*ih*iw,offset=inp).copy()).reshape(1,cin,ih,iw)
        if op in [1,6]:
            ocb,icb=(cout+15)//16,(cin+7)//8
            raw=np.frombuffer(memory,np.int8,count=ocb*icb*kh*kw*128,offset=d[16]).copy().reshape(ocb,icb,kh,kw,16,8)
            padded=raw.transpose(0,4,1,5,2,3).reshape(ocb*16,icb*8,kh,kw)
            if np.any(padded[cout:]) or np.any(padded[:,cin:]):raise ValueError('Nonzero legacy padding lanes')
            w=torch.from_numpy(padded[:cout,:cin].astype(np.int32))
            dot=F.conv2d(x.to(torch.int32),w,None,(sh,sw),(pt,pl)) if op==1 else x.reshape(1,cin).to(torch.int32)@w.reshape(cout,cin).T
            b=torch.from_numpy(np.frombuffer(memory,'<i4',count=cout,offset=d[17]).astype(np.int64))
            acc=dot.to(torch.int64)+b.reshape([1,cout]+([1,1] if op==1 else []))
            m=np.frombuffer(memory,'<i4',count=cout,offset=d[18]);s=np.frombuffer(memory,'<u4',count=cout,offset=d[19])
            y=torch.empty_like(acc,dtype=torch.int8)
            for c,(mm,ss) in enumerate(zip(m,s)):y[:,c]=rne(acc[:,c]*int(mm),int(ss)).clamp(-128,127).to(torch.int8)
        elif op==2:y=x.clamp_min(0)
        elif op==3:
            z=torch.from_numpy(np.frombuffer(memory,np.int8,count=cin*ih*iw,offset=inp2).copy()).reshape_as(x)
            ma=d[20]+(d[21]<<32);mb=d[22]+(d[23]<<32)
            y=rne(x.to(torch.int64)*ma+z.to(torch.int64)*mb,d[24]).clamp(-128,127).to(torch.int8)
        elif op==4:y=F.max_pool2d(x.to(torch.int32),(kh,kw),(sh,sw),(pt,pl)).to(torch.int8)
        elif op==5:y=rne(x.to(torch.int64).sum((2,3))*d[25],d[26]).clamp(-128,127).to(torch.int8)
        else:raise ValueError(('Unknown legacy opcode',op))
        assert y.numel()==d[27]==cout*oh*ow
        payload=y.numpy().tobytes();memory[dst:dst+len(payload)]=payload;outputs.append((index,payload))
    return outputs
