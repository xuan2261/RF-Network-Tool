# RF & Network Diagnostic Tool v1.4.2 — Full QA / CI-E2E

This release hardens verification rather than changing network-discovery behavior. It carries forward the v1.4.1 scan-row deduplication and Ping/Monitoring request-finalization fixes and adds CI, Windows PowerShell 5.1 integration coverage, PSScriptAnalyzer, and interactive WinForms smoke E2E infrastructure.

## Verification model

- Cross-platform deterministic/static contracts: executable on Python 3.13.
- Hosted Windows integration: targets Windows Server 2022 and 2025 using Windows PowerShell 5.1.
- PowerShell lint/parser: PSScriptAnalyzer 1.25.0 plus the built-in PowerShell parser.
- GUI E2E: manual self-hosted workflow requiring a logged-in interactive Windows session.

A packaged release must not be described as Windows-runtime verified until the Windows jobs have actually run green on the exact revision.