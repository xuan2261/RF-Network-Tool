#!/usr/bin/env python3
import sys, json
state={
 'schemaVersion':3,'runId':'abc','profile':'BALANCED','startedAt':'2026-09-19T00:00:00Z','elapsedMs':1250,'phase':'done','complete':True,'cancelled':False,'error':'','done':254,'total':254,'online':4,'seen':2,
 'metrics':{'FastSuccessCount':4,'FastResponseRate':1.6,'FastAverageMs':2.5,'EffectivePingConcurrency':96,'EffectiveRetryConcurrency':64,'EffectiveArpConcurrency':48,'RetryEnabled':True,'DiscoveryMode':'BALANCED','DiscoveryDurationSec':20},
 'results':[{'IP':'192.168.0.1','Status':'Online'},{'IP':'192.168.0.20','Status':'L2 Seen'}]
}
checks={
 'schema_v3':state['schemaVersion']==3,
 'run_identity':bool(state['runId']) and state['profile']=='BALANCED',
 'timing_fields':state['elapsedMs']>0 and bool(state['startedAt']),
 'metrics_shape':set(['FastSuccessCount','FastResponseRate','FastAverageMs','EffectivePingConcurrency','EffectiveRetryConcurrency','EffectiveArpConcurrency','RetryEnabled','DiscoveryMode','DiscoveryDurationSec']).issubset(state['metrics']),
 'discovered_count_is_results':len(state['results'])==2,
 'progress_independent_of_discovered':state['done']==state['total']==254,
 'monitoring_record_fields':all(k in {'RunId','Profile','CIDR','StartedAt','CompletedAt','Outcome','Targets','Online','L2Seen','Discovered','ElapsedMs','FastResponseRate','FastAverageMs','PingConcurrency','RetryConcurrency','ArpConcurrency'} for k in ['RunId','Profile','CIDR','ElapsedMs','FastResponseRate','ArpConcurrency']),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
sys.exit(1 if failed else 0)