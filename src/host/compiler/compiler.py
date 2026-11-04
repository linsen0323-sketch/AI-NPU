"""Compile the frozen QDQ ONNX models to a static integer dataflow program.

No floating weights/scales are needed by the emitted execution program. Scalar
quantization factors become Q31 multipliers and shifts. General vector glue is
signed Q16 (INT32); detector exp/decode uses INT64 Q16 to avoid coordinate range
loss. Conv/Linear inputs retain the selected INT8/INT16 precision.
"""
from __future__ import annotations
import json
import math
from pathlib import Path
from dataclasses import dataclass
import numpy as np
import onnx
from onnx import helper,numpy_helper

F=16
Q=1<<F
REPO=Path(__file__).resolve().parents[3]
PTQ=REPO/"data/models/quantization"
ART=REPO/"work/integer_compiler"


def jsdump(p,obj):
    p=Path(p);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,indent=2,ensure_ascii=False),encoding='utf-8')


def multiplier(real):
    a=np.asarray(real,dtype=np.float64)
    mant,exp=np.frexp(a)
    m=np.rint(mant*(1<<31)).astype(np.int64)
    exp=exp+(m==(1<<31));m=np.where(m==(1<<31),m//2,m)
    shift=31-exp
    if np.any(shift<0) or np.any(shift>62):
        raise ValueError(f'multiplier shift outside contract: {shift}')
    return m.astype(np.int32),shift.astype(np.int32)


def attrs(node):
    d={a.name:helper.get_attribute_value(a) for a in node.attribute}
    return {k:(v.decode() if isinstance(v,bytes) else v) for k,v in d.items()}


def axes(a,rank):
    return tuple(int(v)%rank for v in np.asarray(a).reshape(-1))


def reshape_shape(shape,target):
    out=[shape[i] if int(d)==0 else int(d) for i,d in enumerate(target)]
    if -1 in out:
        k=out.index(-1);out[k]=math.prod(shape)//math.prod(d for d in out if d!=-1)
    assert math.prod(out)==math.prod(shape),(shape,out)
    return tuple(out)


def const_eval(op,values,a):
    x=values[0] if values else None
    if op=='Identity':return [x]
    if op=='Constant':return [numpy_helper.to_array(a['value'])]
    if op=='ConstantOfShape':return [np.full(tuple(x),numpy_helper.to_array(a['value']).reshape(-1)[0],dtype=numpy_helper.to_array(a['value']).dtype)]
    if op=='Concat':return [np.concatenate(values,axis=a.get('axis',0))]
    if op=='Add':return [values[0]+values[1]]
    if op=='Mul':return [values[0]*values[1]]
    if op=='Div':return [values[0]/values[1]]
    if op=='Reshape':return [x.reshape(reshape_shape(x.shape,values[1].reshape(-1)))]
    if op=='Transpose':return [x.transpose(a.get('perm',tuple(reversed(range(x.ndim)))))]
    if op=='Unsqueeze':
        rank=x.ndim+np.asarray(values[1]).size
        out=x
        for axis in sorted(axes(values[1],rank)):out=np.expand_dims(out,axis)
        return [out]
    if op=='Squeeze':return [np.squeeze(x,axis=axes(values[1],x.ndim) if len(values)>1 else None)]
    if op=='Expand':return [np.broadcast_to(x,tuple(values[1])).copy()]
    if op=='Cast':return [x.astype(helper.tensor_dtype_to_np_dtype(a['to']))]
    if op=='DequantizeLinear':
        scale=values[1];zero=values[2] if len(values)>2 else np.asarray(0,dtype=x.dtype)
        if scale.ndim:
            shape=[1]*x.ndim;shape[a.get('axis',1)]=len(scale);scale=scale.reshape(shape);zero=np.broadcast_to(zero,values[1].shape).reshape(shape)
        return [(x.astype(np.float32)-zero)*scale]
    if op=='Slice':
        ss=[slice(None)]*x.ndim
        starts,ends=values[1:3];aa=values[3] if len(values)>3 else np.arange(len(starts));steps=values[4] if len(values)>4 else np.ones_like(starts)
        for k,b,e,s in zip(aa,starts,ends,steps):ss[int(k)]=slice(int(b),int(e),int(s))
        return [x[tuple(ss)]]
    if op=='Shape':return [np.asarray(x.shape,dtype=np.int64)]
    raise NotImplementedError(('constant',op))


def infer(op,ss,a,c,nout):
    s=ss[0]
    if op in ['Identity','QuantizeLinear','DequantizeLinear','Clip','Sigmoid','Exp','LayerNormalization','Relu','Softmax']:
        return [s]*nout
    if op in ['Add','Mul','Div']:
        return [np.broadcast_shapes(*ss)]
    if op=='Conv':
        w=ss[1];st=a.get('strides',[1,1]);pad=a.get('pads',[0]*4);dil=a.get('dilations',[1,1])
        return [(s[0],w[0],*((s[i+2]+pad[i]+pad[i+2]-dil[i]*(w[i+2]-1)-1)//st[i]+1 for i in range(2)))]
    if op=='MatMul':return [(*np.broadcast_shapes(s[:-2],ss[1][:-2]),s[-2],ss[1][-1])]
    if op=='Gemm':return [(s[0] if not a.get('transA',0) else s[1],ss[1][0] if a.get('transB',0) else ss[1][1])]
    if op=='MaxPool':
        st=a.get('strides',[1,1]);pad=a.get('pads',[0]*4);k=a['kernel_shape']
        return [(s[0],s[1],*((s[i+2]+pad[i]+pad[i+2]-k[i])//st[i]+1 for i in range(2)))]
    if op=='GlobalAveragePool':return [(*s[:2],*[1]*(len(s)-2))]
    if op=='Reshape':return [reshape_shape(s,c[1].reshape(-1))]
    if op=='Flatten':
        k=a.get('axis',1);return [(math.prod(s[:k]),math.prod(s[k:]))]
    if op=='Transpose':return [tuple(s[i] for i in a.get('perm',list(reversed(range(len(s))))))]
    if op=='Concat':
        k=a.get('axis',0);o=list(s);o[k]=sum(x[k] for x in ss);return [tuple(o)]
    if op=='Slice':
        o=list(s);aa=c[3] if len(c)>3 else np.arange(len(c[1]));step=c[4] if len(c)>4 else np.ones_like(c[1])
        for k,b,e,st in zip(aa,c[1],c[2],step):o[int(k)]=len(range(*slice(int(b),int(e),int(st)).indices(s[int(k)])))
        return [tuple(o)]
    if op=='Unsqueeze':
        rank=len(s)+c[1].size;aa=set(axes(c[1],rank));it=iter(s);return [tuple(1 if i in aa else next(it) for i in range(rank))]
    if op=='Squeeze':
        aa=set(axes(c[1],len(s))) if len(c)>1 else {i for i,d in enumerate(s) if d==1}
        return [tuple(d for i,d in enumerate(s) if i not in aa)]
    if op=='Split':
        k=a.get('axis',0)%len(s);sizes=c[1] if len(c)>1 else a.get('split',[s[k]//nout]*nout)
        return [tuple(int(v) if i==k else d for i,d in enumerate(s)) for v in sizes]
    if op=='Expand':return [tuple(c[1])]
    if op=='Resize':
        return [tuple(c[3]) if len(c)>3 and c[3] is not None else tuple(int(d*float(v)) for d,v in zip(s,c[2]))]
    raise NotImplementedError(('shape',op,ss))


@dataclass
class Quant:
    source:str
    scale:np.ndarray
    bits:int
    axis:int=0
    perm:tuple|None=None


class Compiler:
    def __init__(self,name):
        self.name=name
        self.source_dir=PTQ/("neu6" if name=="yolox_s_a" else name)
        candidate=self.source_dir/"model_mixed_qdq.onnx"
        self.model=onnx.load(candidate if candidate.is_file() else REPO/"data/models/onnx"/("yolox_s_neu6_qdq.onnx" if name=="yolox_s_a" else "yolox_s_coco80_qdq.onnx"))
        self.nodes=list(self.model.graph.node)
        self.prod={o:n for n in self.nodes for o in n.output}
        self.const={t.name:numpy_helper.to_array(t) for t in self.model.graph.initializer}
        self.shapes={k:v.shape for k,v in self.const.items()}
        self.output=self.model.graph.output[0].name
        self.input=self.model.graph.input[0].name
        self.shapes[self.input]=tuple(d.dim_value for d in self.model.graph.input[0].type.tensor_type.shape.dim)
        self.spec={self.input:{'shape':list(self.shapes[self.input]),'dtype':'int32','fractional_bits':F}}
        self.ops=[];self.params={};self.alias={};self.quant={};self.parameter_number=0

    def resolve(self,name):
        while name in self.alias:name=self.alias[name]
        return name

    def param(self,name,value,dtype=None):
        key=f'p{self.parameter_number:04d}_{name}'
        self.parameter_number+=1
        ar=np.ascontiguousarray(np.asarray(value,dtype=dtype))
        if ar.dtype.kind=='f':raise TypeError(('float runtime parameter',key))
        self.params[key]=ar
        return key

    def pfix(self,name,value):return self.param(name,np.rint(np.asarray(value,dtype=np.float64)*Q),'int32')

    def emit(self,op,inputs,outputs,a=None,dtype='int32'):
        outputs=list(outputs);inputs=[self.resolve(n) for n in inputs]
        self.ops.append({'op':op,'inputs':inputs,'outputs':outputs,'attrs':a or {}})
        for n in outputs:self.spec[n]={'shape':list(self.shapes[n]),'dtype':dtype,'fractional_bits':F if dtype in ['int32','int64'] else 0}

    def weight(self,name):
        n=self.prod.get(name)
        if n is not None and n.op_type=='Transpose':
            q=self.weight(n.input[0]);q.perm=tuple(attrs(n).get('perm',[1,0]));return q
        if n is not None and n.op_type=='DequantizeLinear' and n.input[0] in self.const:
            return Quant(n.input[0],np.asarray(self.const[n.input[1]]),8,attrs(n).get('axis',1))
        raise ValueError(('not a quantized weight',name))

    def compile(self):
        for n in self.nodes:
            op=n.op_type;a=attrs(n);ins=list(n.input);out=list(n.output)
            c=[self.const.get(i) if i else None for i in ins]
            ss=[self.shapes.get(i,()) for i in ins]
            if op=='Shape':
                vals=[np.asarray(ss[0],dtype=np.int64)]
            elif op=='Constant' or all(not i or i in self.const for i in ins):
                vals=const_eval(op,c,a)
            else:vals=None
            if vals is not None:
                for k,v in zip(out,vals):self.const[k]=v;self.shapes[k]=v.shape
                continue
            inferred=infer(op,ss,a,c,len(out))
            for k,s in zip(out,inferred):self.shapes[k]=s
            if op=='Identity':self.alias[out[0]]=self.resolve(ins[0]);continue
            if op=='Clip':
                # Generated clips only implement the symmetric narrow range
                # directly in front of QLinear. The Q op enforces it exactly.
                uses=[v for v in self.nodes if ins and out[0] in v.input]
                if not all(v.op_type=='QuantizeLinear' for v in uses):raise ValueError('unfused Clip')
                self.alias[out[0]]=self.resolve(ins[0]);continue
            if op=='QuantizeLinear':
                scale=float(np.asarray(c[1]));z=np.asarray(c[2]);bits=16 if z.dtype==np.int16 else 8
                assert int(z)==0
                m,s=multiplier(1/(scale*Q))
                self.emit('QUANT',[ins[0]],out,{'multiplier':int(m),'shift':int(s),'bits':bits},'int16' if bits==16 else 'int8')
                self.quant[out[0]]=Quant(out[0],np.asarray(scale),bits)
                continue
            if op=='DequantizeLinear':
                self.alias[out[0]]=self.resolve(ins[0]);self.quant[out[0]]=self.quant[self.resolve(ins[0])];continue
            if op in ['Conv','MatMul','Gemm'] and ins[1] in self.const:
                qw=self.weight(ins[1]);qi=self.const[qw.source]
                # Conv uses OIHW. Dense stores OC,IC regardless of ONNX transpose.
                if op=='MatMul':
                    w=qi if qw.perm==(1,0) else qi.T
                elif op=='Gemm':w=qi if a.get('transB',0) else qi.T
                else:w=qi
                qx=self.quant.get(ins[0],self.quant.get(self.resolve(ins[0])))
                if qx is None:raise ValueError(('weight op without activation quant',n.name,ins[0]))
                sx=float(qx.scale);sw=np.asarray(qw.scale).reshape(-1)
                bias=np.asarray(c[2]) if len(c)>2 and c[2] is not None else np.zeros(len(sw),dtype=np.float32)
                bi=np.rint(bias/(sx*sw)).astype(np.int64)
                assert np.max(np.abs(bi))<=2147483647
                m,s=multiplier(sx*sw*Q)
                d={'weight':self.param('weight',w,'int8'),'bias':self.param('bias',bi,'int32'),'multiplier':self.param('requant_m',m),'shift':self.param('requant_s',s),'activation_bits':qx.bits}
                if op=='Conv':d.update({'strides':a.get('strides',[1,1]),'pads':a.get('pads',[0]*4),'dilations':a.get('dilations',[1,1]),'group':a.get('group',1)})
                self.emit('CONV' if op=='Conv' else 'LINEAR',[ins[0]],out,d)
                continue
            if op in ['Add','Mul']:
                inputs=[]
                for i,v in zip(ins,c):
                    if v is not None:
                        key=self.pfix('constant',v);self.shapes[key]=v.shape;self.spec[key]={'shape':list(v.shape),'dtype':'int32','fractional_bits':F,'constant':True};inputs.append(key)
                    else:inputs.append(i)
                dtype='int64' if any(self.spec[self.resolve(i)]['dtype']=='int64' for i in inputs) else 'int32'
                self.emit(op.upper(),inputs,out,dtype=dtype);continue
            if op=='MatMul':self.emit('MATMUL',ins,out);continue
            if op=='LayerNormalization':
                assert a.get('axis',-1)==-1 and len(out)==1
                self.emit('LAYERNORM',[ins[0]],out,{'gamma':self.pfix('gamma',c[1]),'beta':self.pfix('beta',c[2]),'epsilon_q48':int(round(a.get('epsilon',1e-5)*(1<<48)))})
                continue
            if op=='Softmax':self.emit('SOFTMAX',ins,out,{'axis':a.get('axis',-1)});continue
            if op in ['Sigmoid','Exp','Relu']:
                self.emit(op.upper(),ins,out,dtype='int64' if op=='Exp' else 'int32');continue
            if op=='MaxPool':self.emit('MAXPOOL',[ins[0]],out,{'kernel':a['kernel_shape'],'strides':a.get('strides',[1,1]),'pads':a.get('pads',[0]*4)});continue
            if op=='GlobalAveragePool':self.emit('GAP',ins,out);continue
            if op in ['Reshape','Flatten','Unsqueeze','Squeeze']:
                self.emit('RESHAPE',[ins[0]],out,{'shape':list(self.shapes[out[0]])},self.spec[self.resolve(ins[0])]['dtype']);continue
            if op=='Transpose':self.emit('TRANSPOSE',[ins[0]],out,{'perm':a.get('perm',list(reversed(range(len(ss[0])))))});continue
            if op=='Concat':
                dtype='int64' if any(self.spec[self.resolve(i)]['dtype']=='int64' for i in ins) else 'int32'
                self.emit('CONCAT',ins,out,{'axis':a.get('axis',0)},dtype);continue
            if op=='Slice':
                aa=c[3] if len(c)>3 else np.arange(len(c[1]));step=c[4] if len(c)>4 else np.ones_like(c[1])
                self.emit('SLICE',[ins[0]],out,{'starts':c[1].tolist(),'ends':c[2].tolist(),'axes':aa.tolist(),'steps':step.tolist()},self.spec[self.resolve(ins[0])]['dtype']);continue
            if op=='Split':self.emit('SPLIT',[ins[0]],out,{'axis':a.get('axis',0),'sizes':c[1].tolist() if len(c)>1 else [self.shapes[o][a.get('axis',0)] for o in out]});continue
            if op=='Resize':
                assert a.get('mode')=='nearest' and a.get('coordinate_transformation_mode')=='asymmetric' and a.get('nearest_mode')=='floor'
                self.emit('RESIZE_NEAREST',[ins[0]],out,{'shape':list(self.shapes[out[0]])});continue
            if op=='Expand':self.emit('EXPAND',[ins[0]],out,{'shape':list(self.shapes[out[0]])});continue
            if op=='Cast':self.alias[out[0]]=self.resolve(ins[0]);continue
            raise NotImplementedError(('dynamic',op,n.name))
        output=self.resolve(self.output)
        # Prune computational branches/metadata not needed by graph output.
        needed={output};kept=[]
        for op in reversed(self.ops):
            if needed.intersection(op['outputs']):kept.append(op);needed.update(op['inputs'])
        self.ops=list(reversed(kept))
        used=set([self.input,output])
        used.update(i for op in self.ops for i in op['inputs']+op['outputs'])
        spec={k:v for k,v in self.spec.items() if k in used}
        # LUT values are generated offline, runtime evaluation is integer-only.
        grid=np.arange(-4096,4097,dtype=np.float64)/256
        self.param('sigmoid_lut',np.rint((1/(1+np.exp(-grid)))*Q),'int32')
        self.param('exp_lut',np.rint(np.exp(grid)*Q),'int64')
        self.param('softmax_exp_lut',np.rint(np.exp(np.arange(-4096,1)/256)*(1<<30)),'int32')
        if self.name=='mobilevit_xxs':
            # Match the frozen calibration/evaluation GPU float32 reciprocal
            # normalization exactly, including halfway Q16 rounding cases.
            pixel_lut=np.rint(np.arange(256,dtype=np.float32)*np.float32(1/255)*np.float32(Q)).astype(np.int32)
            input_conversion={'kind':'u8_rgb_pixel_lut_after_resize','lookup':self.param('input_pixel_q16_lut',pixel_lut),'reciprocal_float32_bits':'0x3B808081'}
        else:input_conversion={'kind':'u8_bgr_left_top_letterbox_114_then_shift16'}
        source=json.loads((self.source_dir/'model_manifest.json').read_text(encoding='utf-8'))
        program={'format':'AIGRAPH_INTEGER_V1','name':self.name,'fractional_bits':F,'input':self.input,'output':output,'tensors':spec,'operators':self.ops,'input_shape':list(self.shapes[self.input]),'output_shape':list(self.shapes[output]),'integer_only_execution':True,'shape_policy':'static batch=1','narrow_quant_ranges':True,'exp_clamp_q16':[-16*Q,16*Q],'preprocessing':source['preprocessing'],'classes':source['classes'],'original_checkpoint_sha256':source['original_checkpoint_sha256']}
        program['input_conversion']=input_conversion
        out=ART/self.name;out.mkdir(parents=True,exist_ok=True)
        jsdump(out/'program.json',program)
        np.savez(out/'parameters.npz',**self.params)
        return program,self.params


if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('--model',choices=['mobilevit_xxs','yolox_s_a'],required=True)
    c=Compiler(p.parse_args().model);program,params=c.compile()
    from provenance import write_report
    source=PTQ/('neu6' if program['name']=='yolox_s_a' else program['name']);out=ART/program['name']
    write_report(out/'compile_manifest.json',{'model':program['name'],'compiled':True},
                 [source/n for n in ['model_manifest.json','selected_policy.json']]
                 +[out/'program.json',out/'parameters.npz'])
    from collections import Counter
    print(program['name'],len(program['operators']),dict(Counter(o['op'] for o in program['operators'])),len(params))
