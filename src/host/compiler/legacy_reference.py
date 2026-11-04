"""Read-only adapter for the original ResNet integer DDR ABI and Golden helpers.

Executes the actual LEGACY_IMAGE bytes, preserving the original weight packing,
40-bit accumulator semantics, Add coefficients, full shift range and INT8 -128.
It imports the protected helpers but does not run their artifact writers.
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path
import numpy as np
import torch
from compiler import ART,jsdump
from package import LEGACY,parse,sha

GOLDEN=Path(__file__).resolve().parents[3]/"data/reference/resnet18/verify_full_resnet18_int8.py"


def execute(package_path,input_bytes=None,check_original=False):
    parsed=parse(Path(package_path).read_bytes())
    assert parsed['profile']==1
    meta=parsed['meta'];layout=meta['layout']
    if check_original and sha(GOLDEN.read_bytes())!=layout['source_sha256']['tools/verify_full_resnet18_int8.py']:
        raise ValueError('Protected ResNet Golden source changed')
    source_hash=layout['source_sha256']['tools/verify_full_resnet18_int8.py']
    from legacy_cpu import execute as execute_legacy
    memory=bytearray(parsed['sections']['LEGACY_IMAGE'])
    assert sha(memory)==meta['legacy_payload_sha256']
    if input_bytes is not None:
        assert len(input_bytes)==150528
        start=layout['input_offset'];memory[start:start+len(input_bytes)]=input_bytes
    torch.set_num_threads(6)
    outputs=execute_legacy(memory,layout)
    verified=0
    if check_original:
        trace=json.loads((LEGACY/'vectors/network_trace.json').read_text(encoding='utf-8'))
        assert len(trace)==len(outputs)==len(layout['descriptors'])
        for (i,payload),entry in zip(outputs,trace):
            p=LEGACY.parent/entry['golden']
            expected=bytes.fromhex(p.read_text(encoding='ascii'))
            assert payload==expected,(i,entry['name'])
            verified+=len(payload)
    logits=np.frombuffer(memory,dtype=np.int8,count=6,offset=layout['output_offset']).copy()
    if check_original:assert sha(GOLDEN.read_bytes())==source_hash
    return logits,{'layers_executed':len(outputs),'elements_compared_to_frozen_trace':verified,'integer_logits':logits.tolist(),'class_id':int(logits.argmax()),'legacy_payload_sha256':meta['legacy_payload_sha256'],'protected_golden_sha256':source_hash,'original_sources_modified':False,'all_pass':True,'check_original':bool(check_original),'package_sha256':parsed['sha256']}


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--package',type=Path,default=ART/'resnet18/model.aipkg');p.add_argument('--input',type=Path);p.add_argument('--check-original',action='store_true')
    a=p.parse_args();_,report=execute(a.package,a.input.read_bytes() if a.input else None,a.check_original)
    from provenance import write_report
    inputs=[a.package,GOLDEN,LEGACY/'ddr.bin',LEGACY/'layout.json']
    if a.check_original:
        trace=LEGACY/'vectors/network_trace.json';inputs.append(trace)
        inputs.extend(LEGACY.parent/e['golden'] for e in json.loads(trace.read_text(encoding='utf-8')))
    write_report(ART/'resnet18/legacy_reference_validation.json',report,inputs)
    print(json.dumps(report,indent=2))
