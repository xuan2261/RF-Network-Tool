#!/usr/bin/env python3
from pathlib import Path
import hashlib, json, re, sys, zipfile

root=Path(__file__).resolve().parents[1]
out=root.parent
version=(root/'VERSION').read_text(encoding='ascii').strip()
assert re.fullmatch(r'\d+\.\d+\.\d+', version)
tag=f'v{version}'; prefix=f'RF-Network-Tool-{tag}-FULL-QA-CI-E2E'
archives=[
    out/f'{prefix}-PROJECT.zip',
    out/f'{prefix}-PORTABLE.zip',
]

def digest(data, algorithm):
    h=hashlib.new(algorithm); h.update(data); return h.hexdigest()

def digest_file(path, algorithm='sha256'):
    h=hashlib.new(algorithm)
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1<<20), b''): h.update(chunk)
    return h.hexdigest()

def checksum_map(entry):
    return {x['algorithm']:x['checksumValue'] for x in entry.get('checksums', [])}

def expected_verification_code(values):
    return hashlib.sha1(''.join(sorted(values)).encode('ascii')).hexdigest()

checks={}
for archive in archives:
    label='project' if 'PROJECT' in archive.name else 'portable'
    sbom=archive.with_suffix('.spdx.json')
    checks[label+'_archive_exists']=archive.is_file()
    checks[label+'_sbom_exists']=sbom.is_file()
    if not archive.is_file() or not sbom.is_file():
        continue
    doc=json.loads(sbom.read_text(encoding='utf-8'))
    checks[label+'_spdx_version']=doc.get('spdxVersion')=='SPDX-2.3'
    checks[label+'_data_license']=doc.get('dataLicense')=='CC0-1.0'
    checks[label+'_document_describes']=doc.get('documentDescribes')==['SPDXRef-Package']
    checks[label+'_created_deterministic']=doc.get('creationInfo',{}).get('created')=='1980-01-01T00:00:00Z'
    archive_sha256=digest_file(archive,'sha256')
    checks[label+'_namespace_binds_archive']=doc.get('documentNamespace','').endswith('/'+archive_sha256)
    packages=doc.get('packages',[])
    checks[label+'_one_package']=len(packages)==1
    if len(packages)!=1:
        continue
    package=packages[0]
    checks[label+'_package_id']=package.get('SPDXID')=='SPDXRef-Package'
    checks[label+'_package_name']=package.get('name')==archive.name
    checks[label+'_version']=package.get('versionInfo')==version
    checks[label+'_files_analyzed']=package.get('filesAnalyzed') is True
    checks[label+'_package_sha256']=checksum_map(package).get('SHA256')==archive_sha256
    files={x.get('fileName'):x for x in doc.get('files',[])}
    with zipfile.ZipFile(archive) as z:
        members=sorted(i.filename for i in z.infolist() if not i.is_dir())
        checks[label+'_file_set_exact']=set(files)==set(members) and len(files)==len(members)
        sha1_values=[]; file_hash_ok=True
        for name in members:
            data=z.read(name)
            sha1=digest(data,'sha1'); sha256=digest(data,'sha256'); sha1_values.append(sha1)
            sums=checksum_map(files.get(name,{}))
            if sums.get('SHA1')!=sha1 or sums.get('SHA256')!=sha256:
                file_hash_ok=False
        checks[label+'_file_hashes']=file_hash_ok
    pvc=package.get('packageVerificationCode',{}).get('packageVerificationCodeValue')
    checks[label+'_verification_code']=pvc==expected_verification_code(sha1_values)
    contains={(x.get('spdxElementId'),x.get('relationshipType'),x.get('relatedSpdxElement')) for x in doc.get('relationships',[])}
    expected={('SPDXRef-Package','CONTAINS',x.get('SPDXID')) for x in files.values()}
    checks[label+'_contains_relationships']=contains==expected

failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
if failed: print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)
