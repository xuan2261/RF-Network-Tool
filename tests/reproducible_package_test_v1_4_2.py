#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,tempfile,zipfile

root=Path(__file__).resolve().parents[1]
version=(root/'VERSION').read_text(encoding='ascii').strip();tag=f'v{version}';prefix=f'RF-Network-Tool-{tag}-FULL-QA-CI-E2E'

def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1<<20),b''): h.update(chunk)
 return h.hexdigest()

def copy_project(dst):
 shutil.copytree(root,dst,ignore=shutil.ignore_patterns('.git','__pycache__','*.pyc'))

def build(project,run_id):
 env=os.environ.copy()
 env['RFT_WINDOWS_RUNTIME_VERIFIED']='1'
 env['RFT_SOURCE_REVISION']='repro-source-revision'
 env['GITHUB_RUN_ID']=str(run_id)
 subprocess.run([sys.executable,str(project/'release_tools'/'build_release.py')],cwd=project,env=env,check=True,stdout=subprocess.DEVNULL)
 out=project.parent
 return out/f'{prefix}-PROJECT.zip',out/f'{prefix}-PORTABLE.zip'

def perturb_mtimes(project):
 t=1_900_000_000
 for p in project.rglob('*'):
  if p.is_file():
   try: os.utime(p,(t,t))
   except OSError: pass

def normalized_zip(zp):
 with zipfile.ZipFile(zp) as z:
  infos=z.infolist()
  return bool(infos) and all(i.date_time==(1980,1,1,0,0,0) and i.extra==b'' for i in infos)

with tempfile.TemporaryDirectory(prefix='rft-repro-') as td:
 tmp=Path(td); project=tmp/'RF-Network-Tool'; copy_project(project)
 dirty_files={
  f'BUILD_CHECKS_v{version}.json':'{"local":true}',
  'BUILD_CHECKS_v0.0.0.json':'{"stale":true}',
  'RELEASE_MANIFEST_v0.0.0.json':'{"stale":true}',
  'RF-Network-Tool.targets.json':'{"private":true}',
  'RF-Network-Tool.targets.txt':'private',
  'RF-Network-Tool.device-history.json':'{"private":true}',
  'RF-Network-Tool.discovery-targets.json':'{"private":true}',
  'RF-Network-Tool.discovery-cache.json':'{"private":true}',
  'RF-Network-Tool.scan-history.json':'{"private":true}',
  'RF-Network-Tool.monitoring.json':'{"private":true}',
  'RF-Network-Tool.monitoring-history.json':'{"private":true}',
  'RF-Network-Tool.oui-prefix-cache.v1.tsv':'001122\tPrivate Vendor',
  'dirty.tmp':'temporary',
 }
 for rel,data in dirty_files.items():(project/rel).write_text(data,encoding='utf-8')
 dirty_dirs={
  'logs/runtime.log':'private runtime log',
  'oui-data/cache.txt':'private runtime cache',
  'real-machine-results/machine-info.json':'{"machine":"private"}',
  'ci-artifacts/ui-tab-items.txt':'private qualification evidence',
 }
 for rel,data in dirty_dirs.items():
  p=project/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(data,encoding='utf-8')
 p1,z1=build(project,111111)
 first=(sha(p1),sha(z1))
 manifest=json.loads((project/f'RELEASE_MANIFEST_{tag}.json').read_text(encoding='utf-8'))
 checks={
  'manifest_has_stable_source_revision':manifest.get('verification',{}).get('sourceRevision')=='repro-source-revision',
  'manifest_has_no_run_id':'githubActionsRunId' not in manifest.get('verification',{}),
  'project_zip_metadata_normalized':normalized_zip(p1),
  'portable_zip_metadata_normalized':normalized_zip(z1),
 }
 forbidden=set(dirty_files)|set(dirty_dirs)
 with zipfile.ZipFile(p1) as z:
  packaged={x[len(project.name)+1:] for x in z.namelist() if x.startswith(project.name+'/')}
  checks['project_zip_excludes_local_generated_artifacts']=not (forbidden & packaged)
 manifest_files={x.get('path') for x in manifest.get('files',[])}
 checks['manifest_excludes_local_generated_artifacts']=not (forbidden & manifest_files)
 perturb_mtimes(project)
 p2,z2=build(project,999999)
 second=(sha(p2),sha(z2))
 checks['project_zip_byte_reproducible']=first[0]==second[0]
 checks['portable_zip_byte_reproducible']=first[1]==second[1]
 failed=[k for k,v in checks.items() if not v]
 for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
 print('TOTAL',len(checks),'FAILED',len(failed))
 sys.exit(1 if failed else 0)
