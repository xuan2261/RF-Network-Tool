# RF & Network Diagnostic Tool v1.5.3 — Monitoring Correctness & Discovery Lifecycle Hardening

## Verification exception

**Windows 10 interactive physical qualification was NOT RUN for v1.5.3.**
The release was explicitly authorized without the physical gate because the user did not have access to the laptop at release time.

Do not interpret this release as a Windows 10 physical PASS. The previous v1.5.2 physical evidence is not reused or relabeled as v1.5.3 evidence.

Hosted verification for the v1.5.3 runtime did pass on Windows Server 2022 and Windows Server 2025, together with static/model, lint, chaos/recovery, synthetic performance, launcher E2E, machine-cleanliness, packaging, SBOM, attestation, and reproducibility gates.

## Scope

v1.5.3 hardens Monitoring correctness, long-duration accounting, UI readability, and name-discovery lifecycle handling.

- Collector health (WAITING, PAUSED, STALE, ENGINE ERROR) is separated from the last observed network state.
- Local measurement/collector errors are counted separately and are no longer treated as network packet loss or outages.
- Monitoring accounting uses bounded monotonic timing and rejects stale pre-reset / pre-pause results.
- PingWorker records worker-observed per-target completion timestamps.
- Multi-day UPTIME/DOWNTIME formatting uses whole TimeSpan days correctly.
- Monitoring columns preserve full headers/minimum widths and use horizontal scrolling instead of squeezing 17 columns.
- Opening Device Details reads adapter information without resetting CIDR or scan status.
- Name discovery only reports success when the worker exits 0 and independent run/session-bound terminal evidence proves the requested observation window completed.
- Cancelled, malformed, early, contradictory, and failed discovery terminal states cannot be shown as successful completion.

## Regression coverage

The v1.5.3 native Windows measurement suite covers, among other checks:

- 36-hour duration formatting
- measurement errors excluded from LOSS/OUTAGES
- exact accounting sequence math
- reset epoch rejection
- pause/resume generation rejection
- collector-stop health
- stale-time bounds
- valid 0 ms samples
- discovery early-window rejection
- discovery cancellation terminal semantics
- real Monitoring DataGridView headers at font scales 1.0 / 1.25 / 1.5 / 2.0
- locale-independent observation timestamp parsing, including vi-VN
- Device Details adapter reads with no UI side effects

## Hosted verification evidence

Exact runtime PR head:
`9c49389f83fefc133d7efd1228ef83540d2e366a`

PR CI:
- workflow run `36070746171`: SUCCESS
- Static + deterministic contracts: PASS
- Windows PowerShell 5.1 integration (windows-2022): PASS
- Windows PowerShell 5.1 integration (windows-2025): PASS
- Native measurement correctness and header layout: PASS
- PSScriptAnalyzer 1.25.0 gate: PASS
- Chaos/recovery: PASS
- Synthetic performance: PASS
- Launcher diagnostic E2E: PASS
- Machine cleanliness: PASS
- Reproducible release package: PASS
- SBOM/attestation/reproducibility checks: PASS

Merged runtime commit on main:
`dff1f2d38e0c0063592aef2fcb3271644929b5d8`

Post-merge main CI:
- workflow run `36071327268`: SUCCESS
- Static/model: PASS
- Windows Server 2022: PASS
- Windows Server 2025: PASS
- Reproducible release package: PASS

## Physical qualification status

- Windows 10 interactive Full qualification for v1.5.3: **NOT RUN / NOT VERIFIED**
- reason: user-authorized release without access to the physical laptop
- v1.5.2 physical evidence remains valid only for v1.5.2 and is not carried forward as v1.5.3 evidence

## Release boundary

This release-finalization change only updates version metadata, documentation, the version contract, and a hosted release workflow. Runtime PowerShell code is unchanged from the hosted-CI-verified main commit above.
