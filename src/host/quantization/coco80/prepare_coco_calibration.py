"""Prepare only a deterministic COCO train calibration subset; never edit val."""
from __future__ import annotations
import concurrent.futures as cf
import hashlib
import io
import json
from pathlib import Path
import random
import shutil
import time
import urllib.request
from urllib.parse import urlparse
import cv2
import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parents[4]
import os
OUT = Path(os.environ.get("NPU_COCO_QUANT_OUT", str(REPO/"work/quantization/coco80")))
OUT.mkdir(parents=True, exist_ok=True)
DATA = Path(os.environ.get("NPU_COCO_DATA", str(REPO/"data/datasets/coco80")))
CKPT = REPO/'data/models/checkpoints/yolox_s_coco80.pth'
EXPECTED = 'f55ded7181e1b0c13285c56e7790b8f0e8f8db590fe4edb37f0b7f345c913a30'
SEED = 20261029

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1048576), b''): h.update(block)
    return h.hexdigest()

def dump(path, obj):
    temp = Path(str(path)+'.writing')
    temp.write_text(json.dumps(obj, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
    temp.replace(path)

def verify(path, record):
    blob = path.read_bytes()
    if len(blob)<100 or not blob.startswith(b'\xff\xd8') or b'\xff\xd9' not in blob[-32:]:
        raise ValueError('incomplete JPEG envelope')
    with Image.open(io.BytesIO(blob)) as image:
        image.verify()
    with Image.open(io.BytesIO(blob)) as image:
        image.load()
        if image.size != (record['width'],record['height']): raise ValueError('PIL dimensions differ from annotation')
    image = cv2.imdecode(np.frombuffer(blob,np.uint8),cv2.IMREAD_COLOR)
    if image is None or image.shape[:2] != (record['height'],record['width']): raise ValueError('OpenCV decode/annotation mismatch')
    return dict(sha256=hashlib.sha256(blob).hexdigest(), bytes=len(blob), decode_verified=True)

def download(record):
    path = OUT/'calibration_train2017'/record['file_name']
    if path.name != record['file_name']: raise ValueError('non-flat image filename')
    attempts=[]
    cached=REPO/'data/calibration/coco80/images'/record['file_name']
    if not path.exists() and cached.exists():
        verify(cached,record)
        shutil.copyfile(cached,path)
        attempts.append({'raw_jpeg_cache':str(cached),'statistics_reused':False})
    if path.exists():
        try:
            result=verify(path,record)
            if record.get('sha256') and result['sha256']!=record['sha256']: raise ValueError('saved image hash changed')
            return {**record,**result,'status':'VERIFIED','reused_verified_file':True,'attempts':attempts}
        except Exception as e: attempts.append({'existing_file_error':repr(e)})
    url=record['source_url']
    for attempt in range(1,5):
        part=path.with_suffix('.jpg.part')
        try:
            request=urllib.request.Request(url,headers={'User-Agent':'COCO-PTQ-calibration/1.0'})
            with urllib.request.urlopen(request,timeout=40) as response:
                expected=response.headers.get('Content-Length')
                size=0
                with part.open('wb') as f:
                    while block:=response.read(262144): f.write(block);size+=len(block)
                if expected and size!=int(expected): raise ValueError('HTTP Content-Length mismatch')
            result=verify(part,record)
            part.replace(path)
            attempts.append({'attempt':attempt,'url':url,'status':'SUCCESS'})
            return {**record,**result,'status':'VERIFIED','reused_verified_file':False,'attempts':attempts}
        except Exception as e:
            attempts.append({'attempt':attempt,'url':url,'error':repr(e)})
            # Same official origin, allow HTTP if its HTTPS endpoint is unavailable.
            if attempt==2: url=record['source_url'].replace('https://','http://',1)
            time.sleep(min(attempt,3))
    return {**record,'status':'FAIL','attempts':attempts}

def main():
    assert digest(CKPT)==EXPECTED,'checkpoint SHA256 mismatch'
    ann=DATA/'annotations/instances_train2017.json'
    valann=DATA/'annotations/instances_val2017.json'
    data=json.loads(ann.read_text(encoding='utf-8'))
    cats=sorted(data['categories'],key=lambda x:x['id'])
    assert len(cats)==80,'training annotation is not 80-class COCO'
    ids={c['id'] for c in cats}
    images={im['id']:im for im in data['images']}
    coverage={i:set() for i in images}
    for a in data['annotations']:
        assert a['image_id'] in images and a['category_id'] in ids
        coverage[a['image_id']].add(a['category_id'])
    rng=random.Random(SEED)
    shuffled=sorted(images);rng.shuffle(shuffled)
    bycat={c:[i for i in shuffled if c in coverage[i]] for c in sorted(ids)}
    selected=[];seen=set()
    for c in sorted(ids,key=lambda c:(len(bycat[c]),c)):
        have=sum(c in coverage[i] for i in selected)
        for i in bycat[c]:
            if have>=3: break
            if i not in seen: selected.append(i);seen.add(i);have+=1
    empty=[i for i in shuffled if not coverage[i]]
    for i in empty[:25]:
        if i not in seen:selected.append(i);seen.add(i)
    for i in shuffled:
        if len(selected)>=500:break
        if i not in seen:selected.append(i);seen.add(i)
    assert len(selected)==500
    rng.shuffle(selected)
    rows=[]
    for i in selected:
        im=images[i];name=im['file_name']
        assert Path(name).name==name
        url=im.get('coco_url',f'http://images.cocodataset.org/train2017/{name}')
        parsed=urlparse(url)
        assert parsed.hostname=='images.cocodataset.org' and parsed.path==f'/train2017/{name}'
        rows.append(dict(image_id=i,file_name=name,width=im['width'],height=im['height'],category_ids=sorted(coverage[i]),source_url=f'https://images.cocodataset.org/train2017/{name}',source_split='train2017',path=str(OUT/'calibration_train2017'/name)))
    manifest=dict(schema='COCO_CALIBRATION_V1',seed=SEED,requested_images=500,
                  sampling_rule='Rare-category-first minimum three images per category, up to 25 naturally empty images, seeded random fill to 500; multi-label sets retained',
                  checkpoint=str(CKPT),checkpoint_sha256=EXPECTED,train_annotations=str(ann),train_annotations_sha256=digest(ann),
                  categories=cats,images=rows,category_image_counts={str(c):sum(c in coverage[i] for i in selected) for c in sorted(ids)},
                  empty_image_count=sum(not coverage[i] for i in selected),validation_used_for_calibration=False,
                  official_image_hashes_available=False,status='DOWNLOADING')
    target=OUT/'calibration_manifest.json'
    if target.exists():
        old=json.loads(target.read_text(encoding='utf-8'))
        assert old['train_annotations_sha256']==manifest['train_annotations_sha256'] and old['seed']==SEED
        assert [r['image_id'] for r in old['images']]==selected,'selection identity changed'
        prior={r['image_id']:r for r in old['images']}
        rows=[{**r,**{k:v for k,v in prior[r['image_id']].items() if k in ['sha256','bytes']}} for r in rows]
    (OUT/'calibration_train2017').mkdir(exist_ok=True)
    manifest['images']=rows;dump(target,manifest)
    results={}
    with cf.ThreadPoolExecutor(max_workers=8) as pool:
        jobs={pool.submit(download,r):r for r in rows}
        for future in cf.as_completed(jobs):
            result=future.result();results[result['image_id']]=result
            if len(results)%20==0 or result['status']=='FAIL':
                manifest['images']=[results.get(r['image_id'],r) for r in rows]
                dump(target,manifest)
                print(f'download {len(results)}/500 verified={sum(r["status"]=="VERIFIED" for r in results.values())}',flush=True)
    manifest['images']=[results[r['image_id']] for r in rows]
    manifest['verified_images']=sum(r['status']=='VERIFIED' for r in manifest['images'])
    manifest['status']='PASS' if manifest['verified_images']==500 else 'FAIL'
    dump(target,manifest)
    if manifest['status']!='PASS':raise RuntimeError('calibration download failed; rerun retries only unverified files')
    val=json.loads(valann.read_text(encoding='utf-8'))
    assert len(val['categories'])==80 and len(val['images'])==5000
    assert [(c['id'],c['name']) for c in sorted(val['categories'],key=lambda c:c['id'])]==[(c['id'],c['name']) for c in cats]
    assert set(selected).isdisjoint(im['id'] for im in val['images']),'train/val image ID overlap'
    missing=[im['file_name'] for im in val['images'] if not (DATA/'val2017'/im['file_name']).is_file()]
    dump(OUT/'dataset_ready.json',dict(status='PASS' if not missing else 'FAIL',val_images=len(val['images']),missing=missing,validation_annotations=str(valann),validation_annotations_sha256=digest(valann),calibration_manifest_sha256=digest(target)))
    assert not missing,'validation images missing'
    print('PASS: 500 verified training calibration images; 5000 validation filenames present; 80 classes',flush=True)

if __name__=='__main__':main()
