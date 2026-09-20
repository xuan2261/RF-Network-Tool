#!/usr/bin/env python3
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
ui=(root/'.github/workflows/ui-e2e-selfhosted.yml').read_text(encoding='utf-8')
lint=(root/'tests/WINDOWS_LINT_GATE_v1_4_2.ps1').read_text(encoding='utf-8-sig')
e2e=(root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').read_text(encoding='utf-8-sig')
checks={
 'ci_push_pr_manual': all(x in ci for x in ['push:','pull_request:','workflow_dispatch:']),
 'ci_least_privilege':'contents: read' in ci,
 'ci_concurrency_cancel':'cancel-in-progress: true' in ci,
 'ci_static_job':'static-contracts:' in ci and 'ubuntu-24.04' in ci and 'run_all_static_v1_4_2.py' in ci,
 'ci_windows_matrix':"os: [windows-2022, windows-2025]" in ci,
 'ci_ps51_integration':'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1' in ci and 'shell: powershell' in ci,
 'ci_psscriptanalyzer_pinned':'PSScriptAnalyzer -RequiredVersion 1.25.0' in ci,
 'ci_lint_gate':'WINDOWS_LINT_GATE_v1_4_2.ps1' in ci,
 'ci_lint_high_signal_rules':all(x in lint for x in ['PSAvoidAssignmentToAutomaticVariable','PSPossibleIncorrectComparisonWithNull','PSScriptAnalyzer high-signal warnings']),
 'ci_launcher_e2e':'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1 -DiagnosticOnly' in ci,
 'ci_hosted_ui_smoke':'Hosted WinForms UI smoke E2E' in ci and 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1 -TimeoutSec 20' in ci,
 'ci_package_needs_runtime':'needs: [static-contracts, windows-runtime]' in ci,
 'ci_package_test':'release_package_test_v1_4_2.py' in ci,
 'ci_static_cleanliness':'Ensure tests do not mutate tracked source' in ci and 'git diff --exit-code' in ci,
 'ci_package_runtime_verified_env':"RFT_WINDOWS_RUNTIME_VERIFIED: '1'" in ci,
 'ci_release_artifacts_staged_in_workspace':'ci-artifacts/release/*.zip' in ci and 'Stage release candidates inside workspace' in ci,
 'ci_release_upload_no_parent_traversal':'../RF-Network-Tool-v1.4.2' not in ci.split('Upload release candidates',1)[-1],
 'ci_artifacts_v7':ci.count('actions/upload-artifact@v7')>=2,
 'ci_no_continue_on_error':'continue-on-error:' not in ci,
 'ci_timeouts':ci.count('timeout-minutes:')>=3,
 'ui_manual_only': 'workflow_dispatch:' in ui and not re.search(r'(?m)^\s{2}(push|pull_request):',ui),
 'ui_selfhosted_interactive':"runs-on: [self-hosted, Windows, X64, rft-interactive]" in ui,
 'ui_e2e_script':'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1' in ui,
 'ui_artifact':'winforms-e2e-evidence' in ui,
 'ci_node24_actions':ci.count('actions/checkout@v7')>=3 and ci.count('actions/setup-python@v7')>=2 and ci.count('actions/upload-artifact@v7')>=2,
 'ui_node24_actions':'actions/checkout@v7' in ui and 'actions/upload-artifact@v7' in ui,
 'ui_script_isolated_sandbox':"RFT-v142-e2e-" in e2e,
 'ui_script_uses_uia':'System.Windows.Automation.AutomationElement' in e2e,
 'ui_capture_avoids_args_automatic_var':"[string]$args" not in e2e and "[string]$argumentString" in e2e,
 'ui_capture_forwards_argument_string':"$psi.Arguments=$argumentString" in e2e,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)
