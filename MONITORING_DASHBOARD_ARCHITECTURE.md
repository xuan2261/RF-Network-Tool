# Monitoring Dashboard architecture — v1.4.0

## Goal

Add continuous monitoring for saved PING targets without returning network I/O to the WinForms UI thread. The monitoring layer reuses the persistent PingWorker introduced in v1.3.3 and keeps the Network Scan / Discovery / TaskWorker boundaries unchanged.

## Runtime path

```text
WinForms MONITORING tab
    |
    | 500-ms scheduler tick (bookkeeping only)
    v
Enqueue-PingRequest(kind=MONITOR)
    |
    v
RF-Network-Tool-PingWorker.ps1
    |-- SendPingAsync
    |-- bounded concurrency
    `-- result-<id>.json
            |
            v
Apply-PingWorkerResults
    |
    `-- Apply-MonitorPingResult
            |-- Current / Min / Avg / Max
            |-- Success / Failure / Loss
            |-- Uptime / Downtime
            |-- Outage transitions
            `-- bounded transition timeline
```

The WinForms timer is intentionally a scheduler/poller, not a network executor. A timer tick only identifies due targets, enqueues work, refreshes visible rows, and returns.

## Persistence

`RF-Network-Tool.monitoring.json` stores per-target settings: Enabled, IntervalSec and Alert. `RF-Network-Tool.monitoring-history.json` stores a bounded transition timeline (max 500 records). Session metrics are deliberately not persisted in v1.4.0; restart begins a fresh statistical session while retaining the timeline.

## Freshness and race policy

`PingLatestRequest[target]` identifies the newest non-RF request allowed to update that target. A stale MONITOR result cannot overwrite a newer manual Ping. A target deleted or disabled while a monitor request is in flight rejects the late result. Manual Ping can supersede an in-flight monitor request.

## Accounting policy

ONLINE/OFFLINE durations are accumulated only while monitoring results are authoritative. Disabling a target freezes the duration clock. A PingWorker failure also freezes the clock and is recorded as an engine error; it is not counted as a network outage. The next valid ICMP result resumes accounting.

## Alerts

Alerts occur only on state transitions after the initial UNKNOWN state, using a non-modal ToolTip plus system sound. Repeated OFFLINE samples do not create repeated outage events or modal dialogs.

## Current limitation

Monitoring is ICMP-based. A device that blocks ICMP can be L2 Seen in Network Scan (ARP evidence) while appearing OFFLINE in Monitoring. Multi-probe monitoring is intentionally deferred so v1.4.0 keeps a single, testable health definition.