#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
worker=(root/'RF-Network-Tool-PingWorker.ps1').read_text(encoding='utf-8-sig')
checks={
 'ping_worker_file_exists':(root/'RF-Network-Tool-PingWorker.ps1').exists(),
 'main_starts_ping_worker':'function Start-PingWorker' in main and '$PingWorkerScript' in main,
 'persistent_ipc':'request-*.json' in worker and 'result-$requestId.json' in worker and 'worker-state.json' in worker,
 'async_ping_api':'SendPingAsync' in worker,
 'bounded_concurrency':'DefaultConcurrency' in worker and '[Math]::Min(64' in worker,
 'parent_pid_identity':'ParentPid' in worker and 'ParentStartTicks' in worker and 'StartTime.Ticks' in worker,
 'heartbeat':'Write-Heartbeat' in worker and 'heartbeatAt' in worker,
 'single_ping_enqueued':"Enqueue-PingRequest 'PING_SINGLE'" in main,
 'ping_all_enqueued':"Enqueue-PingRequest 'PING_ALL'" in main,
 'rf_ping_enqueued':"Enqueue-PingRequest 'RF'" in main,
 'monitor_ping_enqueued':"Enqueue-PingRequest 'MONITOR'" in main,
 'no_ui_sync_ping':'.Send(' not in main,
 'no_doevents':'Application]::DoEvents' not in main and 'Application.DoEvents' not in main,
 'ping_timer_poll':'$pingWorkerTimer' in main and 'Apply-PingWorkerResults' in main,
 'shutdown_cleanup':'Stop-PingWorker' in main and '$PingStopFile' in main,
 'latest_request_guard':'PingLatestRequest' in main and 'PING-RESULT-STALE' in main,
 'monitor_does_not_spam_ping_log':"elseif($kind -eq 'MONITOR')" in main,
 'manual_ping_overrides_monitor':"Kind -eq 'MONITOR'" in main and '$script:PingTargetBusy.Remove($target)' in main,
 'monitor_uses_same_worker':"kind=$kind" in main and "elseif($kind -eq 'MONITOR')" in main,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)