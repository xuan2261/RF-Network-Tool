# RF & Network Diagnostic Tool v1.4.2 — Full QA / CI-E2E

This release carries forward the v1.4.1 scan-row deduplication and Ping/Monitoring request-finalization repairs, then hardens Windows PowerShell 5.1 compatibility and the release pipeline using live GitHub Actions execution.

## Runtime and verification changes

- Windows PowerShell 5.1 generic-list handling is hardened with `.ToArray()` where required.
- Deterministic/static contracts run on Python 3.13.
- Hosted Windows integration runs on Windows Server 2022 and 2025 using Windows PowerShell 5.1.
- PSScriptAnalyzer 1.25.0 plus the built-in parser gate syntax/runtime-host compatibility.
- Launcher diagnostic E2E validates STA, WinForms loading, parser sweep, writable data bootstrap, clean startup log, and successful process exit.
- Release packaging depends on all required runtime/static gates and performs manifest/SHA/CRC integrity checks.
- Full-project release ZIPs exclude VCS metadata; generated hashes/manifests are produced from the exact release candidate rather than tracked in Git.
- GitHub Actions use Node 24 generations.
- Interactive WinForms UI automation remains a separate manual self-hosted workflow.

## Verification semantics

A package built locally without hosted-Windows evidence records Windows runtime as `NOT YET VERIFIED`. The CI package job runs only after both hosted Windows lanes pass and writes `EXECUTION PASS` plus the GitHub run/SHA into the generated release manifest.

Interactive desktop UI E2E must still be reported as `NOT YET VERIFIED` until the `rft-interactive` self-hosted workflow actually completes successfully.
