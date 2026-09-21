#!/usr/bin/env python3
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
ui=(root/'.github/workflows/ui-e2e-selfhosted.yml').read_text(encoding='utf-8')
actionlint_cfg=(root/'.github/actionlint.yaml').read_text(encoding='utf-8')
lint=(root/'tests/WINDOWS_LINT_GATE_v1_4_2.ps1').read_text(encoding='utf-8-sig')
e2e=(root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').read_text(encoding='utf-8-sig')
checks={
 'ci_push_main_pr_manual': all(x in ci for x in ['push:','branches: [main]','pull_request:','workflow_dispatch:']),
 'ci_least_privilege':'contents: read' in ci,
 'ci_concurrency_cancel':'cancel-in-progress: true' in ci,
 'ci_static_job':'static-contracts:' in ci and 'ubuntu-24.04' in ci and 'run_all_static_v1_4_2.py' in ci,
 'ci_actionlint_pinned':all(x in ci for x in ["ACTIONLINT_VERSION: '1.7.12'","ACTIONLINT_SHA256: '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'",'rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}']),
 'ci_actionlint_checksum_verified':all(x in ci for x in ['sha256sum -c -','tar -xzf', '"$RUNNER_TEMP/actionlint" -color']),
 'ci_actionlint_https_only':all(x in ci for x in ["--proto '=https'","--proto-redir '=https'",'--tlsv1.2']),
 'ci_actionlint_selfhosted_label':all(x in actionlint_cfg for x in ['self-hosted-runner:','labels:','rft-interactive']),
 'ci_actionlint_shell_fixes':'for _ in 1 2 3 4 5; do' in ci and 'sha256sum -- *.zip' in ci,
 'ci_windows_matrix':"os: [windows-2022, windows-2025]" in ci,
 'ci_ps51_integration':'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1' in ci and 'shell: powershell' in ci,
 'ci_psscriptanalyzer_pinned':'PSScriptAnalyzer -RequiredVersion 1.25.0' in ci,
 'ci_lint_gate':'WINDOWS_LINT_GATE_v1_4_2.ps1' in ci,
 'ci_lint_high_signal_rules':all(x in lint for x in ['PSAvoidAssignmentToAutomaticVariable','PSPossibleIncorrectComparisonWithNull','PSScriptAnalyzer high-signal warnings']),
 'ci_lint_warning_baseline':all(x in lint for x in ['PSAvoidUsingEmptyCatchBlock','diagnostic baseline regression','new diagnostic rule']),
 'ci_chaos_gate':'WINDOWS_CHAOS_TEST_v1_4_2.ps1' in ci,
 'ci_performance_gate':'WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1' in ci,
 'ci_launcher_e2e':'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1 -DiagnosticOnly' in ci,
 'ci_cleanliness_failure_path':'Machine cleanliness fail-closed qualification' in ci and 'WINDOWS_MACHINE_CLEANLINESS_TEST_v1_4_2.ps1' in ci,
 'ci_real_machine_safe_smoke':'Real-machine qualification harness SAFE smoke' in ci and 'RF-Network-Tool-RealMachineQualification.ps1 -Mode Safe -NoZip' in ci and 'real-machine-results/**' in ci,
 'ci_hosted_ui_diagnostic_only':ci.count('WINDOWS_LAUNCHER_E2E_v1_4_2.ps1')==1 and 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1 -DiagnosticOnly' in ci,
 'ci_package_needs_runtime':'needs: [static-contracts, windows-runtime]' in ci,
 'ci_package_test':'release_package_test_v1_4_2.py' in ci and 'release_tools/build_release.py' in ci,
 'ci_static_cleanliness':'Ensure tests do not mutate tracked source' in ci and 'git diff --exit-code' in ci,
 'ci_package_runtime_verified_env':"RFT_WINDOWS_RUNTIME_VERIFIED: '1'" in ci,
 'ci_package_stable_source_revision':"RFT_SOURCE_REVISION: ${{ github.event.pull_request.head.sha || github.sha }}" in ci,
 'ci_package_byte_reproducibility':'Byte reproducibility test' in ci and 'reproducible_package_test_v1_4_2.py' in ci,
 'ci_release_artifacts_staged_in_workspace':'ci-artifacts/release/*.zip' in ci and 'Stage release candidates inside workspace' in ci,
 'ci_release_attestation':all(x in ci for x in ['actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6','id-token: write','attestations: write','gh attestation verify']),
 'ci_release_upload_no_parent_traversal':'../RF-Network-Tool-v1.4.2' not in ci.split('Upload release candidates',1)[-1],
 'ci_version_single_source':all(x in ci for x in ["tags: ['v*.*.*']",'Resolve release version','VERSION','steps.version.outputs.version','needs.package.outputs.artifact_name']),
 'ci_actions_pinned_sha':ci.count('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1')>=3 and ci.count('actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97')>=2 and ci.count('actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a')>=2,
 'ci_no_continue_on_error':'continue-on-error:' not in ci,
 'ci_timeouts':ci.count('timeout-minutes:')>=4,
 'ci_release_job_tag_only':"name: Publish GitHub Release" in ci and "tags: ['v*.*.*']" in ci and "startsWith(github.ref, 'refs/tags/v')" in ci,
 'ci_release_job_needs_package':'needs: [package]' in ci.split('name: Publish GitHub Release',1)[1],
 'ci_release_job_write_scoped':all(x in ci.split('name: Publish GitHub Release',1)[1] for x in ['permissions:','contents: write']),
 'ci_release_download_pinned':'actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131' in ci,
 'ci_release_assets':all(x in ci for x in ['gh release create','SHA256SUMS.txt','RF-Network-Tool-v${RELEASE_VERSION}-FULL-QA-CI-E2E-PORTABLE.zip','RF-Network-Tool-v${RELEASE_VERSION}-FULL-QA-CI-E2E-PROJECT.zip']),
 'ci_release_fail_closed':all(x in ci for x in ['Tag/version mismatch','Refusing to overwrite existing release','DRAFT RELEASE ASSET VERIFICATION PASSED','RELEASE ASSET VERIFICATION PASSED']),
 'ci_release_draft_first':all(x in ci for x in ['--draft','--draft=false','release-view-draft.json']),

 'ui_manual_only': 'workflow_dispatch:' in ui and not re.search(r'(?m)^\s{2}(push|pull_request):',ui),
 'ui_selfhosted_interactive':"runs-on: [self-hosted, Windows, X64, rft-interactive]" in ui,
 'ui_interactive_preflight':'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1' in ui,
 'ui_e2e_script':all(x in ui for x in ['RF-Network-Tool-RealMachineQualification.ps1',"'"+'-Mode'+"','"+ 'Full' +"'",'interactive_gui_e2e must PASS']) and '-DiagnosticOnly' not in ui,
 'ui_artifact':'physical-qualification-evidence' in ui,
 'ui_exact_head_guard':all(x in ui for x in ['expected_sha:','RFT_EXPECTED_SHA: ${{ inputs.expected_sha }}','git rev-parse HEAD',"^[0-9a-f]{40}$",'Revision mismatch']),
 'ui_full_physical_harness':all(x in ui for x in ['RF-Network-Tool-RealMachineQualification.ps1',"'"+'-Mode'+"','"+ 'Full' +"'",'real_lan_fast_balanced']),
 'ui_harness_revision_parity':all(x in ui for x in ['-ExpectedSourceRevision','harnessSourceRevision','Harness source revision mismatch']),
 'ui_requires_physical_pass':all(x in ui for x in ["interactive_gui_e2e must PASS","real_lan_fast_balanced must PASS","SKIP is not release qualification"]),
 'ui_requires_machine_cleanliness':all(x in ui for x in ['machine_cleanliness_baseline must PASS','machine_cleanliness_post must PASS','machineCleanlinessBaseline','machineCleanlinessPost']),
 'ui_sanitized_evidence':all(x in ui for x in ['physical-safe','physical-qualification-summary.json','ui-tab-items.txt','Remove raw physical-network evidence','Remove-Item -LiteralPath .\\real-machine-results','Remove-Item -LiteralPath .\\ci-artifacts']),
 'ui_input_not_injected_into_run':'${{ inputs.interface_index }}' not in ui.split('run: |',1)[-1] and 'RFT_INTERFACE_INDEX: ${{ inputs.interface_index }}' in ui,
 'ui_structural_uniqueness':all(ui.count(x)==1 for x in ['- name: Exact revision guard','- name: Run full physical qualification','- name: Stage safe evidence and assert required physical gates','- name: Upload sanitized physical evidence']),
 'ui_positive_interface_validation':"if($env:RFT_INTERFACE_INDEX -notmatch '^[1-9]\\d*$')" in ui,
 'ui_stale_evidence_cleared_before_revision':ui.index('Remove-Item -LiteralPath .\\real-machine-results') < ui.index('$actual=(git rev-parse HEAD)'),
 'ui_raw_network_evidence_not_uploaded':'path: ci-artifacts/physical-safe/**' in ui and 'path: ci-artifacts/**' not in ui and 'real-machine-results/**' not in ui,
 'ci_node24_actions':ci.count('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1')>=3 and ci.count('actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97')>=2 and ci.count('actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a')>=2,
 'ui_node24_actions':'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' in ui and 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' in ui,
 'ui_script_isolated_sandbox':"RFT-versioned-e2e-" in e2e,
 'ui_script_uses_uia':'System.Windows.Automation.AutomationElement' in e2e,
 'ui_capture_avoids_args_automatic_var':"[string]$args" not in e2e and "[string]$argumentString" in e2e,
 'ui_capture_forwards_argument_string':"$psi.Arguments=$argumentString" in e2e,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)
