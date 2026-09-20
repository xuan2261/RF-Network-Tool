#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
ps=(root/'RF-Network-Tool-RealMachineQualification.ps1').read_text(encoding='utf-8-sig')
cmd=(root/'RUN-REAL-MACHINE-QUALIFICATION.cmd').read_text(encoding='ascii')
lan=(root/'tests/WINDOWS_REAL_LAN_TEST_v1_4_2.ps1').read_text(encoding='utf-8-sig')
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
e2e=(root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').read_text(encoding='utf-8-sig')
checks={
 'wrapper_safe_default':'set "MODE=%~1"' in cmd and 'set "MODE=SAFE"' in cmd,
 'wrapper_gui_optin':'-Mode Gui -AllowModuleInstall' in cmd,
 'wrapper_full_optin':'-Mode Full -AllowModuleInstall' in cmd,
 'orchestrator_modes':"[ValidateSet('Safe','Gui','Full')]" in ps,
 'orchestrator_bundle':'RF-Network-Tool-REAL-MACHINE-LOGS-' in ps and 'Compress-Archive' in ps and 'Get-FileHash -Algorithm SHA256' in ps,
 'orchestrator_privacy':all(x in ps for x in ['<USERPROFILE>','<USERNAME>','<COMPUTER>']),
 'orchestrator_core_gates':all(x in ps for x in ['WINDOWS_INTEGRATION_TEST_v1_4_2.ps1','WINDOWS_LINT_GATE_v1_4_2.ps1','WINDOWS_CHAOS_TEST_v1_4_2.ps1','WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1','WINDOWS_LAUNCHER_E2E_v1_4_2.ps1']),
 'orchestrator_gui_gate':'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1' in ps and "Mode -in @('Gui','Full')" in ps,
 'orchestrator_lan_skip':'skipExitCodes' in ps and '@(3)' in ps,
 'orchestrator_clean_winps_modulepath':all(x in ps for x in ['Start-CleanWindowsPowerShell','Remove-Item Env:PSModulePath','PowerShellGet -MinimumVersion 2.2.5','PSScriptAnalyzer -RequiredVersion 1.25.0']),
 'orchestrator_child_fail_defense':all(x in ps for x in ['selfReportedFail',"child reported FAIL"]),
 'e2e_uia_title_normalization':all(x in e2e for x in ['Normalize-UiName',"-replace '&',''",'^RF Network Diagnostic Tool - Portable v1\\.4\\.2']),
 'e2e_timeout_uses_argument_string':'Process timeout: $exe $argumentString' in e2e and 'Process timeout: $exe $args' not in e2e,
 'real_lan_private_only':'refusing to probe a public IPv4 subnet' in lan and 'Test-LocalSafeIPv4' in lan,
 'real_lan_not_applicable':'exit 3' in lan and 'no active physical private/link-local/CGNAT' in lan,
 'real_lan_physical_default':'HardwareInterface' in lan and 'VMware|VirtualBox' in lan,
 'real_lan_bounded':'Refusing to probe more than 254 hosts' in lan,
 'real_lan_profiles':"@('FAST','BALANCED')" in lan and 'DEEP' not in lan,
 'real_lan_identity':all(x in lan for x in ['no duplicate result IPs','local IPv4 discovered exactly once','runId matches']),
 'ci_harness_smoke':'Real-machine qualification harness SAFE smoke' in ci and 'RF-Network-Tool-RealMachineQualification.ps1 -Mode Safe -NoZip' in ci,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)
