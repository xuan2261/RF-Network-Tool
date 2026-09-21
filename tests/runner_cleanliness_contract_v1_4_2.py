#!/usr/bin/env python3
from pathlib import Path
import sys

root=Path(__file__).resolve().parents[1]
ps=(root/'tests/WINDOWS_RUNNER_CLEANLINESS_v1_4_2.ps1').read_text(encoding='utf-8-sig')
ui=(root/'.github/workflows/ui-e2e-selfhosted.yml').read_text(encoding='utf-8')
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')

checks={
 'cleanliness_pre_post_modes':"[ValidateSet('Pre','Post')]" in ps,
 'cleanliness_self_process_excluded':'[int]$p.ProcessId -eq $PID' in ps,
 'cleanliness_process_inventory':'Get-CimInstance Win32_Process' in ps and 'RF-Network-Tool-Portable.ps1' in ps and 'RF-Network-Tool-ScanWorker.ps1' in ps,
 'cleanliness_source_owned_scope':'$sourceOwned=' in ps and 'Join-Path $root $scriptName' in ps,
 'cleanliness_e2e_sandbox_scope':"$sandboxOwned=" in ps and 'RFT-v142-e2e-' in ps,
 'cleanliness_real_lan_temp_scope':'RFT-real-lan-*' in ps,
 'cleanliness_no_raw_commandline_evidence':"privacy='Command lines, user paths, usernames and machine names are not persisted.'" in ps and 'CommandLine=' not in ps,
 'cleanliness_fail_closed':'activeProcesses={1} residualTempDirs={2}' in ps and 'exit 1' in ps,
 'cleanliness_success_marker':'RUNNER CLEANLINESS {0} PASSED' in ps,
 'physical_pre_cleanliness':'- name: Pre-run runner cleanliness' in ui and 'WINDOWS_RUNNER_CLEANLINESS_v1_4_2.ps1 -Phase Pre' in ui,
 'physical_post_cleanliness':'- name: Post-run runner cleanliness' in ui and 'WINDOWS_RUNNER_CLEANLINESS_v1_4_2.ps1 -Phase Post' in ui,
 'physical_post_cleanliness_always':"- name: Post-run runner cleanliness\n        if: always()" in ui,
 'physical_cleanliness_safe_evidence':all(x in ui for x in ['runner-cleanliness-pre.json','runner-cleanliness-post.json','ci-artifacts\\physical-safe']),
 'hosted_cleanliness_smoke':'- name: Runner cleanliness smoke' in ci and 'WINDOWS_RUNNER_CLEANLINESS_v1_4_2.ps1 -Phase Post' in ci,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)
