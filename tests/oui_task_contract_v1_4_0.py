#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
task=(root/'RF-Network-Tool-TaskWorker.ps1').read_text(encoding='utf-8-sig')
checks={
 'task_worker_exists':(root/'RF-Network-Tool-TaskWorker.ps1').exists(),
 'oui_update_background':"Start-OuiTaskWorker 'OUI_UPDATE'" in main,
 'startup_cache_build':"Start-OuiTaskWorker 'OUI_BUILD_CACHE'" in main,
 'incremental_cache_reader':'function Read-OuiCacheChunk' in main and '$ouiCacheTimer.Interval = 80' in main,
 'compact_cache':'oui-prefix-cache.v1.tsv' in main and 'Build-OuiCache' in task,
 'streaming_cache_writer':'IO.StreamWriter' in task,
 'official_https_only':"standards-oui.ieee.org" in task and "Scheme -ne 'https'" in task,
 'no_system_proxy':'$req.Proxy=$null' in task,
 'redirect_validation':'ResponseUri' in task and 'Unexpected IEEE redirect' in task,
 'download_cap':'33554432' in task,
 'task_parent_identity':'ParentStartTicks' in task and 'StartTime.Ticks' in task,
 'task_heartbeat':'HeartbeatFile' in task and 'Write-Heartbeat' in task,
 'deep_worker_mode':"'DEEP'" in task and "-Mode','DEEP'" in main,
 'safe_upnp_xml':'DtdProcessing' in task and 'XmlResolver=$null' in task,
 'bounded_http':'Read-ResponseLimited' in task and 'AllowAutoRedirect=$false' in task,
 'process_async_read':'ReadToEndAsync' in task,
 'no_doevents':'DoEvents' not in task and 'Application]::DoEvents' not in main,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)