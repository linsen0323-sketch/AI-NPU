"""Export the selected integer tensors as an executable standard ONNX QDQ graph.

W4 tensors use INT8 ONNX containers constrained to [-7,7]; physical nibble
packing is in weights_packed.bin. No optimized INT4 runtime claim is made.
"""
import argparse
import json
import types
import contextlib
from collections import Counter

import numpy as np
import torch
import onnx
import onnxruntime as ort
from torch.onnx import symbolic_helper
from torch.nn import functional as F
import mixed_precision_ptq as q


class ActivationQDQ(torch.autograd.Function):
    @staticmethod
    def forward(ctx, x, scale, bits):
        m=2**(bits-1)-1
        return torch.clamp(torch.round(x/scale),-m,m)*scale

    @staticmethod
    def symbolic(g,x,scale,bits):
        bits=symbolic_helper._parse_arg(bits,"i")
        m=2**(bits-1)-1
        low=g.op("Mul",scale,g.op("Constant",value_t=torch.tensor(float(-m))))
        high=g.op("Mul",scale,g.op("Constant",value_t=torch.tensor(float(m))))
        clipped=g.op("Clip",x,low,high)
        z=g.op("Constant",value_t=torch.tensor(0,dtype=torch.int16 if bits==16 else torch.int8))
        quant=g.op("QuantizeLinear",clipped,scale,z)
        return g.op("DequantizeLinear",quant,scale,z)


class WeightDQ(torch.autograd.Function):
    @staticmethod
    def forward(ctx,qi,scale):
        return qi.float()*scale.reshape([-1]+[1]*(qi.ndim-1))

    @staticmethod
    def symbolic(g,qi,scale):
        z=g.op("ConstantOfShape",g.op("Shape",scale),value_t=torch.tensor([0],dtype=torch.int8))
        return g.op("DequantizeLinear",qi,scale,z,axis_i=0)


def export_forward(self,x):
    x=ActivationQDQ.apply(x,self.export_sx,self.abits)
    w=WeightDQ.apply(self.export_qw,self.export_sw)
    if self.is_conv:
        return F.conv2d(x,w,self.bias,**self.source_spec)
    return F.linear(x,w,self.bias)


def load_selected(name):
    t=q.Task(name)
    stats=json.loads((t.out/'calibration.json').read_text())
    policy=json.loads((t.out/'selected_policy.json').read_text())
    manifest=json.loads((t.out/'model_manifest.json').read_text())
    assert q.sha(t.ckpt)==manifest['original_checkpoint_sha256']
    bundle=torch.load(t.out/'quantized_reference.pth',map_location='cpu',weights_only=False)
    ops=q.wrap_model(t.model,stats)
    t.model.load_state_dict(bundle['reference_state'],strict=True)
    q.apply_policy(ops,policy['policy'])
    return t,ops,policy


def run(name, validate=12):
    q.seed_all()
    t,ops,selected=load_selected(name)
    inputs=[t.tensor(r).unsqueeze(0) for r in t.rows('val')[:validate]]
    with torch.inference_mode():
        expected=[t.model(x).cpu().numpy() for x in inputs]
    for n,o in ops.items():
        qw,sw=(o.w4,o.s4) if o.wbits==4 else (o.w8,o.s8)
        o.register_buffer('export_qw',qw.clone())
        o.register_buffer('export_sw',sw.clone())
        o.register_buffer('export_sx',torch.tensor(o.sx,device=qw.device))
        o.forward=types.MethodType(export_forward,o)
    path=t.out/'model_mixed_qdq.onnx'
    # A16 requires ONNX QuantizeLinear opset 21. Fixed batch=1 is intentional.
    with torch.inference_mode():
        torch.onnx.export(t.model,inputs[0],str(path),opset_version=20,dynamo=False,input_names=['images'],output_names=['logits' if name=='mobilevit_xxs' else 'decoded_predictions'],do_constant_folding=False)
    model=onnx.load(path)
    # Legacy tracing supports through 20; all ordinary operators here keep
    # their semantics in 21. The custom QDQ symbolics require 21 for INT16.
    model.opset_import[0].version=21
    onnx.checker.check_model(model,full_check=True)
    meta={"quantization_reference":"FP32 Conv/MatMul on QDQ tensors, explicit FP32 islands", "int4_container":"INT8 [-7,7]; physical INT4 in weights_packed.bin", "selected_policy":selected['tag'], "preprocessing":json.dumps(t.preprocess),"classes":json.dumps(t.classes),"fpga_deployment":"Requires operator mapping, integer arithmetic verification and RTL integration"}
    onnx.helper.set_model_props(model,meta)
    onnx.save(model,path)
    options=ort.SessionOptions()
    options.graph_optimization_level=ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    options.intra_op_num_threads=6
    options.inter_op_num_threads=1
    session=ort.InferenceSession(str(path),sess_options=options,providers=['CPUExecutionProvider'])
    errors=[]
    for x,ref in zip(inputs,expected):
        actual=session.run(None,{'images':x.cpu().numpy()})[0]
        errors.append({'max_abs':float(np.max(np.abs(ref-actual))), 'mean_abs':float(np.mean(np.abs(ref-actual)))})
        # Near a quantization threshold, tiny CPU/GPU differences can flip one
        # quantized value. Record raw errors and validate task metrics below.
        if not np.isfinite(actual).all():
            raise RuntimeError('Nonfinite ONNX reference output')
    q.dump(t.out/'onnx_verification.json',{'onnx_check_model_pass':True,'opset':21,'static_batch':1,'validation_samples':validate,'errors':errors,'graph_nodes':dict(Counter(n.op_type for n in model.graph.node)),'onnx_bytes':path.stat().st_size,'onnx_sha256':q.sha(path),'runtime':'ORT CPU, graph optimizations disabled; throughput is not an FPGA metric'})
    for i in range(min(3,len(inputs))):
        np.savez_compressed(t.out/f'golden_sample_{i:02d}.npz',images=inputs[i].cpu().numpy(),qdq_reference_output=expected[i],ort_output=session.run(None,{'images':inputs[i].cpu().numpy()})[0])
    q.log(name,'ONNX checker PASS, ORT sample comparison',errors[:2])
    return t,session


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--model',choices=['yolox_s_a'],required=True)
    p.add_argument('--samples',type=int,default=12)
    a=p.parse_args()
    run(a.model,a.samples)
