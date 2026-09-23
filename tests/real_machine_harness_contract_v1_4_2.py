#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
ps=(root/'RF-Network-Tool-RealMachineQualification.ps1').read_text(encoding='utf-8-sig')
cmd=(root/'RUN-REAL-MACHINE-QUALIFICATION.cmd').read_text(encoding='ascii')
lan=(root/'tests/WINDOWS_REAL_LAN_TEST_v1_4_2.ps1').read_text(encoding='utf-8-sig')
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
e2e=(root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').read_text(encoding='utf-8-sig')
clean=(root/'tests/WINDOWS_MACHINE_CLEANLINESS_v1_4_2.ps1').read_text(encoding='utf-8-sig')
clean_test=(root/'tests/WINDOWS_MACHINE_CLEANLINESS_TEST_v1_4_2.ps1').read_text(encoding='utf-8-sig')
integration=(root/'tests/WINDOWS_INTEGRATION_TEST_v1_4_2.ps1').read_text(encoding='utf-8-sig')
checks={
 'wrapper_safe_default':'set "MODE=%~1"' in cmd and 'set "MODE=SAFE"' in cmd,
 'wrapper_gui_optin':'-Mode Gui -AllowModuleInstall' in cmd,
 'wrapper_full_optin':'-Mode Full -AllowModuleInstall' in cmd,
 'wrapper_exact_revision_optin':all(x in cmd for x in ['EXPECTED_SHA=%~2','-ExpectedSourceRevision %EXPECTED_SHA%']),
 'orchestrator_modes':"[ValidateSet('Safe','Gui','Full')]" in ps,
 'integration_parses_qualification_harness':all(x in integration for x in ["RF-Network-Tool-RealMachineQualification.ps1","@('RealMachineQualification',$qualification)"]),
 'orchestrator_bundle':'RF-Network-Tool-REAL-MACHINE-LOGS-' in ps and 'Compress-Archive' in ps and 'Get-FileHash -Algorithm SHA256' in ps,
 'orchestrator_privacy':all(x in ps for x in ['<USERPROFILE>','<USERNAME>','<COMPUTER>','<MAC>','<IPv6>','Mask-NetworkEvidence','bundle IPv4/IPv6/MAC redacted.']),
 'orchestrator_ipv6_privacy_selftest':all(x in ps for x in ['SanitizerSelfTest','2001:db8::1234','fe80::abcd%36','fd12:3456::5','IPV6 EVIDENCE SANITIZER SELF-TEST PASSED']),
 'orchestrator_ipv6_sanitizer_function_complete':all(x in ps for x in ['[Net.IPAddress]::TryParse($parseCandidate,[ref]$parsed)',"return '<IPv6>'",'function Get-SourceRevisionEvidence']),
 'orchestrator_source_revision':all(x in ps for x in ['ExpectedSourceRevision','Get-SourceRevisionEvidence','root-folder-suffix','sourceRevision','source_revision']),
 'orchestrator_core_gates':all(x in ps for x in ['WINDOWS_INTEGRATION_TEST_v1_4_2.ps1','WINDOWS_LINT_GATE_v1_4_2.ps1','WINDOWS_CHAOS_TEST_v1_4_2.ps1','WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1','WINDOWS_LAUNCHER_E2E_v1_4_2.ps1']),
 'orchestrator_cleanliness_gates':all(x in ps for x in ['WINDOWS_MACHINE_CLEANLINESS_v1_4_2.ps1','machine_cleanliness_baseline','machine_cleanliness_post','RFT-cleanliness-']),
 'cleanliness_modes':all(x in clean for x in ["[ValidateSet('Snapshot','Assert')]",'processLeaks=0 tempArtifacts=0','FAIL machine cleanliness baseline','FAIL machine cleanliness post-run']),
 'cleanliness_runtime_tokens':all(x in clean for x in ['RF-Network-Tool-Launcher.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1']),
 'cleanliness_temp_prefixes':all(x in clean for x in ['RFT-v142-test-','RFT-v142-chaos-','RFT-v142-perf-','RFT-versioned-e2e-','RFT-real-lan-']),
 'cleanliness_state_removed':all(x in clean for x in ['Remove-StateFile','finally{','Unsupported machine-cleanliness state schema.']) and 'Remove-Item -LiteralPath $cleanlinessState' in ps,
 'cleanliness_failure_path_test':all(x in clean_test for x in ['Dirty baseline fails closed','Post-run temp leak fails closed','Process-leak baseline snapshot succeeds','Post-run process leak fails closed','Process-leak assertion removes state file','Clean post-run assertion succeeds','ALL WINDOWS MACHINE CLEANLINESS TESTS PASSED']),
 'ci_cleanliness_failure_path':'Machine cleanliness fail-closed qualification' in ci and 'WINDOWS_MACHINE_CLEANLINESS_TEST_v1_4_2.ps1' in ci,
 'ci_ipv6_privacy_selftest':'Evidence sanitizer IPv6 self-test' in ci and 'RF-Network-Tool-RealMachineQualification.ps1 -SanitizerSelfTest -NoZip' in ci,
 'orchestrator_gui_gate':'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1' in ps and "Mode -in @('Gui','Full')" in ps,
 'orchestrator_lan_skip':'skipExitCodes' in ps and '@(3)' in ps,
 'orchestrator_clean_winps_modulepath':all(x in ps for x in ['Start-CleanWindowsPowerShell','Remove-Item Env:PSModulePath','PowerShellGet -MinimumVersion 2.2.5','PSScriptAnalyzer -RequiredVersion 1.25.0']),
 'orchestrator_child_fail_defense':all(x in ps for x in ['selfReportedFail',"child reported FAIL"]),
 'orchestrator_redirect_handle_release':'orchestrator-error.txt' in ps,
 'orchestrator_redirect_read_retry':all(x in ps for x in ['Read-TextFileWithRetry','Start-Sleep -Milliseconds 100','Read-TextFileWithRetry $stdout 10000']),
 'orchestrator_explicit_winps_module_path':all(x in ps for x in ['Get-CleanWindowsPowerShellModulePath','SpecialFolder]::MyDocuments','WindowsPowerShell\\Modules','System32\\WindowsPowerShell\\v1.0\\Modules','$env:PSModulePath=Get-CleanWindowsPowerShellModulePath']),
 'orchestrator_pssa_install_diagnostics':'psscriptanalyzer_install_diagnostics.txt' in ps and 'CleanPSModulePath=' in ps,
 'e2e_uia_title_normalization':all(x in e2e for x in ['Normalize-UiName',"-replace '&','' -replace '\\s+',' '",'$escapedVersion',"'VERSION'"]),
 'e2e_waits_for_tab_accessibility':all(x in e2e for x in ['$tabWait=[Diagnostics.Stopwatch]::StartNew()','$items.Count -ge 5','Start-Sleep -Milliseconds 200']),
 'e2e_msaa_tab_fallback':all(x in e2e for x in ['AccessibleObjectFromWindow','RftMsaaBridge','SysTabControl32','accDoDefaultAction','MSAA.SysTabControl32','Get-VisibleExpectedPaneNames']),
 'e2e_native_tab_selection_oracle':all(x in e2e for x in ['TCM_GETCURSEL','GetSelectedIndex','ui-tab-selection.txt','MSAA.SysTabControl32+TCM_GETCURSEL','Native TCM_GETCURSEL confirms selected tab']),
 'e2e_msaa_selftest':all(x in e2e for x in ['AccessibilitySelfTest','MSAA TAB ACCESSIBILITY SELF-TEST PASSED','MSAA accDoDefaultAction switches page tab']),
 'e2e_ctrl_tab_fallback':all(x in e2e for x in ['System.Windows.Forms.SendKeys','Microsoft.VisualBasic.Interaction]::AppActivate','ControlType]::Pane','Current.IsOffscreen','CtrlTab+UIAutomation.Pane fallback','ui-tab-provider.txt','$navigationExercised']),
 'e2e_requires_real_navigation':"Assert-True ($navigationExercised -and -not $p.HasExited) 'GUI survives tab navigation'" in e2e,
 'e2e_ui_tree_evidence':all(x in e2e for x in ['ui-tree-dump.txt','ProgrammaticName','AutomationId','ClassName']),
 'e2e_tab_name_normalization':'$normalizedExpected=Normalize-UiName $expected' in e2e,
 'e2e_timeout_uses_argument_string':'Process timeout: $exe $argumentString' in e2e and 'Process timeout: $exe $args' not in e2e,
 'real_lan_private_only':'refusing to probe a public IPv4 subnet' in lan and 'Test-LocalSafeIPv4' in lan,
 'real_lan_not_applicable':'exit 3' in lan and 'no active physical private/link-local/CGNAT' in lan,
 'real_lan_physical_default':'HardwareInterface' in lan and 'VMware|VirtualBox' in lan,
 'real_lan_bounded':'Refusing to probe more than 254 hosts' in lan,
 'real_lan_profiles':"@('FAST','BALANCED')" in lan and 'DEEP' not in lan,
 'real_lan_identity':all(x in lan for x in ['no duplicate result IPs','local IPv4 discovered exactly once','runId matches']),
 'ci_msaa_tab_selftest':'Tab accessibility MSAA fallback self-test' in ci and 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1 -AccessibilitySelfTest' in ci,
 'ci_harness_smoke':'Real-machine qualification harness SAFE smoke' in ci and 'RF-Network-Tool-RealMachineQualification.ps1 -Mode Safe -NoZip' in ci,
 'ci_harness_polluted_modulepath_fixture':all(x in ci for x in ["PowerShell\\7\\Modules","$env:PSModulePath = $ps7Modules + ';' + $env:PSModulePath"]),
 'ci_harness_stress_twice':all(x in ci for x in ['SAFE harness stress pass 1/2','SAFE harness stress pass 2/2']),
 'ci_harness_installer_path':all(x in ci for x in ['Uninstall-Module','-Mode Safe -AllowModuleInstall -NoZip','installer path','reuse installed analyzer']),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)
