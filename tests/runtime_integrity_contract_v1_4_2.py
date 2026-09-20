#!/usr/bin/env python3
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
main = (root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')

# Model the two failure modes seen in the Windows screenshots.
def canonical_scan_ips(values):
    seen = {}
    for raw in values:
        key = str(raw or '').strip().lower()
        if not key:
            continue
        seen[key] = str(raw).strip()
    return list(seen.values())

def finalize_busy(expected, completed, busy):
    completed_keys={str(x).strip().lower() for x in completed}
    out=dict(busy); missing=[]
    for raw in expected:
        target=str(raw).strip(); key=target.lower()
        if out.get(target)=='req-1':
            out.pop(target,None)
        if key not in completed_keys:
            missing.append(target)
    return out,missing

checks={
    # Pure behavioral expectations.
    'model_scan_dedup': canonical_scan_ips(['192.168.1.1',' 192.168.1.1 ','192.168.1.2']) == ['192.168.1.1','192.168.1.2'],
    'model_empty_worker_result_clears_busy': finalize_busy(['192.168.1.1','192.168.1.58'],[],{'192.168.1.1':'req-1','192.168.1.58':'req-1'}) == ({},['192.168.1.1','192.168.1.58']),

    # Source contract: one canonical row/record per normalized IP, with repair from actual grid state.
    'scan_key_helper': 'function Get-ScanIpKey' in main,
    'scan_grid_fallback': 'function Find-ScanGridRowByIp' in main,
    'scan_index_repair': 'function Repair-ScanGridIndex' in main and "'SCAN-INTEGRITY'" in main,
    'scan_record_map': '$script:ScanRecordByIp = @{}' in main,
    'scan_no_append_only_results': '$script:ScanResults += $rec' not in main,
    'scan_null_row_check': 'if($null -eq $row)' in main,

    # Source contract: every request is finalized even when worker returns zero/partial results.
    'ping_engine_error_helper': 'function Set-PingTargetEngineError' in main,
    'ping_request_finalizer': 'function Finalize-PingRequest' in main,
    'ping_completed_target_map': '$completedTargets=@{}' in main,
    'ping_finalizer_called': re.search(r'Finalize-PingRequest\s+\$requestId',main) is not None,
    'monitor_retry_after_engine_error': '$stat.LastScheduledAt=$null' in main and 'Engine error:' in main,
    'ping_latest_cleanup': '$script:PingLatestRequest.Remove($target)' in main,

    # UI distinguishes not-yet-sampled / in-flight / engine-failure states from network OFFLINE.
    'monitor_pending_state': "'PENDING'" in main,
    'monitor_waiting_state': "'WAITING'" in main,
    'monitor_engine_error_state': "'ENGINE ERROR'" in main,
}

failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
if failed: print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)