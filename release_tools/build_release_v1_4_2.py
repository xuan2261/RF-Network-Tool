#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,shutil,zipfile
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
def write_sha_tree(root):
 rows=[]
 for p in sorted(root.rglob('*')):
  if not p.is_file(): continue
  rel=p.relative_to(root).as_posix()
  if rel in {'SHA256.txt',manifest_name} or '__pycache__' in p.parts or p.suffix=='.pyc': continue
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
 if rel in {'SHA256.txt',manifest_name} or '__pycache__' in p.parts or p.suffix=='.pyc': continue
 files.append({'path':rel,'size':p.stat().st_size,'sha256':sha(p)})
manifest={
 'release':'v1.4.2 Full QA / CI-E2E',
 'projectFileCount':len(files),
 'portableFiles':required+['SHA256.txt'],
 'files':files,
 'verification':{
   'designPlan':'PASS',
   'linuxStaticDeterministicSource':'PASS',
   'windowsRuntime':'NOT YET VERIFIED',
   'githubActionsConfigured':'PASS (workflow syntax/contract checked locally; live Actions run requires a GitHub repo)',
   'hostedWindowsGate':'windows-2022 + windows-2025: integration + PSScriptAnalyzer + diagnostic E2E',
   'interactiveGuiE2E':'NOT YET VERIFIED (requires self-hosted logged-in Windows runner labeled rft-interactive)',
   'windowsGate':'RUN-DIAGNOSTIC.cmd + RUN-TESTS.cmd + tests/WINDOWS_SMOKE_TEST_v1_4_2.md + tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1'
 }
}
(project/manifest_name).write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
write_sha_tree(project)
# One top-level folder in each zip for clean extraction.
for zpath,root in [(project_zip,project),(portable_zip,portable)]:
 if zpath.exists():zpath.unlink()
 with zipfile.ZipFile(zpath,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
  base=root.name
  for p in sorted(root.rglob('*')):
   if p.is_file() and '__pycache__' not in p.parts and p.suffix!='.pyc':
    z.write(p,Path(base)/p.relative_to(root))
print(project_zip)
print(portable_zip)