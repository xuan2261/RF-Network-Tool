#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
checks={
 'no_application_doevents':'DoEvents' not in main,
 'no_sync_ping_ui':'.Send(' not in main,
 'ping_ui_background':'Enqueue-PingRequest' in main and '$pingWorkerTimer' in main,
 'monitor_background':"Enqueue-PingRequest 'MONITOR'" in main and '$monitorTimer.Interval=500' in main,
 'monitor_no_modal_alert':'$monitorAlertTip.Show(' in main and 'ShowBalloonTip' not in main,
 'deep_background':"'-Mode','DEEP'" in main,
 'oui_background':"Start-OuiTaskWorker 'OUI_UPDATE'" in main,
 'scan_background':'Start-ScanWorker' in main and '$scanWorkerTimer' in main,
 'name_background':'Start-DiscoveryWorker' in main and '$discoveryTimer' in main,
 'ping_watchdog':'PING-WATCHDOG' in main,
 'oui_watchdog':'OUI-WATCHDOG' in main,
 'deep_watchdog':'Deep worker heartbeat stale' in main and '$deepTimer' in main,
 'monitor_grid_updates_bounded':'$due.Count -ge 24' in main,
 'all_timer_cleanup':'$monitorTimer' in main and 'foreach($tm in @(' in main,
 'ui_exception_boundary':'SetUnhandledExceptionMode' in main and 'add_ThreadException' in main,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)