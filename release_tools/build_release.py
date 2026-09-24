#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,sys,zipfile
project=Path(__file__).resolve().parents[1]
outroot=project.parent
version=(project/'VERSION').read_text(encoding='ascii').strip()
if not re.fullmatch(r'\d+\.\d+\.\d+',version): raise SystemExit(f'Invalid VERSION: {version!r}')
tag=f'v{version}'
prefix=f'RF-Network-Tool-{tag}-FULL-QA-CI-E2E'
portable=outroot/f'{prefix}-PORTABLE'
project_zip=outroot/f'{prefix}-PROJECT.zip'
portable_zip=outroot/f'{prefix}-PORTABLE.zip'
manifest_name=f'RELEASE_MANIFEST_{tag}.json'
required=[
 'START-RF-NETWORK-TOOL.vbs','RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd',
 'RF-Network-Tool-Launcher.ps1','RF-Network-Tool-Portable.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-RoutePlanner.ps1',
 'RF-Network-Tool-DiscoveryWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1',
 'README.txt','VERSION'
]
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()
def clean_bytecode(root):
 for p in list(root.rglob('__pycache__')): shutil.rmtree(p,ignore_errors=True)
 for p in list(root.rglob('*.pyc')):
  try:p.unlink()
  except FileNotFoundError:pass
EXCLUDED_DIRS={'.git','__pycache__','logs','oui-data','real-machine-results','ci-artifacts'}
EXCLUDED_TOP_FILES={
 'RF-Network-Tool.targets.json','RF-Network-Tool.targets.txt',
 'RF-Network-Tool.device-history.json','RF-Network-Tool.discovery-targets.json','RF-Network-Tool.discovery-cache.json'
}
def is_excluded(root,p):
 rel=p.relative_to(root)
 if any(part in EXCLUDED_DIRS for part in rel.parts): return True
 if p.suffix in {'.pyc','.tmp'}: return True
 if len(rel.parts)==1:
  name=rel.name
  if name in EXCLUDED_TOP_FILES: return True
  if name.startswith('BUILD_CHECKS_v') and name.endswith('.json'): return True
  if name.startswith('RELEASE_MANIFEST_v') and name.endswith('.json') and name!=manifest_name: return True
 return False
def write_sha_tree(root):
 rows=[]
 for p in sorted(root.rglob('*')):
  if not p.is_file(): continue
  rel=p.relative_to(root).as_posix()
  if rel in {'SHA256.txt',manifest_name} or is_excluded(root,p): continue
  rows.append(f'{sha(p)}  {rel}')
 (root/'SHA256.txt').write_text('\n'.join(rows)+'\n',encoding='ascii')
 return rows
clean_bytecode(project)
if portable.exists():shutil.rmtree(portable)
portable.mkdir(parents=True)
for n in required:
 src=project/n
 if not src.is_file(): raise SystemExit(f'Missing portable runtime file: {n}')
 shutil.copy2(src,portable/n)
write_sha_tree(portable)
files=[]
for p in sorted(project.rglob('*')):
 if not p.is_file(): continue
 rel=p.relative_to(project).as_posix()
 if rel in {'SHA256.txt',manifest_name} or is_excluded(project,p): continue
 files.append({'path':rel,'size':p.stat().st_size,'sha256':sha(p)})
ci_verified=os.environ.get('RFT_WINDOWS_RUNTIME_VERIFIED')=='1'
source_revision=os.environ.get('RFT_SOURCE_REVISION',os.environ.get('GITHUB_SHA',''))
manifest={
 'release':f'{tag} Full QA / CI-E2E',
 'version':version,
 'projectFileCount':len(files),
 'portableFiles':required+['SHA256.txt'],
 'files':files,
 'verification':{
   'designPlan':'PASS',
   'linuxStaticDeterministicSource':'PASS',
   'windowsRuntime':('EXECUTION PASS (hosted Windows matrix)' if ci_verified else 'NOT YET VERIFIED'),
   'githubActions':('EXECUTION PASS' if ci_verified else 'NOT YET VERIFIED'),
   'sourceRevision':source_revision,
   'hostedWindowsGate':'windows-2022 + windows-2025: integration + PSScriptAnalyzer + diagnostic E2E',
   'interactiveGuiE2E':'NOT YET VERIFIED (requires logged-in Windows physical/self-hosted evidence)',
   'windowsGate':'RUN-DIAGNOSTIC.cmd + RUN-TESTS.cmd + tests/WINDOWS_SMOKE_TEST_v1_4_2.md + tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1'
 }
}
(project/manifest_name).write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
write_sha_tree(project)
ZIP_EPOCH=(1980,1,1,0,0,0)
def write_deterministic_zip(zpath,root):
 if zpath.exists():zpath.unlink()
 with zipfile.ZipFile(zpath,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
  base=root.name
  for p in sorted(root.rglob('*')):
   if not p.is_file() or is_excluded(root,p): continue
   arc=(Path(base)/p.relative_to(root)).as_posix()
   info=zipfile.ZipInfo(arc,ZIP_EPOCH);info.create_system=3;info.compress_type=zipfile.ZIP_DEFLATED
   info.external_attr=(0o100644 << 16);info.extra=b'';info.comment=b''
   z.writestr(info,p.read_bytes(),compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
for zpath,root in [(project_zip,project),(portable_zip,portable)]: write_deterministic_zip(zpath,root)
sbom_builder=project/'release_tools'/'build_sbom.py'
subprocess.run([sys.executable,str(sbom_builder),'--version',version,'--source-date-epoch','315532800',str(project_zip),str(portable_zip)],check=True)
for artifact in (project_zip,portable_zip,project_zip.with_suffix('.spdx.json'),portable_zip.with_suffix('.spdx.json')): print(artifact)
