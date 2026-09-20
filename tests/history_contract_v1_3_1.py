#!/usr/bin/env python3
"""Deterministic contract simulation for device-history identity/count semantics."""
import sys

def key(ip,mac=''):
    clean=''.join(c for c in (mac or '').upper() if c in '0123456789ABCDEF')
    return 'MAC:'+clean if len(clean)>=12 and clean!='000000000000' else 'IP:'+ip

def update(hist,dev,inc=False,now='2026-09-19T11:00:00'):
    k=key(dev['IP'],dev.get('MAC','')); ipk='IP:'+dev['IP']
    if k.startswith('MAC:') and ipk!=k and ipk in hist:
        old=hist[ipk]
        if k not in hist:
            old=dict(old);old['Key']=k;hist[k]=old
        else:
            dst=hist[k];dst['FirstSeen']=min(dst.get('FirstSeen','z'),old.get('FirstSeen','z'));dst['LastSeen']=max(dst.get('LastSeen',''),old.get('LastSeen',''));dst['SeenCount']=max(int(dst.get('SeenCount',0)),int(old.get('SeenCount',0)))
        del hist[ipk]
    if k not in hist: hist[k]={'Key':k,'FirstSeen':now,'LastSeen':now,'SeenCount':0}
    h=hist[k];h['LastSeen']=now
    if inc: h['SeenCount']=int(h.get('SeenCount',0))+1
    h.update({'LastIP':dev['IP'],'LastMAC':dev.get('MAC',''),'LastName':dev.get('Name','')})
    return h

c={};h={}
# Scan 1: ICMP first, MAC absent.
a=update(h,{'IP':'192.168.0.50','MAC':'','Name':''},True,'2026-09-19T11:00:00')
c['initial_ip_identity']=a['Key']=='IP:192.168.0.50' and a['SeenCount']==1
# Same scan: ARP enriches MAC, must migrate not increment.
b=update(h,{'IP':'192.168.0.50','MAC':'AA-BB-CC-DD-EE-FF','Name':''},False,'2026-09-19T11:00:01')
c['arp_migrates_ip_to_mac']='IP:192.168.0.50' not in h and 'MAC:AABBCCDDEEFF' in h
c['arp_does_not_increment']=b['SeenCount']==1
# Same scan: name/deep enrich must not increment.
c1=update(h,{'IP':'192.168.0.50','MAC':'AA-BB-CC-DD-EE-FF','Name':'Jetson Nano'},False,'2026-09-19T11:00:02')
c['name_enrich_does_not_increment']=c1['SeenCount']==1 and c1['LastName']=='Jetson Nano'
# Next scan increments exactly once.
d=update(h,{'IP':'192.168.0.50','MAC':'AA-BB-CC-DD-EE-FF','Name':'Jetson Nano'},True,'2026-09-19T11:05:00')
c['next_scan_increments_once']=d['SeenCount']==2
# Existing MAC + provisional IP duplicate: merge uses max, not sum.
h2={'MAC:AABBCCDDEEFF':{'Key':'MAC:AABBCCDDEEFF','FirstSeen':'2026-09-19T09:00:00','LastSeen':'2026-09-19T10:00:00','SeenCount':7},'IP:192.168.0.50':{'Key':'IP:192.168.0.50','FirstSeen':'2026-09-19T08:00:00','LastSeen':'2026-09-19T10:30:00','SeenCount':2}}
e=update(h2,{'IP':'192.168.0.50','MAC':'AA-BB-CC-DD-EE-FF'},False,'2026-09-19T11:00:00')
c['duplicate_merge_no_double_count']=len(h2)==1 and e['SeenCount']==7 and e['FirstSeen']=='2026-09-19T08:00:00'
failed=[k for k,v in c.items() if not v]
for k,v in c.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(c),'FAILED',len(failed))
sys.exit(1 if failed else 0)