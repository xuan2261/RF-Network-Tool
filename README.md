# RF-Network-Tool

Portable Windows RF & network diagnostics tool built for Windows PowerShell 5.1 + WinForms.

## Current stable release

**v1.5.3 — Monitoring correctness and discovery lifecycle hardening**

- Release: https://github.com/xuan2261/RF-Network-Tool/releases/tag/v1.5.3
- Release commit: `1ae01b7b4e3da80f80d004f0b41f5e4929605128`
- Portable asset: `RF-Network-Tool-v1.5.3-FULL-QA-CI-E2E-PORTABLE.zip`
- Project asset: `RF-Network-Tool-v1.5.3-FULL-QA-CI-E2E-PROJECT.zip`
- Public checksums: `SHA256SUMS.txt` on the GitHub Release

### Verification status

| Gate | v1.5.3 status |
| --- | --- |
| Static / deterministic contracts | PASS |
| Windows PowerShell 5.1 — Windows Server 2022 | PASS |
| Windows PowerShell 5.1 — Windows Server 2025 | PASS |
| Native Monitoring correctness + layout regression suite | PASS |
| PSScriptAnalyzer 1.25.0 | PASS |
| Chaos / recovery + synthetic performance | PASS |
| Launcher diagnostic E2E + machine-cleanliness gates | PASS |
| Reproducible package + SPDX SBOM + attestations | PASS |
| Windows 10 interactive physical Full qualification | **NOT RUN / NOT VERIFIED** |

The release was explicitly published without the Windows 10 physical gate because the physical laptop was unavailable. The earlier v1.5.2 physical result is **not** reused as v1.5.3 evidence.

See [STATUS_v1.5.3.md](STATUS_v1.5.3.md) for the exact CI runs, release-asset digests, open follow-up gates, and current supply-chain status.

## What v1.5.3 changes

### Monitoring

- Separates **collector health** (`WAITING`, `PAUSED`, `STALE`, `ENGINE ERROR`) from the last observed network state.
- Local measurement/collector exceptions are counted separately and are excluded from ICMP `LOSS` and outage accounting.
- Uses reset epochs and per-target generations so late pre-reset / pre-pause results cannot corrupt a new statistics session.
- Uses monotonic/freshness-bounded accounting for observed online/offline durations.
- Keeps successful `0 ms` samples valid.
- Correctly formats multi-day durations.
- Shows full Monitoring headers with measured minimum widths and horizontal scrolling instead of squeezing the table.
- Exposes `OK/TOTAL`, `LAST SAMPLE`, `LAST CHANGE`, and detailed tooltips for sample and timeout semantics.

Monitoring durations are **observed ICMP-state durations**, not device operating-system uptime. `LOSS` is based on valid network-response samples; local measurement errors do not enter its denominator.

### Network Scan and discovery

- FAST / BALANCED / DEEP scanning remains asynchronous.
- ICMP, active ARP, IPv4 neighbor evidence, passive IPv6 NDP, and optional route-aware RFC1918 scopes are retained.
- Opening Device Details reads adapter information without resetting the CIDR or scan status.
- Name discovery is fail-closed: success requires process exit 0 plus matching session/run terminal evidence proving the requested observation window completed.
- Missing, malformed, cancelled, early, contradictory, or failed discovery terminal evidence is not displayed as successful completion.

### Identity and Deep Analysis

v1.5.2 identity hardening remains in place:

- historical names are MAC-bound and provenance-gated;
- IP-only historical hostname reuse is not trusted when a MAC is known;
- History-derived names cannot silently poison a different MAC identity;
- Deep Analysis / Refresh uses shared worker lifecycle state and bounded startup/progress handling.

## Main capabilities

- Multi-target PING with persistent aliases
- RF / RJ45 UDP inspection
- FAST / BALANCED / DEEP IPv4 network scanning
- Passive IPv6 neighbor snapshot
- Optional bounded route-aware private multi-subnet planning
- Device history and discovery evidence
- Background Deep Analysis / common-port probes
- Continuous Monitoring dashboard
- IEEE OUI cache/update workflow
- Portable launcher, runtime diagnostics, logs, deterministic CI and reproducible release packaging

## Quick start

1. Download the **PORTABLE** ZIP from the v1.5.3 release.
2. Extract the whole archive into a new writable folder.
3. Run `RUN-DIAGNOSTIC.cmd`.
4. If diagnostic reports PASS, launch with `START-RF-NETWORK-TOOL.vbs` or `RUN-PORTABLE.cmd`.
5. Keep older data/runtime folders separate until the new copy has been checked on the target PC.

Do not mix runtime files from different releases.

## Documentation map

- [README.txt](README.txt) — portable operator guide and troubleshooting
- [RELEASE_NOTES.md](RELEASE_NOTES.md) — published v1.5.3 release scope and verification exception
- [STATUS_v1.5.3.md](STATUS_v1.5.3.md) — current post-release status, evidence, checksums and open follow-ups
- [MEASUREMENT_HARDENING_v1.5.3.md](MEASUREMENT_HARDENING_v1.5.3.md) — design/verification contract for the v1.5.3 hardening
- [MONITORING_DASHBOARD_ARCHITECTURE.md](MONITORING_DASHBOARD_ARCHITECTURE.md) — current Monitoring architecture and accounting semantics
- historical v1.4.x audit/release documents remain historical references, not the current verification source

## Release integrity

The v1.5.3 GitHub Release was produced from a successful hosted main CI run and contains two ZIPs, two SPDX SBOM documents, and `SHA256SUMS.txt`.

Current release immutability is **not enabled** for v1.5.3. GitHub release immutability, when enabled at repository level, applies to future releases only. The project tracks this follow-up separately; existing v1.5.3 tag/assets should not be moved or replaced.

If v1.5.3 later fails physical qualification, keep v1.5.3 unchanged and fix the defect in a new patch release (v1.5.4+).
