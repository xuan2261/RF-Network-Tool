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

DIRTY_DIRS=('logs','oui-data','real-machine-results','ci-artifacts')
DIRTY_FILES=(
 'RF-Network-Tool.targets.json','RF-Network-Tool.targets.txt','RF-Network-Tool.device-history.json',
 'RF-Network-Tool.discovery-targets.json','RF-Network-Tool.discovery-cache.json',
 f'BUILD_CHECKS_v{version}.json','scratch.tmp','RELEASE_MANIFEST_v0.0.0.json'
)
def seed_dirty_workspace(project):
 for d in DIRTY_DIRS:
  p=project/d;p.mkdir(parents=True,exist_ok=True);(p/'local-only.txt').write_text('local generated artifact',encoding='utf-8')
 for name in DIRTY_FILES:(project/name).write_text('local generated artifact',encoding='utf-8')
def forbidden_rel(rel):
 parts=Path(rel).parts
 if any(p in DIRTY_DIRS for p in parts): return True
 return Path(rel).name in DIRTY_FILES
def project_zip_has_no_dirty_artifacts(zp,project_name):
 with zipfile.ZipFile(zp) as z:
  rels=[n[len(project_name)+1:] for n in z.namelist() if n.startswith(project_name+'/') and not n.endswith('/')]
  return not any(forbidden_rel(rel) for rel in rels)

with tempfile.TemporaryDirectory(prefix='rft-repro-') as td:
 tmp=Path(td); project=tmp/'RF-Network-Tool'; copy_project(project)
 seed_dirty_workspace(project)
 p1,z1=build(project,111111)
 first=(sha(p1),sha(z1))
 manifest=json.loads((project/f'RELEASE_MANIFEST_{tag}.json').read_text(encoding='utf-8'))
 checks={
  'manifest_has_stable_source_revision':manifest.get('verification',{}).get('sourceRevision')=='repro-source-revision',
  'manifest_has_no_run_id':'githubActionsRunId' not in manifest.get('verification',{}),
  'project_zip_metadata_normalized':normalized_zip(p1),
  'portable_zip_metadata_normalized':normalized_zip(z1),
  'project_zip_excludes_local_generated_artifacts':project_zip_has_no_dirty_artifacts(p1,project.name),
  'manifest_excludes_local_generated_artifacts':not any(forbidden_rel(x.get('path','')) for x in manifest.get('files',[])),
 }
 perturb_mtimes(project)
 p2,z2=build(project,999999)
 second=(sha(p2),sha(z2))
 checks['project_zip_byte_reproducible']=first[0]==second[0]
 checks['portable_zip_byte_reproducible']=first[1]==second[1]
 failed=[k for k,v in checks.items() if not v]
 for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
 print('TOTAL',len(checks),'FAILED',len(failed))
 sys.exit(1 if failed else 0)
