#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,tempfile,zipfile

root=Path(__file__).resolve().parents[1]

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
 subprocess.run([sys.executable,str(project/'release_tools'/'build_release_v1_4_2.py')],cwd=project,env=env,check=True,stdout=subprocess.DEVNULL)
 out=project.parent
 p=out/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PROJECT.zip'\n z=out/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PORTABLE.zip'\n return p,z,p.with_suffix('.spdx.json'),z.with_suffix('.spdx.json')

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
 # Simulate a used/dirty workstation before release packaging. These files are
 # generated at runtime or by local QA and must never enter a release archive.
 (project/'BUILD_CHECKS_v1.4.2.json').write_text('{"local":true}',encoding='utf-8')
 (project/'RF-Network-Tool.targets.json').write_text('{"private":true}',encoding='utf-8')
 (project/'dirty.tmp').write_text('temporary',encoding='utf-8')
 (project/'logs').mkdir(exist_ok=True); (project/'logs'/'runtime.log').write_text('private runtime log',encoding='utf-8')
 (project/'oui-data').mkdir(exist_ok=True); (project/'oui-data'/'cache.txt').write_text('runtime cache',encoding='utf-8')
 (project/'real-machine-results').mkdir(exist_ok=True); (project/'real-machine-results'/'machine-info.json').write_text('{"machine":"private"}',encoding='utf-8')
 p1,z1=build(project,111111)
 first=(sha(p1),sha(z1))
 manifest=json.loads((project/'RELEASE_MANIFEST_v1.4.2.json').read_text(encoding='utf-8'))
 checks={
  'manifest_has_stable_source_revision':manifest.get('verification',{}).get('sourceRevision')=='repro-source-revision',
  'manifest_has_no_run_id':'githubActionsRunId' not in manifest.get('verification',{}),
  'project_zip_metadata_normalized':normalized_zip(p1),
  'portable_zip_metadata_normalized':normalized_zip(z1),
 }
 with zipfile.ZipFile(p1) as z:
  packaged=set(z.namelist())
  prefix=project.name+'/'
  forbidden={
   prefix+'BUILD_CHECKS_v1.4.2.json',prefix+'RF-Network-Tool.targets.json',prefix+'dirty.tmp',
   prefix+'logs/runtime.log',prefix+'oui-data/cache.txt',prefix+'real-machine-results/machine-info.json'
  }
  checks['project_zip_excludes_local_generated_artifacts']=not (forbidden & packaged)
 manifest_files={x.get('path') for x in manifest.get('files',[])}
 checks['manifest_excludes_local_generated_artifacts']=not ({
  'BUILD_CHECKS_v1.4.2.json','RF-Network-Tool.targets.json','dirty.tmp','logs/runtime.log',
  'oui-data/cache.txt','real-machine-results/machine-info.json'
 } & manifest_files)
 perturb_mtimes(project)
 p2,z2=build(project,999999)
 second=(sha(p2),sha(z2))
 checks['project_zip_byte_reproducible']=first[0]==second[0]
 checks['portable_zip_byte_reproducible']=first[1]==second[1]
 failed=[k for k,v in checks.items() if not v]
 for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
 print('TOTAL',len(checks),'FAILED',len(failed))
 sys.exit(1 if failed else 0)
