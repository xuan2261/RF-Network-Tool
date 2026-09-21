# RF & Network Diagnostic Tool v1.4.2 — Full QA / CI-E2E

This release carries forward the v1.4.1 scan-row deduplication and Ping/Monitoring request-finalization repairs, then hardens Windows PowerShell 5.1 compatibility and the release pipeline using live GitHub Actions execution.

## Runtime and verification changes

- Windows PowerShell 5.1 generic-list handling is hardened with `.ToArray()` where required.
- Deterministic/static contracts run on Python 3.13.
- Hosted Windows integration runs on Windows Server 2022 and 2025 using Windows PowerShell 5.1.
- PSScriptAnalyzer 1.25.0 plus the built-in parser gate syntax/runtime-host compatibility.
- Automatic-variable assignment and unsafe right-sided `$null` comparison diagnostics are release-blocking.
- Launcher diagnostic E2E validates STA, WinForms loading, parser sweep, writable data bootstrap, clean startup log, and successful process exit.
- Release packaging depends on all required runtime/static gates and performs manifest/SHA/CRC integrity checks.
- Full-project release ZIPs exclude VCS metadata; generated hashes/manifests are produced from the exact release candidate rather than tracked in Git.
- GitHub Actions use Node 24 generations.
- Interactive WinForms UI automation remains a separate manual self-hosted workflow.

## Verification semantics

A package built locally without hosted-Windows evidence records Windows runtime as `NOT YET VERIFIED`. The CI package job runs only after both hosted Windows lanes pass and writes `EXECUTION PASS` plus the GitHub run/SHA into the generated release manifest.

Interactive desktop UI E2E must still be reported as `NOT YET VERIFIED` until the `rft-interactive` self-hosted workflow actually completes successfully.


## Download and run

For normal use, download **`RF-Network-Tool-v1.4.2-FULL-QA-CI-E2E-PORTABLE.zip`** from the GitHub **Releases** page. Extract the ZIP to a writable folder, then launch **`START-RF-NETWORK-TOOL.vbs`** or **`RUN-PORTABLE.cmd`**.

The **PROJECT.zip** asset contains the full source/tests/workflows and is intended for development or auditing rather than day-to-day use.

The release also publishes **`SHA256SUMS.txt`** so the downloaded ZIP and companion SBOM can be checked against the exact CI-produced assets.

Each PROJECT/PORTABLE ZIP has a deterministic **SPDX 2.3 JSON SBOM** companion. The SBOM is derived from the exact ZIP contents, binds every archived file to SHA-1/SHA-256 checksums, and binds the package to the release ZIP SHA-256.

## Additional hardening in the release pipeline

- malformed/stale IPC and worker restart/parent-death recovery are exercised by Windows chaos tests;
- synthetic /24 scan and 128-target persistent PingWorker throughput are gated on Windows Server 2022 and 2025;
- high-confidence secret/dangerous workflow patterns are audited;
- release ZIPs receive GitHub build-provenance attestations and are verified before publication;
- each release ZIP also receives a GitHub SBOM attestation using its deterministic SPDX 2.3 document, and CI verifies the SPDX predicate before upload/publication;
- GitHub Releases publication runs only after the complete static + Windows + package chain has passed on a push to `main`.

Full interactive WinForms UIAutomation remains **NOT YET VERIFIED** until a logged-in self-hosted Windows runner labeled `rft-interactive` executes that workflow successfully.
