# v1.5.3 release — measurement correctness and discovery lifecycle

v1.5.3 was developed from the published v1.5.2 baseline and released from commit
`1ae01b7b4e3da80f80d004f0b41f5e4929605128`.

The user explicitly authorized publication while the Windows 10 physical laptop was unavailable. Therefore Windows 10 interactive physical qualification remains **NOT RUN / NOT VERIFIED** for v1.5.3 and is not represented as a PASS.

## Accepted scope

- Collector health (`OK / WAITING / PAUSED / STALE / ENGINE ERROR`) is separate from the last observed network state.
- Local measurement exceptions are counted separately and excluded from the ICMP network-loss denominator and outage counter.
- Accounting uses monotonic timestamps with a freshness cap; display projections do not mutate committed accounting.
- Reset rotates a statistics epoch. Pause/resume rotates the target generation. Late old work cannot change a new statistics session.
- PingWorker records worker-observed completion timestamps per target. These are not hardware packet timestamps.
- Multi-day durations use whole `TimeSpan.Days`.
- Monitoring columns have measured minimum widths, full headers, frozen identification columns and horizontal scrolling.
- Device Details reads selected-adapter information without resetting CIDR/status.
- Name discovery requires process exit 0 plus matching session/run terminal `SUCCESS` evidence proving the requested observation window completed.
- Missing, malformed, cancelled, early, contradictory and failed discovery evidence cannot be green.
- Final scan summary retains Online, L2, NDP6 and IPv4 counts plus core/total time.

## Verification model

`tests/WINDOWS_MEASUREMENT_TEST_v1_5_3.ps1` executes production-function ASTs with controlled clock and I/O/UI boundaries. It covers accounting, measurement errors, epochs/generations, long durations, discovery terminal policy and real DataGridView header sizing.

Existing Windows integration also exercises the real discovery worker, invalid input, explicit cancellation, PingWorker timestamps, launcher diagnostics and related runtime contracts.

### Hosted evidence

Runtime PR head:
`9c49389f83fefc133d7efd1228ef83540d2e366a`

- PR CI `36070746171`: SUCCESS
- post-merge runtime CI `36071327268`: SUCCESS

Release-finalization commit:
`1ae01b7b4e3da80f80d004f0b41f5e4929605128`

- finalization/main CI `36080645401`: SUCCESS
- publication workflow `36081055104`: SUCCESS
- static/model, Windows Server 2022/2025, native measurement, lint, chaos/recovery, synthetic performance, packaging, SPDX SBOM, attestations and reproducibility: PASS

### Physical evidence

Windows 10 interactive Full qualification for v1.5.3: **NOT RUN / NOT VERIFIED**.

v1.5.2 physical evidence is valid only for v1.5.2 and must not be relabeled as v1.5.3 evidence.

Physical backfill is tracked in GitHub Issue #21. If that future run finds a defect, v1.5.3 remains unchanged and the fix belongs in v1.5.4+.

## Release and supply-chain status

The public v1.5.3 release is:
https://github.com/xuan2261/RF-Network-Tool/releases/tag/v1.5.3

The release contains the portable ZIP, project ZIP, two SPDX SBOM files and `SHA256SUMS.txt`.

At the latest documentation refresh, the v1.5.3 Release API reports `immutable=false`. Repository release immutability is tracked in Issue #22. GitHub documents that enabling repository release immutability applies to future releases only; it does not retroactively make v1.5.3 immutable.

Do not move the v1.5.3 tag or replace its release assets to correct later defects.

## Known evidence boundary

The earlier observation where a DEEP scan showed only a small residual time beyond core scanning cannot be assigned a historical root cause without that run's logs. v1.5.3 fixes the fail-open behavior: an early/crashed discovery worker can no longer be presented as successful solely because the process exited.

Hosted control/layout tests are not proof of every Windows display/DPI/topology combination. See `STATUS_v1.5.3.md` for current open follow-ups.
