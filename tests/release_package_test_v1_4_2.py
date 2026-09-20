#!/usr/bin/env python3
from pathlib import Path
import hashlib,os,zipfile,json,sys
root=Path(__file__).resolve().parents[1]; out=root.parent
portable=out/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PORTABLE'
pzip=out/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PROJECT.zip'; zportable=out/'RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PORTABLE.zip'
manifest_name='RELEASE_MANIFEST_v1.4.2.json'
required={
 'START-RF-NETWORK-TOOL.vbs','RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd','RF-Network-Tool-Launcher.ps1','RF-Network-Tool-Portable.ps1',
 'RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-DiscoveryWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1','README.txt','SHA256.txt'
}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1<<20),b''):h.update(b)
 return h.hexdigest()
def sha_entries(rootdir):
 rows={}
 for line in (rootdir/'SHA256.txt').read_text(encoding='ascii').splitlines():
  if not line.strip():continue
  digest,rel=line.split('  ',1);rows[rel]=digest
 return rows
def verify_sha(rootdir):
 rows=sha_entries(rootdir)
 return bool(rows) and all((rootdir/rel).is_file() and sha(rootdir/rel)==digest for rel,digest in rows.items())
def is_excluded(rootdir,p):
 rel=p.relative_to(rootdir)
 return '.git' in rel.parts or '__pycache__' in rel.parts or p.suffix=='.pyc'
def expected_hash_files(rootdir):
 ex={'SHA256.txt',manifest_name}
 return {p.relative_to(rootdir).as_posix() for p in rootdir.rglob('*') if p.is_file() and p.relative_to(rootdir).as_posix() not in ex and not is_excluded(rootdir,p)}
def zip_top_folder(zp,expected):
 with zipfile.ZipFile(zp) as z:
  names=[x for x in z.namelist() if x and not x.endswith('/')]
  return bool(names) and all(x.startswith(expected+'/') for x in names)
def zip_has_no_vcs_metadata(zp):
 with zipfile.ZipFile(zp) as z:
  return all('/.git/' not in x and not x.endswith('/.git') for x in z.namelist())
vbs=(root/'START-RF-NETWORK-TOOL.vbs').read_bytes()
cmds=[(root/x).read_bytes() for x in ('RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd','RUN-TESTS.cmd')]
manifest=json.loads((root/manifest_name).read_text(encoding='utf-8')) if (root/manifest_name).is_file() else {}
checks={
 'portable_exact_files':portable.is_dir() and {p.name for p in portable.iterdir() if p.is_file()}==required,
 'portable_no_dirs':portable.is_dir() and not any(p.is_dir() for p in portable.iterdir()),
 'project_manifest_exists':(root/manifest_name).is_file(),
 'project_manifest_release':manifest.get('release')=='v1.4.2 Full QA / CI-E2E',
 'project_sha_manifest':(root/'SHA256.txt').is_file() and verify_sha(root),
 'portable_sha_manifest':(portable/'SHA256.txt').is_file() and verify_sha(portable),
 'project_sha_coverage':(root/'SHA256.txt').is_file() and set(sha_entries(root))==expected_hash_files(root),
 'portable_sha_coverage':portable.is_dir() and (portable/'SHA256.txt').is_file() and set(sha_entries(portable))==expected_hash_files(portable),
 'project_release_manifest_coverage':set(x['path'] for x in manifest.get('files',[]))==expected_hash_files(root),
 'project_sha_no_vcs_metadata':(root/'SHA256.txt').is_file() and all(not rel.startswith('.git/') for rel in sha_entries(root)),
 'project_release_manifest_no_vcs_metadata':all(not x.get('path','').startswith('.git/') for x in manifest.get('files',[])),
 'ci_manifest_windows_verified':(manifest.get('verification',{}).get('windowsRuntime','').startswith('EXECUTION PASS') if os.environ.get('RFT_WINDOWS_RUNTIME_VERIFIED')=='1' else manifest.get('verification',{}).get('windowsRuntime')=='NOT YET VERIFIED'),
 'project_zip_exists':pzip.is_file(),
 'portable_zip_exists':zportable.is_file(),
 'project_zip_crc':False,
 'portable_zip_crc':False,
 'project_zip_top_folder':pzip.is_file() and zip_top_folder(pzip,root.name),
 'project_zip_no_vcs_metadata':pzip.is_file() and zip_has_no_vcs_metadata(pzip),
 'portable_zip_top_folder':zportable.is_file() and zip_top_folder(zportable,portable.name),
 'no_pycache_project':not any('__pycache__' in p.parts or p.suffix=='.pyc' for p in root.rglob('*')),
 'portable_runtime_workers':all((portable/x).is_file() for x in ['RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-DiscoveryWorker.ps1']),
 'portable_has_readme':(portable/'README.txt').is_file() and 'MONITORING' in (portable/'README.txt').read_text(encoding='utf-8-sig'),
 'vbs_ascii_no_bom':not vbs.startswith(b'\xef\xbb\xbf') and all(x<128 for x in vbs),
 'cmd_ascii_no_bom':all(not b.startswith(b'\xef\xbb\xbf') and all(x<128 for x in b) for b in cmds),
 'windows_v142_tests_in_full':all((root/x).is_file() for x in ['tests/WINDOWS_INTEGRATION_TEST_v1_4_2.ps1','tests/WINDOWS_CHAOS_TEST_v1_4_2.ps1','tests/WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1','tests/WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1','tests/WINDOWS_LINT_GATE_v1_4_2.ps1','tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1','tests/WINDOWS_SMOKE_TEST_v1_4_2.md','tests/security_audit_v1_4_2.py']),
 'ci_workflows_in_full':all((root/x).is_file() for x in ['.github/workflows/ci.yml','.github/workflows/ui-e2e-selfhosted.yml']),
 'portable_no_dev_artifacts':portable.is_dir() and not any((portable/x).exists() for x in ['tests','plans','release_tools','.github','QA_REPORT_v1.4.2.md'])
}
for key,zp in [('project_zip_crc',pzip),('portable_zip_crc',zportable)]:
 if zp.is_file():
  with zipfile.ZipFile(zp) as z:checks[key]=(z.testzip() is None)
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)