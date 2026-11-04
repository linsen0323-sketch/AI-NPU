"""Validate packaged model identities and runtime descriptors; never access hardware."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import sys
from collections import Counter

REPO=Path(__file__).resolve().parents[3]
sys.dont_write_bytecode = True
PREFIXES={'models/':'data/models/','host/':'src/host/','third_party/':'src/third_party/','software/':'src/software/'}
RETIRED_DOCUMENTS = {
    'docs/model_gaps.md': 'b9464759209dd4f405f254416536065f396b50836071397e70736bd22131bb2c',
}


def current_target(relative):
    return next((new+relative[len(old):] for old,new in PREFIXES.items() if relative.startswith(old)),relative)


def migration_hashes():
    """Collect path-only adaptation links while preserving historical ledgers."""
    links={}
    for name in ('layout_migration.json','layout_metadata_adaptation.json'):
        receipt=REPO/'evidence/packaging'/name
        if not receipt.is_file():
            continue
        data=json.loads(receipt.read_text('utf-8'))
        for row in data.get('moved_files',[])+data.get('edits',[]):
            path=row['after_path']
            links.setdefault(path,[]).append((row['before_sha256'],row['after_sha256'],name))
    return links


def check_historical_asset(entry, links, current_inventory):
    historical=entry['target']
    relative=current_target(historical)
    path=(REPO/relative).resolve()
    assert path.is_relative_to(REPO.resolve()),f'unsafe historical target: {historical}'
    if relative in RETIRED_DOCUMENTS and not path.exists():
        receipt_path = REPO/'evidence/packaging/documentation_cleanup.json'
        receipt = json.loads(receipt_path.read_text('utf-8'))
        retired = {row['path']: row for row in receipt['removed_documents']}
        assert entry['target_sha256'] == RETIRED_DOCUMENTS[relative], 'retired document historical hash changed'
        assert retired.get(relative, {}).get('before_sha256') == RETIRED_DOCUMENTS[relative], 'retired document receipt missing or changed'
        assert relative not in current_inventory, 'retired document remains in current manifest'
        return 'retired_document_receipt'
    assert path.is_file(),f'missing packaged file: {historical}'
    actual=digest(path)
    original=entry['target_sha256']
    if actual==original:
        return 'historical_sha256'
    # Frozen input/model/third-party bytes always use the original hash.
    editable=historical.startswith(('host/','docs/','build/scripts/','tools/'))
    assert editable,f'frozen packaged asset changed: {historical}'
    reachable={original}
    receipts=set()
    for _ in range(len(links.get(relative,[]))+1):
        for before,after,receipt in links.get(relative,[]):
            if before in reachable:
                reachable.add(after);receipts.add(receipt)
    if actual in reachable:
        return 'layout_receipt_sha256'
    # A final release manifest also records subsequent authored documentation.
    # It cannot excuse changing immutable models, data or third-party sources.
    if historical.startswith(('docs/','build/scripts/','tools/')) and current_inventory.get(relative)==actual:
        return 'current_release_manifest_sha256'
    raise AssertionError(f'Adapted file lacks a matching migration/current release receipt: {relative}')

def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()

def verify():
    bundle=REPO/'data/models/runtime/bundle'
    spec=importlib.util.spec_from_file_location('package_manifest_contract',REPO/'src/host/plan_tools/runtime_manifest.py')
    contract=importlib.util.module_from_spec(spec);spec.loader.exec_module(contract)
    manifest=json.loads((bundle/'manifest.json').read_text('utf-8'))
    models=contract.check_manifest(manifest)
    checks=[]
    for record in models:
        image=bundle/record['file']
        assert digest(image)==record['image_sha256'],f'model checksum: {image}'
        assert digest(bundle/record['golden_input'])==record['input_sha256']
        contract.check_image(image.read_bytes(),record)
        checks.append(dict(id=record['id'],name=record['name'],bytes=image.stat().st_size,
                           sha256=digest(image),descriptor_and_memory_contract='PASS'))
    for line in (bundle/'SHA256SUMS').read_text('utf-8').splitlines():
        if not line.strip():continue
        expected,name=line.split(maxsplit=1)
        relative=name.lstrip('*')
        path=(bundle/relative).resolve()
        assert path.is_relative_to(bundle.resolve()),'unsafe checksum path'
        assert digest(path)==expected,f'bundle checksum: {relative}'
    copied=json.loads((REPO/'evidence/packaging/models_files.json').read_text('utf-8'))['files']
    links=migration_hashes()
    inventory_file=REPO/'manifests/files.json'
    current_inventory={row['path']:row['sha256'] for row in json.loads(inventory_file.read_text('utf-8'))['files']} if inventory_file.is_file() else {}
    verified=0
    bases=Counter()
    for entry in copied:
        basis=check_historical_asset(entry,links,current_inventory)
        bases[basis]+=1
        if basis != 'retired_document_receipt':
            verified+=1
    return dict(status='PASS',scope='local_file_integrity_and_binary_contract_only',
                board_test_executed=False,inference_executed=False,models=checks,
                packaged_files_verified=verified,verification_basis=dict(bases),
                historical_document_entries_retired=bases['retired_document_receipt'],
                historical_ledgers_modified=False)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    result=verify()
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
