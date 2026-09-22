#!/usr/bin/env python3
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
runtime=[
 'RF-Network-Tool-DiscoveryWorker.ps1','RF-Network-Tool-Launcher.ps1','RF-Network-Tool-PingWorker.ps1',
 'RF-Network-Tool-Portable.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-TaskWorker.ps1',
 'START-RF-NETWORK-TOOL.vbs','RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd','RUN-TESTS.cmd',
 'tests/WINDOWS_MACHINE_CLEANLINESS_v1_4_2.ps1','tests/WINDOWS_MACHINE_CLEANLINESS_TEST_v1_4_2.ps1',
 'release_tools/build_release.py','release_tools/build_release_v1_4_2.py','release_tools/build_sbom.py','tests/release_sbom_test_v1_4_2.py','.github/actionlint.yaml','.github/workflows/ci.yml','.github/workflows/ui-e2e-selfhosted.yml'
]
secret_patterns={
 'github_token':re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{40,})\b'),
 'aws_access_key':re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
 'openai_key':re.compile(r'\bsk-[A-Za-z0-9_-]{20,}\b'),
 'private_key':re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
}
danger_patterns={
 'invoke_expression':re.compile(r'(?im)^\s*(?:iex|Invoke-Expression)\b'),
 'download_execute':re.compile(r'(?is)(?:DownloadString|Invoke-WebRequest|curl(?:\.exe)?)\s*[^\n|]{0,200}\|\s*(?:iex|powershell|pwsh|cmd|sh)\b'),
}
findings=[]
for rel in runtime:
 p=root/rel
 if not p.is_file():
  findings.append((rel,'missing_runtime_file',''))
  continue
 text=p.read_text(encoding='utf-8-sig',errors='replace')
 for name,rx in {**secret_patterns,**danger_patterns}.items():
  if rx.search(text):findings.append((rel,name,'matched'))
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
ui=(root/'.github/workflows/ui-e2e-selfhosted.yml').read_text(encoding='utf-8')
uses=re.findall(r'(?m)^\s*-?\s*uses:\s*([^\s#]+)',ci+'\n'+ui)
external=[u for u in uses if not u.startswith('./')]
unpinned=[u for u in external if not re.search(r'@[0-9a-fA-F]{40}$',u)]
checks={
 'runtime_files_present':not any(x[1]=='missing_runtime_file' for x in findings),
 'no_high_confidence_secrets':not any(x[1] in secret_patterns for x in findings),
 'no_download_execute_patterns':not any(x[1] in danger_patterns for x in findings),
 'no_pull_request_target':'pull_request_target:' not in ci,
 'no_write_all_permissions':not re.search(r'(?m)^\s*permissions:\s*write-all\s*$',ci),
 'no_continue_on_error':'continue-on-error:' not in ci,
 'all_external_actions_pinned_sha':not unpinned and bool(external),
 'package_attestation_permissions':all(x in ci for x in ['id-token: write','attestations: write','contents: read']),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
for rel,kind,_ in findings:
 if kind!='missing_runtime_file':print('FINDING',kind,rel)
for u in unpinned:print('FINDING unpinned_action',u)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)
