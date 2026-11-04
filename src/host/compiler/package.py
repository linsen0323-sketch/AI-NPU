"""Relocatable AIPKG3 DDR images, binary descriptors, verifier and loader output."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import struct
import zlib
from pathlib import Path
import numpy as np
from compiler import ART,jsdump

MAGIC=b'AIPKG3\0\0'
HEADER=struct.Struct('<8s6I2Q4I')
DIRECTORY=struct.Struct('<16sQQII24s')
ALIGN=4096
DTYPES={'int8':1,'int16':2,'int32':3,'int64':4}
OPS={name:i+1 for i,name in enumerate(['QUANT','CONV','LINEAR','ADD','MUL','MATMUL','LAYERNORM','SOFTMAX','SIGMOID','EXP','RELU','RESHAPE','TRANSPOSE','CONCAT','SLICE','SPLIT','EXPAND','RESIZE_NEAREST','MAXPOOL','GAP'])}
ATTRS={name:i+1 for i,name in enumerate(['multiplier','shift','bits','weight','bias','activation_bits','strides','pads','dilations','group','gamma','beta','epsilon_q48','axis','shape','perm','starts','ends','axes','steps','sizes','kernel'])}
LEGACY=Path(__file__).resolve().parents[3]/"data/models/intermediate/resnet18_legacy_image"


def align(n,a=64):return (n+a-1)//a*a


def sha(data):return hashlib.sha256(data).hexdigest()


def plan(program,parameters):
    specs=program['tensors'];ops=program['operators'];ids={n:i for i,n in enumerate([*parameters,*[n for n in specs if n not in parameters]])}
    birth={program['input']:-1};last={program['input']:-1}
    for i,o in enumerate(ops):
        for n in o['outputs']:birth[n]=i;last.setdefault(n,i)
        for n in o['inputs']:last[n]=i
    last[program['output']]=len(ops)
    allocation={};free=[];active=[];high=0
    for n in sorted(birth,key=lambda n:(birth[n],ids[n])):
        step=birth[n]
        still=[]
        for end,offset,size in active:
            if end<step:free.append((offset,size))
            else:still.append((end,offset,size))
        active=still
        # Coalesce adjacent free ranges.
        coalesced=[]
        for off,size in sorted(free):
            if coalesced and coalesced[-1][0]+coalesced[-1][1]==off:
                p,s=coalesced[-1];coalesced[-1]=(p,s+size)
            else:coalesced.append((off,size))
        free=coalesced
        size=align(math.prod(specs[n]['shape'])*np.dtype(specs[n]['dtype']).itemsize)
        suitable=next((j for j,(_,s) in enumerate(free) if s>=size),None)
        if suitable is None:off=align(high);high=off+size
        else:
            off,available=free.pop(suitable)
            if available>size:free.append((off+size,available-size))
        allocation[n]={'offset':off,'bytes':size,'first_op':birth[n],'last_op':last[n]}
        active.append((last[n],off,size))
    # A separate O(N^2) lifetime/range check catches allocator mistakes.
    names=list(allocation)
    for i,n in enumerate(names):
        a=allocation[n]
        for nn in names[i+1:]:
            b=allocation[nn]
            if max(a['first_op'],b['first_op'])<=min(a['last_op'],b['last_op']):
                assert a['offset']+a['bytes']<=b['offset'] or b['offset']+b['bytes']<=a['offset'],(n,nn)
    return ids,allocation,align(high,4096)


def encode_graph(program,parameters):
    ids,allocation,workspace=plan(program,parameters)
    constants=bytearray();param_layout={}
    for name,arr in parameters.items():
        arr=np.asarray(arr);assert arr.dtype.kind in 'iu'
        arr=arr.astype(arr.dtype.newbyteorder('<'))
        constants.extend(bytes(align(len(constants))-len(constants)))
        param_layout[name]={'offset':len(constants),'bytes':arr.nbytes,'shape':list(arr.shape),'dtype':str(arr.dtype)}
        constants.extend(arr.tobytes())
    tbuf=bytearray()
    for name,tid in sorted(ids.items(),key=lambda x:x[1]):
        const=name in parameters
        spec=param_layout[name] if const else program['tensors'][name]
        region=param_layout[name] if const else allocation[name]
        offset=region['offset'];nb=region['bytes'] if const else math.prod(spec['shape'])*np.dtype(spec['dtype']).itemsize
        shape=spec['shape'];assert len(shape)<=8
        words=[tid,int(const),DTYPES[spec['dtype']],0 if const else spec['fractional_bits'],len(shape),1 if const else 0,offset&0xffffffff,offset>>32,nb&0xffffffff,nb>>32,0xffffffff if const else region['first_op']&0xffffffff,0xffffffff if const else region['last_op'],*shape,*([0]*(8-len(shape))),64]
        words+= [0]*(32-len(words));tbuf.extend(struct.pack('<32I',*words))
    attrs_data=bytearray();instructions=bytearray()
    for op in program['operators']:
        entries=[];vectors=bytearray();ordered=sorted(op['attrs'].items(),key=lambda kv:ATTRS[kv[0]])
        start=len(attrs_data);vector_base=start+16*len(ordered)
        for name,value in ordered:
            if isinstance(value,str):kind=2;count=1;data=ids[value]
            elif isinstance(value,list):
                kind=3;count=len(value);data=vector_base+len(vectors)
                vectors.extend(struct.pack('<'+'q'*count,*[int(v) for v in value]))
            else:kind=1;count=1;data=int(value)
            entries.append(struct.pack('<IHHq',ATTRS[name],kind,count,data))
        attrs_data.extend(b''.join(entries)+vectors)
        length=len(attrs_data)-start
        attrs_data.extend(bytes(align(len(attrs_data),16)-len(attrs_data)))
        ii=[ids[i] for i in op['inputs']];oo=[ids[i] for i in op['outputs']]
        assert len(ii)<=4 and len(oo)<=4
        words=[OPS[op['op']],0,len(ii),len(oo),*(ii+[0xffffffff]*(4-len(ii))),*(oo+[0xffffffff]*(4-len(oo))),start,length,math.prod(program['tensors'][op['outputs'][0]]['shape']),0]
        words+=[0]*(32-len(words));instructions.extend(struct.pack('<32I',*words))
    meta={'program':program,'tensor_ids':ids,'parameters':param_layout,'workspace_plan':allocation,'workspace_bytes':workspace,'opcode_registry':OPS,'attribute_registry':ATTRS,'numeric_contract':{'fixed_fractional_bits':16,'fixed_vector':'INT32 Q16; exp/decode INT64 Q16','activation':'signed narrow INT8/INT16 per QUANT descriptor','rounding':'RNE ties-to-even','bias_accumulator':'INT32 biases, exact INT64 golden accumulations, requant operand limited INT32','softmax':'exp-negative LUT Q30, integer normalization to Q16','layernorm':'integer mean, population variance, integer sqrt Q24 with epsilon Q48'}}
    sections={'META':json.dumps(meta,ensure_ascii=False,separators=(',',':')).encode('utf-8'),'TENSORS':bytes(tbuf),'INSTRUCTIONS':bytes(instructions),'ATTRIBUTES':bytes(attrs_data),'CONSTANTS':bytes(constants)}
    return sections,meta,ids[program['input']],ids[program['output']],workspace


def assemble(model_id,profile,sections,workspace,input_id,output_id,input_lut_id=0xffffffff):
    offset=align(256+64*len(sections),ALIGN);entries=[];parts=[]
    for name,data in sections.items():
        entries.append(DIRECTORY.pack(name.encode().ljust(16,b'\0'),offset,len(data),zlib.crc32(data)&0xffffffff,ALIGN,bytes(24)))
        parts.append((offset,data));offset=align(offset+len(data),ALIGN)
    directory=b''.join(entries)
    blob=bytearray(offset);blob[256:256+len(directory)]=directory
    for off,data in parts:blob[off:off+len(data)]=data
    body_crc=zlib.crc32(blob[256:])&0xffffffff
    header=HEADER.pack(MAGIC,3,256,model_id,profile,len(sections),zlib.crc32(directory)&0xffffffff,offset,workspace,input_id,output_id,0,0)+struct.pack('<II',body_crc,input_lut_id)+bytes(184)
    crc=zlib.crc32(header)&0xffffffff
    header=header[:56]+struct.pack('<I',crc)+header[60:]
    blob[:256]=header
    return bytes(blob)


def parse(data):
    if len(data)<256:raise ValueError('short package')
    h=HEADER.unpack_from(data)
    magic,ver,hlen,mid,profile,count,dcrc,total,workspace,iid,oid,hcrc,flags=h
    if magic!=MAGIC or ver!=3 or hlen!=256 or total!=len(data):raise ValueError('invalid header/version/length')
    head=data[:56]+bytes(4)+data[60:256]
    if zlib.crc32(head)&0xffffffff!=hcrc:raise ValueError('header CRC mismatch')
    if zlib.crc32(data[256:])&0xffffffff!=struct.unpack_from('<I',data,64)[0]:raise ValueError('whole body CRC mismatch')
    directory=data[256:256+count*64]
    if len(directory)!=count*64 or zlib.crc32(directory)&0xffffffff!=dcrc:raise ValueError('directory CRC mismatch')
    sections={};ranges=[]
    for i in range(count):
        name,off,n,crc,alignment,_=DIRECTORY.unpack_from(directory,i*64);name=name.rstrip(b'\0').decode('ascii')
        if off%ALIGN or off<align(256+count*64,ALIGN) or off+n>len(data) or name in sections:raise ValueError('invalid section bounds')
        if any(max(off,a)<min(off+n,b) for a,b in ranges):raise ValueError('overlapping sections')
        raw=data[off:off+n]
        if zlib.crc32(raw)&0xffffffff!=crc:raise ValueError(f'section CRC mismatch: {name}')
        ranges.append((off,off+n));sections[name]=raw
    meta=json.loads(sections['META'])
    return {'model_id':mid,'profile':profile,'workspace_bytes':workspace,'input_id':iid,'output_id':oid,'input_lut_id':struct.unpack_from('<I',data,68)[0],'sections':sections,'meta':meta,'crc32':zlib.crc32(data)&0xffffffff,'sha256':sha(data)}


def load_program(path):
    parsed=parse(Path(path).read_bytes())
    if parsed['profile']!=2:raise ValueError('package uses preserved ResNet ABI1 engine profile')
    meta=parsed['meta'];raw=parsed['sections']['CONSTANTS'];params={}
    for name,p in meta['parameters'].items():
        params[name]=np.frombuffer(raw[p['offset']:p['offset']+p['bytes']],dtype=np.dtype(p['dtype']).newbyteorder('<')).reshape(p['shape']).copy()
    # Reconstruct from the binary instructions and attribute TLV, not META ops.
    inv_ids={i:n for n,i in meta['tensor_ids'].items()};inv_ops={i:n for n,i in OPS.items()};inv_attr={i:n for n,i in ATTRS.items()}
    tb=parsed['sections']['TENSORS']
    if len(tb)!=len(inv_ids)*128:raise ValueError('tensor table length mismatch')
    for off in range(0,len(tb),128):
        w=struct.unpack_from('<32I',tb,off);name=inv_ids[w[0]]
        const=bool(w[1]);spec=meta['parameters'][name] if const else meta['program']['tensors'][name]
        region=meta['parameters'][name] if const else meta['workspace_plan'][name]
        if w[2]!=DTYPES[spec['dtype']] or w[4]!=len(spec['shape']) or list(w[12:12+w[4]])!=spec['shape']:raise ValueError('binary tensor schema mismatch')
        if (w[6]|(w[7]<<32))!=region['offset'] or (w[8]|(w[9]<<32))!=math.prod(spec['shape'])*np.dtype(spec['dtype']).itemsize:raise ValueError('binary tensor address mismatch')
        if region['offset']%64:raise ValueError('unaligned tensor')
    ab=parsed['sections']['ATTRIBUTES'];ib=parsed['sections']['INSTRUCTIONS'];ops=[]
    if len(ib)%128:raise ValueError('instruction table length mismatch')
    for pos in range(0,len(ib),128):
        w=struct.unpack_from('<32I',ib,pos);a={};begin,nbytes=w[12:14]
        if w[2]>4 or not 1<=w[3]<=4 or begin+nbytes>len(ab):raise ValueError('invalid instruction bounds')
        # The smallest referenced vector offset delimits fixed TLV records.
        cursor=begin;records_end=begin+nbytes
        while cursor+16<=records_end:
            aid,kind,count,value=struct.unpack_from('<IHHq',ab,cursor)
            if aid not in inv_attr or kind not in [1,2,3]:raise ValueError('invalid binary attribute')
            if kind==1:v=value
            elif kind==2:v=inv_ids[value]
            else:
                records_end=min(records_end,value)
                v=list(struct.unpack_from('<'+'q'*count,ab,value))
            a[inv_attr[aid]]=v;cursor+=16
        ops.append({'op':inv_ops[w[0]],'inputs':[inv_ids[i] for i in w[4:4+w[2]]],'outputs':[inv_ids[i] for i in w[8:8+w[3]]],'attrs':a})
    p=dict(meta['program']);p['operators']=ops
    if p['operators']!=meta['program']['operators']:raise ValueError('binary descriptor differs from metadata')
    return p,params,parsed


def write_loader(out,name,image,workspace):
    crc=zlib.crc32(image)&0xffffffff
    script=f'''# Source in XSDB AFTER PS DDR initialization and stopping the selected CPU.
# Offline model staging only. Never writes MODEL_READY or FPGA registers.
# Caller must supply reserved ranges; these are not guessed from board type.
foreach var {{AI_MODEL_BASE AI_WORKSPACE_BASE AI_DDR_BEGIN AI_DDR_END AI_RESERVED_BEGIN AI_RESERVED_END AI_DDR_EXCLUSIVE}} {{
    if {{![info exists ::$var]}} {{ error "Set $var before loading" }}
}}
if {{$::AI_DDR_EXCLUSIVE!=1}} {{ error "Model/workspace regions must be reserved from CPU, DMA and Linux" }}
set image [file join [file dirname [info script]] model.aipkg]
set length {len(image)}
set workbytes {workspace}
set cpu_state [state]
if {{$cpu_state ne "Stopped" && ![string match "Stopped: (*)" $cpu_state]}} {{error "Stop the selected Cortex-A9 before loading; no reset is issued here"}}
if {{$::AI_MODEL_BASE%4096 || $::AI_WORKSPACE_BASE%4096}} {{error "DDR bases must be 4096-byte aligned"}}
foreach {{begin end}} [list $::AI_MODEL_BASE [expr {{$::AI_MODEL_BASE+$length}}] $::AI_WORKSPACE_BASE [expr {{$::AI_WORKSPACE_BASE+$workbytes}}]] {{
    if {{$begin<$::AI_DDR_BEGIN || $end>$::AI_DDR_END || $begin<$::AI_RESERVED_BEGIN || $end>$::AI_RESERVED_END || $end<=$begin}} {{error "Range outside configured DDR/reservation"}}
}}
if {{max($::AI_MODEL_BASE,$::AI_WORKSPACE_BASE)<min($::AI_MODEL_BASE+$length,$::AI_WORKSPACE_BASE+$workbytes)}} {{error "Model and workspace overlap"}}
set f [open $image rb]
try {{set local [read $f]}} finally {{close $f}}
if {{[string length $local]!=$length || ([zlib crc32 $local]&0xffffffff)!=0x{crc:08X}}} {{error "Local image mismatch"}}
dow -data $image $::AI_MODEL_BASE
set crc 0
for {{set off 0}} {{$off<$length}} {{incr off $n}} {{
    set n [expr {{min(65536,$length-$off)}}]
    set data [mrd -size w -bin [expr {{$::AI_MODEL_BASE+$off}}] [expr {{$n/4}}]]
    if {{[string length $data]!=$n}} {{error "Short DDR read"}}
    set crc [zlib crc32 $data $crc]
    if {{($off+$n)%1048576==0 || $off+$n==$length}} {{puts "DDR verify: [expr {{$off+$n}}] / $length"}}
}}
if {{($crc&0xffffffff)!=0x{crc:08X}}} {{error "DDR CRC mismatch; nothing activated"}}
puts "{name} AIPKG3 staged and DDR CRC verified. No inference enabled."
puts "This package requires the future matching AIPKG3 runtime; do not feed it to the current ResNet ABI2 loader."
'''
    (out/'load_ddr.tcl').write_text(script,encoding='ascii')


def build(name):
    out=ART/name;out.mkdir(parents=True,exist_ok=True)
    if name=='resnet18':
        legacy=(LEGACY/'ddr.bin').read_bytes();layout=json.loads((LEGACY/'layout.json').read_text())
        acceptance=json.loads((LEGACY/'export_validation.json').read_text());assert acceptance['all_pass']
        meta={'format':'AIPKG3_LEGACY_R18','name':name,'engine_profile':'preserved ResNet descriptor ABI1','legacy_payload_sha256':sha(legacy),'legacy_payload_crc32':zlib.crc32(legacy)&0xffffffff,'layout':layout,'legacy_export_validation':acceptance,'preserved_payload_bytes':len(legacy),'input_offset':layout['input_offset'],'output_offset':layout.get('output_offset'),'runtime_float_tensors':False,'source':'Unchanged project-local board-validated ResNet export; no requantization or retraining'}
        sections={'META':json.dumps(meta,ensure_ascii=False,separators=(',',':')).encode(),'LEGACY_IMAGE':legacy}
        workspace=align(len(legacy),4096);image=assemble(1,1,sections,workspace,0xffffffff,0xffffffff)
    else:
        program=json.loads((out/'program.json').read_text());parameters=dict(np.load(out/'parameters.npz'))
        sections,meta,iid,oid,workspace=encode_graph(program,parameters)
        lookup=program.get('input_conversion',{}).get('lookup')
        image=assemble(2 if name=='mobilevit_xxs' else 3,2,sections,workspace,iid,oid,meta['tensor_ids'][lookup] if lookup else 0xffffffff)
    (out/'model.aipkg').write_bytes(image)
    parsed=parse(image)
    if name!='resnet18':
        p,params,parsed=load_program(out/'model.aipkg')
        assert p==program
        for k,v in parameters.items():np.testing.assert_array_equal(v,params[k])
    else:assert parsed['sections']['LEGACY_IMAGE']==legacy
    write_loader(out,name,image,workspace)
    report={'model':name,'package_format':'AIPKG3','engine_profile':parsed['profile'],'image_bytes':len(image),'workspace_bytes':workspace,'crc32':f'0x{parsed["crc32"]:08X}','sha256':parsed['sha256'],'sections':{k:len(v) for k,v in parsed['sections'].items()},'relocatable':True,'load_to_ddr_verified_on_board':False,'current_resnet_bitstream_compatible':False,'binary_roundtrip_pass':True}
    if name=='resnet18':report['legacy_payload_sha256']=meta['legacy_payload_sha256']
    jsdump(out/'package_manifest.json',report)
    print(json.dumps(report,indent=2))
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['build','verify']);p.add_argument('--model',choices=['resnet18','mobilevit_xxs','yolox_s_a']);p.add_argument('--file',type=Path)
    a=p.parse_args()
    if a.action=='build':build(a.model)
    else:
        r=parse(a.file.read_bytes());print(json.dumps({k:v for k,v in r.items() if k not in ['sections','meta']},indent=2))
