# Monitoring Dashboard architecture — v1.5.3

## Goal

Continuously monitor saved PING targets without putting network I/O on the WinForms UI thread, while keeping **collector health** separate from the last observed **network state**.

The persistent PingWorker remains the network executor. The UI owns scheduling, request identity, accounting projection, persistence and presentation.

## Runtime path

```text
WinForms MONITORING tab
    |
    | 500-ms scheduler tick (bookkeeping only)
    v
Get due enabled targets
    |
    | attach monitoring epoch + per-target generation
    v
Enqueue-PingRequest(kind=MONITOR)
    |
    v
RF-Network-Tool-PingWorker.ps1
    |-- SendPingAsync
    |-- bounded concurrency
    |-- per-target worker-observed completion timestamp
    `-- result-<id>.json
            |
            v
Apply-PingWorkerResults
    |
    |-- reject wrong epoch / generation / stale request
    v
Apply-MonitorPingResult
    |-- valid ICMP success/failure -> network accounting
    |-- local/malformed/collector error -> measurement error only
    |-- update Current / Min / Avg / Max
    |-- update Success / Failure / Total / Loss
    |-- update observed Uptime / Downtime
    |-- update outage transitions
    `-- bounded persistent transition timeline
```

The WinForms timer is a scheduler/poller, not a network executor.

## Two independent state axes

### Network state

The last valid ICMP observation is one of:

- `UNKNOWN`
- `ONLINE`
- `OFFLINE`

Only valid network samples can change this axis.

### Collector health

The monitoring engine separately projects:

- `OK`
- `WAITING`
- `PAUSED`
- `STALE`
- `ENGINE ERROR`

A local collector/worker failure therefore does **not** become a network outage. The grid and summary derive their displayed status from this health decision without corrupting the underlying network accounting.

## Sample and loss accounting

For a target:

- `SuccessCount` increments only for valid successful ICMP observations.
- `FailureCount` increments only for valid network-offline observations.
- `TotalCount = SuccessCount + FailureCount`.
- `LOSS = FailureCount / TotalCount * 100`.
- `MeasurementErrorCount` is separate and excluded from `LOSS`.
- a successful `0 ms` response remains valid.

`OK/TOTAL` displays `SuccessCount/TotalCount`; its tooltip also exposes network failures and measurement-error count.

## Duration accounting

UPTIME/DOWNTIME are **observed ICMP-state durations**, not operating-system uptime.

Accounting uses a monotonic clock and a freshness lease. It does not extrapolate indefinitely across:

- sleep/resume gaps;
- stale collector periods;
- engine failures;
- paused monitoring;
- unknown state.

Multi-day formatting uses `TimeSpan.Days` rather than rounding fractional `TotalDays`.

## Reset, pause and stale-result policy

A statistics reset rotates a monitoring **epoch**.

A target pause/resume rotates that target's **generation**.

Every monitoring request carries the epoch and target generation that were current when the request was sent. Results or missing-result errors from older epochs/generations are rejected, preventing in-flight work from contaminating a fresh session.

Manual PING still has priority over older monitoring results through the existing request-freshness guard.

## Persistence

`RF-Network-Tool.monitoring.json` stores per-target settings:

- Enabled
- IntervalSec
- Alert

`RF-Network-Tool.monitoring-history.json` stores the bounded transition timeline (maximum 500 records).

Session statistics are intentionally not persisted. Restart or Reset statistics starts a new statistical horizon while retaining the transition timeline until the user clears it.

## UI contract

The Monitoring grid exposes:

- STATUS
- NOW
- MIN ms
- AVG ms
- MAX ms
- OK/TOTAL
- LOSS
- UPTIME
- DOWNTIME
- OUTAGES
- LAST SAMPLE
- LAST CHANGE

The grid uses measured minimum widths, frozen identification columns, full header tooltips and horizontal scrolling. It must not shrink 17 columns until headers become ambiguous.

`LAST SAMPLE` is the last accepted monitoring observation timestamp. `LAST CHANGE` is the last network-state transition timestamp; they are intentionally different.

## Alerts

Alerts occur only on meaningful network-state transitions after the initial UNKNOWN state. Repeated OFFLINE samples do not create repeated outage events or modal dialogs.

Collector errors do not masquerade as outage alerts.

## Current limitation

Monitoring remains ICMP-based. A device that blocks ICMP can be `L2 Seen` in Network Scan while appearing OFFLINE in Monitoring.

Worker-observed sample timestamps are application timestamps, not NIC/hardware packet timestamps.

Windows 10 interactive physical Full qualification for v1.5.3 was not run at publication time; hosted Windows Server 2022/2025 coverage does not replace that physical evidence.
