#!/usr/bin/env python3
"""Deterministic schema/merge contract tests for v1.2.1 evidence records."""
from collections import OrderedDict
import json, sys

def ev(source,state,value='',detail='',at=''):
    return {'Source':source,'State':state,'Value':value,'Detail':detail,'ObservedAt':at}

def scan_evidence(item, at='2026-09-19T10:00:00+07:00'):
    out=[]
    fast=bool(item.get('IcmpFast')); fs=item.get('IcmpFastStatus','Unknown')
    out.append(ev('ICMP fast','PASS' if fast else 'NO RESPONSE',f"{item.get('IcmpFastMs')} ms | TTL {item.get('IcmpFastTTL')}" if fast else '',fs,at))
    retry=bool(item.get('IcmpRetry')); rs=item.get('IcmpRetryStatus','Not attempted')
    out.append(ev('ICMP retry','PASS' if retry else ('SKIPPED' if str(rs).startswith('Skipped') else 'NO RESPONSE'),f"{item.get('IcmpRetryMs')} ms | TTL {item.get('IcmpRetryTTL')}" if retry else '',rs,at))
    arp=bool(item.get('Arp'))
    out.append(ev('Active ARP','PASS' if arp else 'NO RESPONSE',item.get('ArpMAC',''),item.get('ArpStatus',''),at))
    nbr=bool(item.get('Neighbor'))
    out.append(ev('Neighbor cache','PASS' if nbr else 'NOT OBSERVED',item.get('NeighborMAC',''),item.get('NeighborState',''),at))
    return out

def merge(*sets):
    m=OrderedDict()
    for st in sets:
        for e in st:
            if e and e.get('Source'): m[e['Source']]=dict(e)
    return list(m.values())

checks={}
arp_only={'IP':'192.168.0.77','Status':'L2 Seen','IcmpFast':False,'IcmpFastStatus':'TimedOut','IcmpRetry':False,'IcmpRetryStatus':'TimedOut','Arp':True,'ArpStatus':'Success','ArpError':'0','ArpMAC':'AA-BB-CC-DD-EE-FF','Neighbor':True,'NeighborState':'Reachable','NeighborMAC':'AA-BB-CC-DD-EE-FF'}
a=scan_evidence(arp_only)
checks['arp_only_has_four_scan_records']=len(a)==4
checks['arp_only_icmp_no_response']=a[0]['State']=='NO RESPONSE' and a[1]['State']=='NO RESPONSE'
checks['arp_only_active_arp_pass']=next(x for x in a if x['Source']=='Active ARP')['State']=='PASS'
checks['arp_only_neighbor_pass']=next(x for x in a if x['Source']=='Neighbor cache')['State']=='PASS'

online={'IP':'192.168.0.10','Status':'Online','IcmpFast':True,'IcmpFastStatus':'Success','IcmpFastMs':'2','IcmpFastTTL':'64','IcmpRetry':False,'IcmpRetryStatus':'Skipped - fast ICMP success','Arp':True,'ArpStatus':'Success','ArpMAC':'11-22-33-44-55-66','Neighbor':True,'NeighborState':'Reachable','NeighborMAC':'11-22-33-44-55-66'}
b=scan_evidence(online)
checks['fast_online_pass']=b[0]['State']=='PASS' and '2 ms' in b[0]['Value']
checks['retry_skipped_after_fast_success']=b[1]['State']=='SKIPPED'

disc=[ev('System DNS','NO RESPONSE','','No hostname'),ev('mDNS / DNS-SD','PASS','jetson.local','mDNS host')]
deep=[ev('Common TCP services','PASS','22/SSH, 80/HTTP','fixed probe set')]
m=merge(a,disc,deep,[ev('System DNS','PASS','jetson-nano','late refresh')])
checks['merge_deduplicates_by_source']=len([x for x in m if x['Source']=='System DNS'])==1
checks['later_evidence_overrides_same_source']=next(x for x in m if x['Source']=='System DNS')['State']=='PASS'
checks['deep_evidence_preserved']=any(x['Source']=='Common TCP services' for x in m)

cache={'schemaVersion':2,'updatedAt':'2026-09-19T10:00:00+07:00','records':[{'IP':'192.168.0.10','Name':'jetson-nano','Source':'System DNS','Score':100,'Evidence':disc}]}
checks['discovery_cache_schema_v2_shape']=cache['schemaVersion']==2 and isinstance(cache['records'],list) and isinstance(cache['records'][0]['Evidence'],list)

failed=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
if failed: print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)