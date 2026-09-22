#!/usr/bin/env python3
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, json, os, re, zipfile

SPDX_VERSION='SPDX-2.3'
DATA_LICENSE='CC0-1.0'
DEFAULT_EPOCH=315532800  # 1980-01-01T00:00:00Z, aligned with deterministic ZIP epoch.

def digest_bytes(data, algorithm):
    h=hashlib.new(algorithm); h.update(data); return h.hexdigest()

def digest_file(path, algorithm='sha256'):
    h=hashlib.new(algorithm)
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1<<20), b''): h.update(chunk)
    return h.hexdigest()

def spdx_id_for_path(path):
    return 'SPDXRef-File-'+hashlib.sha1(path.encode('utf-8')).hexdigest()

def verification_code(sha1_values):
    return hashlib.sha1(''.join(sorted(sha1_values)).encode('ascii')).hexdigest()

def created_timestamp(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def build_sbom(archive, output, version, epoch):
    archive=Path(archive).resolve()
    output=Path(output).resolve()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise SystemExit(f'Invalid version: {version!r}')
    if not archive.is_file():
        raise SystemExit(f'Archive does not exist: {archive}')
    archive_sha256=digest_file(archive, 'sha256')
    files=[]; sha1_values=[]; relationships=[]; seen_ids=set()
    with zipfile.ZipFile(archive) as z:
        members=sorted((i for i in z.infolist() if not i.is_dir()), key=lambda i:i.filename)
        if not members:
            raise SystemExit(f'Archive has no files: {archive}')
        for info in members:
            data=z.read(info)
            sha1=digest_bytes(data, 'sha1')
            sha256=digest_bytes(data, 'sha256')
            file_id=spdx_id_for_path(info.filename)
            if file_id in seen_ids:
                raise SystemExit(f'SPDX identifier collision for: {info.filename}')
            seen_ids.add(file_id); sha1_values.append(sha1)
            files.append({
                'SPDXID':file_id,
                'fileName':info.filename,
                'checksums':[
                    {'algorithm':'SHA1','checksumValue':sha1},
                    {'algorithm':'SHA256','checksumValue':sha256},
                ],
                'licenseConcluded':'NOASSERTION',
                'licenseInfoInFiles':['NOASSERTION'],
                'copyrightText':'NOASSERTION',
            })
            relationships.append({
                'spdxElementId':'SPDXRef-Package',
                'relationshipType':'CONTAINS',
                'relatedSpdxElement':file_id,
            })
    tag=f'v{version}'
    namespace=f'https://github.com/xuan2261/RF-Network-Tool/releases/{tag}/sbom/{archive.name}/{archive_sha256}'
    package={
        'SPDXID':'SPDXRef-Package',
        'name':archive.name,
        'versionInfo':version,
        'downloadLocation':'NOASSERTION',
        'filesAnalyzed':True,
        'packageVerificationCode':{'packageVerificationCodeValue':verification_code(sha1_values)},
        'checksums':[{'algorithm':'SHA256','checksumValue':archive_sha256}],
        'licenseConcluded':'NOASSERTION',
        'licenseDeclared':'NOASSERTION',
        'copyrightText':'NOASSERTION',
        'primaryPackagePurpose':'APPLICATION',
    }
    document={
        'spdxVersion':SPDX_VERSION,
        'dataLicense':DATA_LICENSE,
        'SPDXID':'SPDXRef-DOCUMENT',
        'name':archive.name+'.spdx',
        'documentNamespace':namespace,
        'creationInfo':{
            'created':created_timestamp(epoch),
            'creators':[f'Tool: RF-Network-Tool deterministic SBOM generator {tag}'],
            'comment':'Generated deterministically from the exact release ZIP; timestamp derives from SOURCE_DATE_EPOCH.',
        },
        'documentDescribes':['SPDXRef-Package'],
        'packages':[package],
        'files':files,
        'relationships':relationships,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2)+'\n', encoding='utf-8')
    return output

def main():
    parser=argparse.ArgumentParser(description='Build deterministic SPDX 2.3 SBOMs from release ZIP archives.')
    parser.add_argument('archives', nargs='+', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--source-date-epoch', type=int, default=int(os.environ.get('SOURCE_DATE_EPOCH', DEFAULT_EPOCH)))
    args=parser.parse_args()
    if args.source_date_epoch < 0:
        raise SystemExit('SOURCE_DATE_EPOCH must be non-negative.')
    for archive in args.archives:
        if archive.suffix.lower()!='.zip':
            raise SystemExit(f'Only ZIP archives are supported: {archive}')
        print(build_sbom(archive, archive.with_suffix('.spdx.json'), args.version, args.source_date_epoch))

if __name__=='__main__':
    main()
