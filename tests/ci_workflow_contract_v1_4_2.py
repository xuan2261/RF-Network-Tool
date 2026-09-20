#!/usr/bin/env python3
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
ui=(root/'.github/workflows/ui-e2e-selfhosted.yml').read_text(encoding='utf-8')
checks={
 'ci_push_pr_manual': all(x in ci for x in ['push:','pull_request:','workflow_dispatch:']),
 'ci_least_privilege':'contents: read' in ci,
 'ci_concurrency_cancel':'cancel-in-progress: true' in ci,
 'ci_static_job':'static-contracts:' in ci and 'ubuntu-24.04' in ci and 'run_all_static_v1_4_2.py' in ci,
 'ci_windows_matrix':"os: [windows-2022, windows-2025]" in ci,
 'ci_ps51_integration':'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1' in ci and 'shell: powershell' in ci,
 'ci_psscriptanalyzer_pinned':'PSScriptAnalyzer -RequiredVersion 1.25.0' in ci,
 'ci_lint_gate':'WINDOWS_LINT_GATE_v1_4_2.ps1' in ci,
 'ci_launcher_e2e':'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1 -DiagnosticOnly' in ci,
 'ci_package_needs_runtime':'needs: [static-contracts, windows-runtime]' in ci,
 'ci_package_test':'release_package_test_v1_4_2.py' in ci,
 'ci_artifacts_v4':ci.count('actions/upload-artifact@v4')>=2,
 'ci_no_continue_on_error':'continue-on-error:' not in ci,
 'ci_timeouts':ci.count('timeout-minutes:')>=3,
 'ui_manual_only': 'workflow_dispatch:' in ui and not re.search(r'(?m)^\s{2}(push|pull_request):',ui),
 'ui_selfhosted_interactive':"runs-on: [self-hosted, Windows, X64, rft-interactive]" in ui,
 'ui_e2e_script':'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1' in ui,
 'ui_artifact':'winforms-e2e-evidence' in ui,
 'ui_script_isolated_sandbox':"RFT-v142-e2e-" in (root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').read_text(encoding='utf-8-sig'),
 'ui_script_uses_uia':'System.Windows.Automation.AutomationElement' in (root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').read_text(encoding='utf-8-sig'),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)