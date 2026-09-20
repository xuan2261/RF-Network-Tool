#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,os,shutil,zipfile
project=Path(__file__).resolve().parents[1]
outroot=project.parent
portable=outroot/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PORTABLE'
project_zip=outroot/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PROJECT.zip'
portable_zip=outroot/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PORTABLE.zip'
manifest_name='RELEASE_MANIFEST_v1.4.2.json'
required=[
 'START-RF-NETWORK-TOOL.vbs','RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd',
 'RF-Network-Tool-Launcher.ps1','RF-Network-Tool-Portable.ps1','RF-Network-Tool-ScanWorker.ps1',
 'RF-Network-Tool-DiscoveryWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1',
 'README.txt'
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
GENERATED_TOP_LEVEL_DIRS={'.git','__pycache__','logs','oui-data','real-machine-results'}
GENERATED_TOP_LEVEL_FILES={
 'BUILD_CHECKS_v1.4.2.json','RF-Network-Tool.targets.json','RF-Network-Tool.targets.txt',
 'RF-Network-Tool.device-history.json','RF-Network-Tool.discovery-targets.json','RF-Network-Tool.discovery-cache.json'
}
def is_excluded(root,p):
 rel=p.relative_to(root)
 if any(part in {'.git','__pycache__'} for part in rel.parts): return True
 if rel.parts and rel.parts[0] in GENERATED_TOP_LEVEL_DIRS: return True
 if rel.as_posix() in GENERATED_TOP_LEVEL_FILES: return True
 return p.suffix in {'.pyc','.tmp'}
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
# Minimal portable runtime package.
if portable.exists():shutil.rmtree(portable)
portable.mkdir(parents=True)
for n in required:
 src=project/n
 if not src.is_file(): raise SystemExit(f'Missing portable runtime file: {n}')
 shutil.copy2(src,portable/n)
write_sha_tree(portable)
# Full-project manifest. SHA256.txt and the manifest itself are intentionally excluded from the covered file list.
files=[]
for p in sorted(project.rglob('*')):
 if not p.is_file(): continue
 rel=p.relative_to(project).as_posix()
 if rel in {'SHA256.txt',manifest_name} or is_excluded(project,p): continue
 files.append({'path':rel,'size':p.stat().st_size,'sha256':sha(p)})
ci_verified=os.environ.get('RFT_WINDOWS_RUNTIME_VERIFIED')=='1'
source_revision=os.environ.get('RFT_SOURCE_REVISION',os.environ.get('GITHUB_SHA',''))
manifest={
 'release':'v1.4.2 Full QA / CI-E2E',
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
   'interactiveGuiE2E':'NOT YET VERIFIED (requires self-hosted logged-in Windows runner labeled rft-interactive)',
   'windowsGate':'RUN-DIAGNOSTIC.cmd + RUN-TESTS.cmd + tests/WINDOWS_SMOKE_TEST_v1_4_2.md + tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1'
 }
}
(project/manifest_name).write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
write_sha_tree(project)
# One top-level folder in each zip for clean extraction.
# Normalize ZIP metadata so the same source revision produces byte-identical
# archives across reruns regardless of checkout/file mtimes or runner identity.
ZIP_EPOCH=(1980,1,1,0,0,0)
def write_deterministic_zip(zpath,root):
 if zpath.exists():zpath.unlink()
 with zipfile.ZipFile(zpath,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
  base=root.name
  for p in sorted(root.rglob('*')):
   if not p.is_file() or is_excluded(root,p): continue
   arc=(Path(base)/p.relative_to(root)).as_posix()
   info=zipfile.ZipInfo(arc,ZIP_EPOCH)
   info.create_system=3
   info.compress_type=zipfile.ZIP_DEFLATED
   info.external_attr=(0o100644 << 16)
   info.extra=b''
   info.comment=b''
   z.writestr(info,p.read_bytes(),compress_type=zipfile.ZIP_DEFLATED,compresslevel=9)
for zpath,root in [(project_zip,project),(portable_zip,portable)]:
 write_deterministic_zip(zpath,root)
print(project_zip)
print(portable_zip)