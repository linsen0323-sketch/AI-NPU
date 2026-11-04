"""User-facing offline model package tool: inspect, prepare input, integer infer.

The tool never programs the FPGA, alters checkpoints, or touches board memory.
Generated XSDB scripts perform reserved-DDR staging only when run explicitly.
"""
import argparse
import json
import math
import zlib
from pathlib import Path
import numpy as np
from compiler import ART,Q,jsdump
from package import parse,load_program,sha


def write_input_loader(folder,metadata,package):
    offset=int(metadata['offset']);n=int(metadata['bytes'])
    if offset<0 or n<=0 or n%4 or offset+n>package['workspace_bytes']:
        raise ValueError('Input exceeds the declared workspace or has invalid size')
    if (folder/'input.bin').stat().st_size!=n:
        raise ValueError('Input length differs from metadata')
    initial=folder/'legacy_workspace_initial.bin'
    init='';preflight=''
    if package['profile']==1:
        if initial.read_bytes()!=package['sections']['LEGACY_IMAGE']:
            raise ValueError('Legacy bootstrap differs from this package')
        preflight=f'''check_local [file join $here legacy_workspace_initial.bin] {initial.stat().st_size} 0x{zlib.crc32(initial.read_bytes())&0xffffffff:08X}
'''
        init=f'''set boot [file join $here legacy_workspace_initial.bin]
stage_verified $boot $::AI_WORKSPACE_BASE {initial.stat().st_size} 0x{zlib.crc32(initial.read_bytes())&0xffffffff:08X}
'''
    n=metadata['bytes'];crc=zlib.crc32((folder/'input.bin').read_bytes())&0xffffffff
    script=f'''# Offline input staging. Does not start inference or access PL registers.
foreach var {{AI_MODEL_BASE AI_WORKSPACE_BASE AI_DDR_BEGIN AI_DDR_END AI_RESERVED_BEGIN AI_RESERVED_END AI_DDR_EXCLUSIVE}} {{
  if {{![info exists ::$var]}} {{error "Set $var before staging"}}
}}
set cpu_state [state]
if {{$::AI_DDR_EXCLUSIVE!=1 || ($cpu_state ne "Stopped" && ![string match "Stopped: (*)" $cpu_state])}} {{error "Require stopped CPU and exclusive reserved DDR"}}
if {{$::AI_WORKSPACE_BASE%4096 || $::AI_MODEL_BASE%4096}} {{error "Unaligned bases"}}
set modelbytes {package['total_bytes']}
set workbytes {package['workspace_bytes']}
foreach {{b e}} [list $::AI_MODEL_BASE [expr {{$::AI_MODEL_BASE+$modelbytes}}] $::AI_WORKSPACE_BASE [expr {{$::AI_WORKSPACE_BASE+$workbytes}}]] {{
  if {{$b<$::AI_DDR_BEGIN || $e>$::AI_DDR_END || $b<$::AI_RESERVED_BEGIN || $e>$::AI_RESERVED_END || $e<=$b}} {{error "Range outside DDR reservation"}}
}}
if {{max($::AI_MODEL_BASE,$::AI_WORKSPACE_BASE)<min($::AI_MODEL_BASE+$modelbytes,$::AI_WORKSPACE_BASE+$workbytes)}} {{error "Model/workspace overlap"}}
proc check_local {{file length expected_crc}} {{
  set f [open $file rb]
  try {{set data [read $f]}} finally {{close $f}}
  if {{[string length $data]!=$length || ([zlib crc32 $data]&0xffffffff)!=$expected_crc}} {{error "Local input/bootstrap CRC mismatch"}}
}}
proc verify_ddr {{base length expected_crc}} {{
  set crc 0
  for {{set off 0}} {{$off<$length}} {{incr off $n}} {{
    set n [expr {{min(65536,$length-$off)}}]
    set data [mrd -size w -bin [expr {{$base+$off}}] [expr {{$n/4}}]]
    if {{[string length $data]!=$n}} {{error "Short DDR read"}}
    set crc [zlib crc32 $data $crc]
  }}
  if {{($crc&0xffffffff)!=$expected_crc}} {{error "Actual DDR input CRC mismatch"}}
}}
proc stage_verified {{file base length expected_crc}} {{
  check_local $file $length $expected_crc
  dow -data $file $base
  verify_ddr $base $length $expected_crc
}}
set here [file dirname [info script]]
{preflight}check_local [file join $here input.bin] {n} 0x{crc:08X}
# Require the exact matching model image to have been staged first.
verify_ddr $::AI_MODEL_BASE $modelbytes 0x{package['crc32']:08X}
{init}set input_address [expr {{$::AI_WORKSPACE_BASE+{offset}}}]
stage_verified [file join $here input.bin] $input_address {n} 0x{crc:08X}
puts "Input staged and actual DDR CRC verified. No inference started."
puts "A future PS runtime must manage cache flush/invalidate and ownership before execution."
'''
    (folder/'load_input.tcl').write_text(script,encoding='ascii')


def prepare_input(package_path,image,folder):
    raise RuntimeError('Historical 224/640 image-input helper disabled for final npu100. Use the packaged Linux camera/preprocessing runtime and docs/model_pipeline.md.')
    package_path=Path(package_path);folder=Path(folder)
    data=package_path.read_bytes();parsed=parse(data)
    fixed,metadata=preprocess(parsed,image)
    folder.mkdir(parents=True,exist_ok=True)
    fixed.tofile(folder/'input.bin');np.save(folder/'input.npy',fixed)
    metadata.update(bytes=fixed.nbytes,sha256=sha(fixed.tobytes()),
                    package_sha256=parsed['sha256'])
    jsdump(folder/'input_manifest.json',metadata)
    if parsed['profile']==1:
        (folder/'legacy_workspace_initial.bin').write_bytes(parsed['sections']['LEGACY_IMAGE'])
    write_input_loader(folder,metadata,{**parsed,'total_bytes':len(data)})
    return fixed,metadata


def preprocess(package,image):
    meta=package['meta']
    name=meta.get('name',meta.get('program',{}).get('name'))
    if name=='mobilevit_xxs':
        from PIL import Image
        im=Image.open(image).convert('RGB').resize((256,256),Image.Resampling.BILINEAR)
        pixels=np.asarray(im,dtype=np.uint8).transpose(2,0,1)[None]
        lookup=meta['program']['input_conversion']['lookup'];desc=meta['parameters'][lookup]
        lut=np.frombuffer(package['sections']['CONSTANTS'],dtype='<i4',count=256,offset=desc['offset'])
        return lut[pixels].astype('<i4'),{'name':name,'shape':[1,3,256,256],'dtype':'int32','fractional_bits':16,'offset':meta['workspace_plan'][meta['program']['input']]['offset'],'source':str(image),'input_conversion':'package U8->Q16 lookup'}
    if name=='yolox_s_a':
        import cv2
        im=cv2.imread(str(image))
        if im is None:raise FileNotFoundError(image)
        h,w=im.shape[:2];r=min(640/h,640/w)
        resize=cv2.resize(im,(int(w*r),int(h*r)),interpolation=cv2.INTER_LINEAR)
        canvas=np.full((640,640,3),114,dtype=np.uint8);canvas[:resize.shape[0],:resize.shape[1]]=resize
        fixed=canvas.transpose(2,0,1)[None].astype('<i4')*Q
        return fixed,{'name':name,'shape':[1,3,640,640],'dtype':'int32','fractional_bits':16,'offset':meta['workspace_plan'][meta['program']['input']]['offset'],'source':str(image),'original_hw':[h,w],'letterbox_ratio':r,'letterbox_pad_xy':[0,0]}
    # Preserve the ResNet deployment input pipeline exactly.
    from PIL import Image
    from torchvision import transforms
    transform=transforms.Compose([transforms.Resize(256),transforms.CenterCrop(224),transforms.ToTensor(),transforms.Normalize([.485,.456,.406],[.229,.224,.225])])
    values=transform(Image.open(image).convert('RGB')).numpy()[None]
    quant=meta['layout']['input_quantization']
    scale=np.float32(quant['scale']);zp=int(quant['zero_point'])
    data=np.clip(np.rint(values/scale)+zp,-128,127).astype(np.int8)
    return data,{'name':'resnet18','shape':[1,3,224,224],'dtype':'int8','fractional_bits':0,'offset':meta['input_offset'],'source':str(image),'scale':float(scale),'zero_point':zp}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='action',required=True)
    a=sub.add_parser('list')
    for cmd in ['inspect','prepare-input','run']:
        a=sub.add_parser(cmd);a.add_argument('--package',required=True,type=Path)
        if cmd in ['prepare-input','run']:
            a.add_argument('--image',required=True,type=Path);a.add_argument('--out',required=True,type=Path)
        if cmd=='run':a.add_argument('--strict-attention',action='store_true')
    a=p.parse_args()
    if a.action in ('prepare-input','run'):
        p.error('Historical 224/640 image-input and inference CLI disabled for final npu100. Use the packaged Linux runtime; see docs/model_pipeline.md.')
    if a.action=='list':
        for name in ['resnet18','mobilevit_xxs','yolox_s_a']:
            path=ART/name/'model.aipkg'
            if path.exists():
                r=parse(path.read_bytes());print(name,'image',path.stat().st_size,'workspace',r['workspace_bytes'],'profile',r['profile'])
        return
    image=a.package.read_bytes();r=parse(image)
    if a.action=='inspect':
        meta=r['meta'];print(json.dumps({'file':str(a.package),'model_id':r['model_id'],'engine_profile':r['profile'],'image_bytes':len(image),'workspace_bytes':r['workspace_bytes'],'crc32':f'0x{r["crc32"]:08X}','sha256':r['sha256'],'sections':{k:len(v) for k,v in r['sections'].items()},'classes':meta.get('program',{}).get('classes',['Cr','In','PS','Pa','RS','Sc']),'board_validation':False},indent=2,ensure_ascii=False));return
    fixed,metadata=prepare_input(a.package,a.image,a.out)
    if a.action=='prepare-input':print(json.dumps(metadata,indent=2,ensure_ascii=False));return
    if r['profile']==1:
        from legacy_reference import execute
        logits,result=execute(a.package,fixed.tobytes())
        result['class_name']=['Cr','In','PS','Pa','RS','Sc'][result['class_id']]
        np.save(a.out/'output_integer.npy',logits)
        jsdump(a.out/'result.json',result)
        print(json.dumps(result,indent=2,ensure_ascii=False));return
    from integer_runtime import Runtime
    program,parameters,_=load_program(a.package)
    rt=Runtime(program=program,parameters=parameters,strict_attention=a.strict_attention)
    out=rt.run(fixed,input_fixed=True).cpu().numpy()
    np.save(a.out/'output_integer.npy',out)
    if metadata['name']=='mobilevit_xxs':
        idx=int(out.argmax(-1)[0]);result={'class_id':idx,'class_name':program['classes'][idx],'integer_logits':out.tolist(),'fractional_bits':16}
    else:
        import torch
        from torchvision.ops import batched_nms
        pred=torch.from_numpy(out[0].astype(np.float32)/Q)
        corners=torch.cat([pred[:,:2]-pred[:,2:4]/2,pred[:,:2]+pred[:,2:4]/2],dim=1)
        cls_conf,cls=pred[:,5:].max(1);scores=pred[:,4]*cls_conf
        keep=scores>=.01
        boxes=corners[keep];scores=scores[keep];classes=cls[keep]
        chosen=batched_nms(boxes,scores,classes,.65)
        detections=[]
        if len(chosen):
            ratio=metadata['letterbox_ratio']
            for idx in chosen:
                cls_id=int(classes[idx]);detections.append({'class_id':cls_id,'class_name':program['classes'][cls_id],'xyxy_original':(boxes[idx]/ratio).tolist(),'score':float(scores[idx])})
        result={'detections':detections,'nms_on_host':True,'integer_output_shape':list(out.shape)}
    jsdump(a.out/'result.json',result)
    print(json.dumps(result,indent=2,ensure_ascii=False))


if __name__=='__main__':main()
