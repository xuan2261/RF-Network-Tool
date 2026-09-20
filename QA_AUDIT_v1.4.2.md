# QA Audit v1.4.2 — Full QA / CI-E2E

## Scope

Verification infrastructure and runtime-regression audit for RF-Network-Tool v1.4.2, including defects discovered only after executing on GitHub-hosted Windows PowerShell 5.1.

## Executed evidence

- Active deterministic/static suites execute in GitHub Actions and are required to pass before packaging.
- Windows PowerShell 5.1 integration executes independently on `windows-2022` and `windows-2025`.
- The built-in PowerShell parser covers the launcher, main script, and four workers.
- PSScriptAnalyzer 1.25.0 executes on both Windows lanes; Error/ParseError findings are release-blocking.
- Launcher diagnostic E2E executes the real launcher in STA mode and verifies WinForms/parser/startup-log gates.
- Release packaging is gated behind static + both Windows lanes, followed by package integrity and CRC checks.
- Release artifacts are staged inside the Actions workspace before upload.
- GitHub Actions dependencies use current Node 24 generations (`checkout@v7`, `setup-python@v7`, `upload-artifact@v7`).

## Defects found and repaired during live CI

1. **Windows PowerShell 5.1 generic-list enumeration** — `@($list)` on `List[object]` caused runtime `Argument types do not match`. Runtime paths were changed to `.ToArray()` and regression guards were added.
2. **DEEP integration assertion** — the test incorrectly counted open ports instead of performed `PortChecks`; the test contract was corrected.
3. **Launcher E2E argument forwarding** — the helper used the PowerShell automatic variable name `$args`, so the child process lost `-STA -File ... -Diagnostic`. It now uses `$argumentString` with dedicated regression guards.
4. **Artifact upload path** — `upload-artifact` rejects parent traversal (`../`). Release candidates are now staged under `ci-artifacts/release/`.
5. **Full-project package contamination** — audit of a real Actions artifact found `.git` metadata inside the project ZIP. The release builder and package tests now exclude/reject VCS metadata.
6. **Generated verification metadata** — `BUILD_CHECKS_v1.4.2.json`, `RELEASE_MANIFEST_v1.4.2.json`, and `SHA256.txt` are generated outputs and are no longer tracked in Git, preventing stale hashes/status from living in source control.

## Verification status

- **EXECUTION PASS**: deterministic/static contracts on hosted CI.
- **EXECUTION PASS**: Windows PowerShell 5.1 runtime integration on Windows Server 2022.
- **EXECUTION PASS**: Windows PowerShell 5.1 runtime integration on Windows Server 2025.
- **EXECUTION PASS**: PSScriptAnalyzer Error/ParseError gate and launcher diagnostic E2E on both hosted Windows lanes.
- **EXECUTION PASS**: reproducible package build/integrity gate and uploaded release artifact.
- **NOT YET VERIFIED**: interactive WinForms UI automation requiring a logged-in self-hosted Windows runner labeled `rft-interactive`.

Hosted diagnostic E2E is real execution, but it is not represented as full interactive desktop UI E2E. The latter remains intentionally separate and must not be claimed as passed until that workflow actually runs green.
