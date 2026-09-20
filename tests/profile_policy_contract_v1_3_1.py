#!/usr/bin/env python3
"""Deterministic policy contract tests mirroring v1.3.1 profile rules."""
import sys

def policy(profile, base, count):
    p=(profile or 'BALANCED').upper(); base=max(100,min(2000,int(base))); count=max(1,int(count))
    if p=='FAST':
        return dict(Profile='FAST',Fast=min(450,base),Retry=False,RetryMs=min(450,base),Ping=64 if count<=64 else 128,Arp=32 if count<=64 else 64,Discovery=8)
    if p=='DEEP':
        return dict(Profile='DEEP',Fast=max(300,min(1500,base)),Retry=True,RetryMs=max(1200,min(3000,base*3)),Ping=32 if count<=64 else 64 if count<=256 else 96,Arp=24 if count<=64 else 32 if count<=256 else 48,Discovery=45)
    return dict(Profile='BALANCED',Fast=max(150,min(900,base)),Retry=True,RetryMs=max(700,min(2000,base*2)),Ping=48 if count<=64 else 96 if count<=256 else 128,Arp=32 if count<=64 else 48 if count<=256 else 64,Discovery=20)

def adapt(p, successes, avg, total):
    retry=min(p['Ping'],64); arp=p['Arp']
    if successes==0: retry=min(retry,32); arp=min(arp,32)
    elif avg>=120: retry=min(retry,32); arp=min(arp,24)
    elif avg>=60: retry=min(retry,48); arp=min(arp,32)
    if total>512: retry=min(retry,32); arp=min(arp,24)
    return retry,arp

c={}
f=policy('FAST',350,254); c['fast_no_retry']=not f['Retry']; c['fast_discovery_8']=f['Discovery']==8; c['fast_high_parallelism']=f['Ping']==128 and f['Arp']==64
b=policy('BALANCED',350,254); c['balanced_default']=b==dict(Profile='BALANCED',Fast=350,Retry=True,RetryMs=700,Ping=96,Arp=48,Discovery=20)
d=policy('DEEP',350,254); c['deep_conservative']=d['Ping']==64 and d['Arp']==32 and d['RetryMs']==1200 and d['Discovery']==45
c['base_timeout_clamped']=policy('BALANCED',50,10)['Fast']==150 and policy('FAST',5000,10)['Fast']==450
c['small_subnet_policy']=policy('BALANCED',350,32)['Ping']==48 and policy('DEEP',350,32)['Arp']==24
c['rtt_healthy_keeps_limits']=adapt(b,4,3,254)==(64,48)
c['rtt_medium_reduces']=adapt(b,4,75,254)==(48,32)
c['rtt_slow_reduces_more']=adapt(b,4,150,254)==(32,24)
c['zero_reply_is_conservative']=adapt(b,0,0,254)==(32,32)
c['large_range_caps']=adapt(policy('BALANCED',350,700),10,5,700)==(32,24)
c['low_density_not_packet_loss']=adapt(b,1,2,254)==(64,48)
failed=[k for k,v in c.items() if not v]
for k,v in c.items(): print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(c),'FAILED',len(failed))
if failed: print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)