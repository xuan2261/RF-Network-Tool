#!/usr/bin/env python3
from pathlib import Path
import re, sys, json
root=Path(__file__).resolve().parents[1]
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
worker=(root/'RF-Network-Tool-PingWorker.ps1').read_text(encoding='utf-8-sig')

# Tiny deterministic model matching the intended monitoring accounting contract.
class Stat:
    def __init__(self):
        self.state='UNKNOWN'; self.success=0; self.fail=0; self.total=0; self.outages=0; self.samples=[]
    def apply(self, ok, ms=None):
        old=self.state; self.total+=1
        if ok:
            self.success+=1; self.state='ONLINE'; self.samples.append(float(ms))
        else:
            self.fail+=1; self.state='OFFLINE'
        if old=='ONLINE' and self.state=='OFFLINE': self.outages+=1
    @property
    def loss(self): return 0.0 if not self.total else round(self.fail*100.0/self.total,1)
    @property
    def avg(self): return None if not self.samples else round(sum(self.samples)/len(self.samples),1)

def interval(v):
    allowed=[1,2,5,10,30]
    try:n=int(v)
    except Exception:n=5
    if n in allowed:return n
    return min(allowed,key=lambda x:abs(x-n))

st=Stat(); st.apply(True,2); a=(st.state,st.loss,st.outages,st.avg); st.apply(False); b=(st.state,st.loss,st.outages); st.apply(False); c=st.outages; st.apply(True,4); d=(st.state,st.loss,st.outages,st.avg)
checks={
 'monitor_tab':"$tabMonitor.Text = 'MONITORING'" in main or "$tabMonitor.Text='MONITORING'" in main,
 'config_file':'RF-Network-Tool.monitoring.json' in main,
 'history_file':'RF-Network-Tool.monitoring-history.json' in main,
 'history_bounded':'MonitoringMaxEvents = 500' in main and 'RemoveAt(0)' in main,
 'interval_choices':all(x in main for x in ["@('1','2','5','10','30')",'Get-MonitorInterval']),
 'persistent_settings':'Save-MonitoringConfig' in main and 'Load-MonitoringConfig' in main,
 'history_persistence':'Save-MonitoringHistory' in main and 'Load-MonitoringHistory' in main,
 'monitor_ping_request':"Enqueue-PingRequest 'MONITOR'" in main,
 'monitor_result_branch':"elseif($kind -eq 'MONITOR')" in main and 'Apply-MonitorPingResult $r' in main,
 'no_sync_ping_ui':'.Send(' not in main,
 'async_worker':'SendPingAsync' in worker,
 'manual_priority':'PingLatestRequest' in main and "Kind -eq 'MONITOR'" in main,
 'stale_request_guard':'PING-RESULT-STALE' in main and 'PingLatestRequest' in main,
 'disabled_result_ignored':'if(-not [bool]$cfg.Enabled){return}' in main,
 'disable_freezes_clock':'Set-MonitorEnabledState' in main and '$stat.LastResultAt=$null' in main,
 'worker_failure_freezes_clock':'A worker failure is not a network outage' in main and 'Worker error: $message' in main,
 'nonblocking_alert':'System.Windows.Forms.ToolTip' in main and '$monitorAlertTip.Show(' in main,
 'timeline_grid':'gridMonitorTimeline' in main and 'Refresh-MonitorTimelineGrid' in main,
 'metrics_columns':all(x in main for x in ['MonCurrent','MonMin','MonAvg','MonMax','MonLoss','MonUptime','MonDowntime','MonOutages']),
 'summary_counts':'Enabled $($enabled.Count) | Online $online | Offline $offline | Unknown $unknown' in main,
 'scheduler_500ms':'$monitorTimer.Interval=500' in main,
 'scheduler_batch_cap':'$due.Count -ge 24' in main,
 'first_success_model':a==('ONLINE',0.0,0,2.0),
 'outage_transition_model':b==('OFFLINE',50.0,1),
 'repeat_failure_no_extra_outage':c==1,
 'recovery_model':d==('ONLINE',50.0,1,3.0),
 'interval_exact':all(interval(x)==x for x in [1,2,5,10,30]),
 'interval_nearest':interval(7)==5 and interval(26)==30 and interval('bad')==5,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)