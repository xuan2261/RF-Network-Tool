# Windows Smoke Test v1.4.2 Full QA / CI-E2E

1. Run `RUN-DIAGNOSTIC.cmd`; expect PASS.
2. Run `RUN-TESTS.cmd`; expect `ALL WINDOWS INTEGRATION TESTS PASSED`.
3. Start `START-RF-NETWORK-TOOL.vbs`; no console/JIT dialog should remain.
4. PING: load 10+ saved targets, rename one, close/reopen and confirm one row per target.
5. PING: run single Ping and Ping All while resizing/changing tabs; UI must stay responsive.
6. MONITORING: press `Đồng bộ từ PING`, enable at least 2 targets, use 1s and 5s intervals, verify NOW/MIN/AVG/MAX/LOSS update without Ping log spam.
7. MONITORING: disconnect/reconnect one reachable test device; verify one ONLINE->OFFLINE outage transition and recovery, timeline entry and optional non-modal ALERT if enabled.
8. MONITORING: disable a target and confirm its uptime/downtime counters stop advancing until re-enabled.
9. NETWORK SCAN: FAST/BALANCED/DEEP on a /24; UI stays responsive and L2 Seen still appears for ARP-only devices.
10. Device Details: Deep Analysis and OPEN PORTS continue to work in background.
11. RF/RJ45: Start UDP and optional RF Ping; verify monitoring does not block RF controls.
12. Close app while monitoring/scan/deep tasks are active; confirm worker processes exit and no stale UI appears after restart.


## Runtime-integrity regressions

- Network Scan: during one scan, each IP appears in **one row only**; MAC/OUI/name enrichment updates that row in place.
- PING: after **Ping tất cả**, no target may remain at `Đang ping nền...` beyond the worker watchdog; worker/IPC failure must become `ERROR | ...`.
- MONITORING: enabled targets should move through `WAITING`/`PENDING` to `ONLINE` or `OFFLINE`; an IPC/worker failure is `ENGINE ERROR`, not a false network outage.
- Repeat FAST/BALANCED/DEEP scans and confirm displayed row count does not grow from duplicate IP rows.