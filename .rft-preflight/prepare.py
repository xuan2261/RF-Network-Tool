from pathlib import Path, PurePosixPath
import base64, hashlib, json, lzma, os, sys, urllib.request
root=Path.cwd()
raw=lzma.decompress(base64.b64decode(''.join((root/'.rft-preflight'/('part-%d.b64'%i)).read_text().strip() for i in range(3))))
assert hashlib.sha256(raw).hexdigest()=='96ed2c6ecafc5c6df89842da7d48eb0f5c4c1c5fb0d9eda9dc64eabc53e2f639'
recipe=json.loads(raw)
mode=sys.argv[1]
changes=[]
for item in recipe['files']:
    name=item['path']; rel=PurePosixPath(name)
    assert not rel.is_absolute() and '..' not in rel.parts
    path=root/name
    if mode=='publish':
        data=path.read_bytes(); assert hashlib.sha256(data).hexdigest()==item['after'], name
        payload=json.dumps({'encoding':'base64','content':base64.b64encode(data).decode()}).encode()
        req=urllib.request.Request('https://api.github.com/repos/'+os.environ['GITHUB_REPOSITORY']+'/git/blobs',data=payload,method='POST',headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'rft-authorized-preflight'})
        with urllib.request.urlopen(req,timeout=45) as response: blob=json.load(response)
        expected=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
        assert blob['sha']==expected,name
        record={'path':name,'mode':'100644','type':'blob','sha':blob['sha']};changes.append(record)
        print('VERIFIED_BLOB '+json.dumps(record))
        continue
    data=path.read_bytes() if path.exists() else b''
    assert hashlib.sha256(data).hexdigest()==item['before'], 'Base mismatch: '+name
    lines=data.decode('utf-8').splitlines(keepends=True)
    for start,end,text in reversed(item['edits']): lines[start:end]=[text]
    data=''.join(lines).encode('utf-8'); assert hashlib.sha256(data).hexdigest()==item['after'], 'Patch mismatch: '+name
    if mode=='prepare' and name=='tests/WINDOWS_MEASUREMENT_TEST_v1_5_3.ps1':
        (root/'.rft-preflight/baseline-test.ps1').write_bytes(data)
    elif mode=='apply':
        path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
if mode=='publish':
    dest=root/'ci-artifacts/blob-map.json';dest.parent.mkdir(exist_ok=True)
    dest.write_text(json.dumps({'base':recipe['base'],'files':changes},indent=2))
print('PREFLIGHT_'+mode.upper()+'_DONE')
