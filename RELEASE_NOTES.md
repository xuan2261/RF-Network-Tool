# RF & Network Diagnostic Tool v1.5.2 — Identity, Monitoring & Deep-Analysis Hardening

## Scope

v1.5.2 is a correctness and operability release built on v1.5.1 route-aware scanning.

- Device-history naming is now MAC-bound and provenance-gated instead of reusing a historical name by IP alone.
- Historical fallback names are prevented from being written back into a different device identity.
- Deep Analysis / Refresh now uses shared mutable WinForms callback state, startup heartbeat tracking, and a bounded fail-closed watchdog.
- Deep analysis preserves name provenance when UPnP supplies a friendly name.
- Monitoring exposes OK/TOTAL samples, last-sample time, session start, and explicit millisecond units.
- Monitoring renders the full retained timeline rather than silently truncating display to 200 rows.
- Network scanning records per-phase timings and distinguishes core scan time from end-to-end discovery time.
- The Windows 10 physical qualification now includes a release-critical deep_ui_e2e gate that opens Device Details and invokes the real Phân tích sâu / Refresh button path.

## Correctness fixes

### Device identity / history

v1.5.1 could reuse a historical hostname when a different MAC later received the same IPv4 address. v1.5.2 removes IP-only history autofill when a MAC is known, requires provenance-bearing exact-MAC history, and prevents History-derived names from re-poisoning the identity store.

### Deep Analysis / Refresh

The Device Details dialog previously used multiple local variables across separate WinForms callback scriptblocks. v1.5.2 consolidates mutable worker lifecycle state, records heartbeat phase/progress, and aborts boundedly if startup never becomes observable.

### Monitoring

The dashboard now makes the statistical horizon auditable with OK/TOTAL, LAST SAMPLE, and Stats since. MIN/AVG/MAX headers explicitly use milliseconds. The retained timeline and displayed timeline now have the same upper bound.

## Verification evidence

Exact runtime head before merge:
`bda75e02be48ba55806c7a2c161cfcf8680508df`

Windows 10 physical qualification:
- workflow run `36024657880`
- interactive_gui_e2e: PASS
- deep_ui_e2e: PASS
- deep-ui-e2e.json: PASS / completed
- workerCompleted: true
- workerSucceeded: true
- lastPhase: Completed
- route_scope_planner: PASS
- route_scope_live: PASS
- real_lan_fast_balanced: PASS
- machine cleanliness baseline/post: PASS
- aggregate: 17 PASS / 0 FAIL / 0 SKIP
- physical evidence artifact SHA-256: `352d9e577f48a55addb6a23119e7118b36a8e4b8bab34437612dbc8fa3c5cd3d`

Post-merge main commit:
`ea2f6c8cef08afcc495bdcc9bd4c8b83eb8908b5`

Post-merge hosted CI:
- workflow run `36026333412`: SUCCESS
- static/model: PASS
- Windows PowerShell 5.1 integration on Windows Server 2022: PASS
- Windows PowerShell 5.1 integration on Windows Server 2025: PASS
- reproducible release package: PASS

## Release boundary

This release-finalization change is metadata/documentation only. Runtime code is unchanged from the physically qualified and post-merge CI-verified v1.5.2 implementation.
