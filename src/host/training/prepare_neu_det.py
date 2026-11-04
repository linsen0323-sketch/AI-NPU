#!/usr/bin/env python3
"""Convert original NEU-DET Pascal VOC XMLs to leakage-free YOLOX COCO split.

- Never touches originals.
- Removes exactly the known byte-identical patches_101.jpg, retaining
  patches_105.jpg with its own XML annotations (not claimed authoritative).
- Stratifies by original image filename class; 60 validation images per class.
- Uses original Pascal VOC bounding-box coordinates and object classes as stored in XML.
- Reports filenames whose prefix differs from an object class; requires explicit
  --accept-xml-labels to proceed (do not silently discard objects).
- Stores an exact split manifest for reproducibility.

Run from YOLOX project root:
  python prepare_neu_voc_paper_clean.py \
    --src NEU-DET-original --dest datasets/NEU_PAPER80_CLEAN --seed 2022
"""
from __future__ import annotations
import argparse
import hashlib
import json
import random
import shutil
import xml.etree.ElementTree as ET
from collections import defaultdict, Counter
from pathlib import Path
from PIL import Image

CLASSES = ('crazing', 'inclusion', 'patches', 'pitted_surface', 'rolled-in_scale', 'scratches')
CLASS_IDS = {label: i+1 for i,label in enumerate(CLASSES)}
VALID_EXT = {'.jpg', '.jpeg', '.png', '.bmp'}


def normalize(s: str) -> str:
    return '_'.join(s.strip().lower().split())


def filename_class(name: str) -> str:
    stem = Path(name).stem.lower()
    matches = [label for label in CLASSES if stem.startswith(label + '_')]
    if len(matches) != 1:
        raise ValueError(f'Cannot determine defect class from filename: {name}')
    return matches[0]


def convert_xml(xml_file: Path, image_size: tuple[int,int]) -> list[dict]:
    root = ET.parse(xml_file).getroot()
    w,h = image_size
    size = root.find('size')
    if size is not None:
        xw, xh = size.findtext('width'), size.findtext('height')
        if xw and xh and (int(xw),int(xh)) != (w,h):
            raise ValueError(f'XML/image dimensions disagree: {xml_file} XML={(xw,xh)}, actual={(w,h)}')
    anns=[]
    for obj in root.findall('object'):
        label=normalize(obj.findtext('name',''))
        if label not in CLASS_IDS:
            raise ValueError(f'Unknown category {label!r} in {xml_file}')
        bb=obj.find('bndbox')
        if bb is None:
            raise ValueError(f'No <bndbox> for object in {xml_file}')
        vals=[float(bb.findtext(c)) for c in ('xmin','ymin','xmax','ymax')]
        x0,y0,x1,y1=vals
        if not (0<=x0<x1<=w and 0<=y0<y1<=h):
            raise ValueError(f'Invalid/out-of-bounds box {vals} for {(w,h)} in {xml_file}')
        bw,bh=x1-x0,y1-y0
        anns.append({'category_id':CLASS_IDS[label], 'bbox':[x0,y0,bw,bh], 'area':bw*bh, 'iscrowd':0, 'segmentation':[]})
    if not anns:
        raise ValueError(f'No object annotations in {xml_file}')
    return anns


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--src',default='NEU-DET-original')
    ap.add_argument('--dest',default='datasets/NEU_PAPER80_CLEAN')
    ap.add_argument('--seed',type=int,default=2022)
    ap.add_argument('--val-per-class',type=int,default=60)
    ap.add_argument('--audit-only', action='store_true', help='Check all original labels and duplicates; do not write dataset')
    ap.add_argument('--accept-xml-labels', action='store_true', help='Proceed using original XML object labels even when image filename category differs')
    args=ap.parse_args()
    src=Path(args.src).resolve()
    dest=Path(args.dest).resolve()
    images_dir=src/'IMAGES'
    annotations_dir=src/'ANNOTATIONS'
    if not images_dir.is_dir() or not annotations_dir.is_dir():
        raise SystemExit(f'Missing IMAGES or ANNOTATIONS directory under {src}')
    if dest.exists():
        raise SystemExit(f'Refusing to overwrite existing output directory: {dest}')
    if src == dest or src in dest.parents:
        raise SystemExit('Destination cannot be inside source directory.')
    images=sorted((p for p in images_dir.iterdir() if p.is_file() and p.suffix.lower() in VALID_EXT),key=lambda p:p.name)
    xmls=list(annotations_dir.glob('*.xml'))
    if len(images)!=1800 or len(xmls)!=1800:
        raise SystemExit(f'Expected 1800 images and 1800 XMLs; found images={len(images)}, xmls={len(xmls)}; no output created.')
    if len({p.stem for p in images})!=len(images):
        raise SystemExit('Multiple image files have the same stem; no output created.')
    hash_groups=defaultdict(list)
    for p in images:
        hash_groups[hashlib.sha256(p.read_bytes()).hexdigest()].append(p)
    duplicates=[g for g in hash_groups.values() if len(g)>1]
    expected={'patches_101.jpg','patches_105.jpg'}
    if len(duplicates)!=1 or len(duplicates[0])!=2 or {p.name for p in duplicates[0]}!=expected:
        raise SystemExit(f'Unexpected duplicate groups: {[[p.name for p in g] for g in duplicates]}. Review before processing.')
    removed=next(p for p in duplicates[0] if p.name=='patches_101.jpg')
    selected=[p for p in images if p!=removed]
    if len(selected)!=1799:
        raise SystemExit(f'Expected 1799 unique images, found {len(selected)}')
    groups=defaultdict(list)
    meta={}
    mismatches=[]
    for path in selected:
        xml=annotations_dir/(path.stem+'.xml')
        if not xml.is_file():
            raise SystemExit(f'Missing XML: {xml}')
        with Image.open(path) as im:
            size=im.size
        anns=convert_xml(xml,size)
        group=filename_class(path.name)
        xml_classes = sorted({CLASSES[a['category_id'] - 1] for a in anns})
        if any(label != group for label in xml_classes):
            mismatches.append((path.name, group, xml_classes))
        groups[group].append(path)
        meta[path]=(size,anns)
    total=sum(len(g) for g in groups.values())
    if total!=1799:
        raise SystemExit('Not all images are accounted for')
    print(f'Filename vs XML category mismatches: {len(mismatches)}')
    for filename, filename_label, xml_labels in mismatches:
        print(f'  {filename}: filename={filename_label}, XML={xml_labels}')
    if args.audit_only:
        print('AUDIT COMPLETE: no new dataset written.')
        return
    if mismatches and not args.accept_xml_labels:
        raise SystemExit('Review mismatch list before rebuilding. To retain XML object labels, rerun with --accept-xml-labels. No output created.')
    print(f'Original: {len(images)} image entries, {len(xmls)} XML files.')
    print('Duplicate: patches_101.jpg and patches_105.jpg (identical bytes; XML annotations differ).')
    print('Excluded patches_101.jpg from NEW dataset. Keeping patches_105.jpg with its own XML.')
    rng=random.Random(args.seed)
    train, val=[],[]
    for cat in CLASSES:
        group=sorted(groups[cat],key=lambda p:p.name)
        if len(group)<=args.val_per_class:
            raise SystemExit(f'Not enough images for {cat}: {len(group)}')
        rng.shuffle(group)
        val.extend(group[:args.val_per_class])
        train.extend(group[args.val_per_class:])
        print(f'{cat}: total={len(group)}, train={len(group)-args.val_per_class}, val={args.val_per_class}')
    rng.shuffle(train)
    rng.shuffle(val)
    if len(train)!=1439 or len(val)!=360:
        raise SystemExit(f'Unexpected split {len(train)} / {len(val)} (expected 1439 / 360).')
    dest.mkdir(parents=True)
    (dest/'annotations').mkdir()
    categories=[{'id':CLASS_IDS[name],'name':name,'supercategory':'defect'} for name in CLASSES]
    for split, items in [('train2017',train),('val2017',val)]:
        img_dir=dest/split
        img_dir.mkdir()
        images_out=[]
        annotations_out=[]
        instances=Counter()
        annotation_id=1
        for image_id,path in enumerate(items,1):
            shutil.copy2(path,img_dir/path.name)
            (w,h), anns = meta[path]
            images_out.append({'id':image_id,'file_name':path.name,'width':w,'height':h})
            for ann in anns:
                annotations_out.append(dict(ann,id=annotation_id,image_id=image_id))
                instances[CLASSES[ann['category_id']-1]]+=1
                annotation_id+=1
        payload={'info':{'description':'NEU-DET unique-image stratified split; not the 2022 paper authors split','seed':args.seed},'licenses':[],
                 'images':images_out,'annotations':annotations_out,'categories':categories}
        out=dest/'annotations'/f'instances_{split}.json'
        out.write_text(json.dumps(payload,ensure_ascii=False,indent=1),encoding='utf-8')
        print(f'{split}: {len(images_out)} images, {len(annotations_out)} boxes')
        print('  defect instances:',dict(instances))
    manifest={'source':str(src),'seed':args.seed,'paper_split_exact':False,
              'category_mismatches': [{'image': name, 'filename_category': cat, 'xml_categories': cats} for name, cat, cats in mismatches],
              'removed_duplicate':'patches_101.jpg','kept_duplicate':'patches_105.jpg',
              'train2017':[p.name for p in train],'val2017':[p.name for p in val]}
    (dest/'split_manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False),encoding='utf-8')
    print(f'OK. Created dataset: {dest}')
    print('Reminder: 1439/360 clean approximate replication, not the paper original 1440/360 image list.')

if __name__=='__main__':
    main()
