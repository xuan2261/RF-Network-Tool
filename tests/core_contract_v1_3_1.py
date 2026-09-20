#!/usr/bin/env python3
"""Deterministic contracts for long-lived core formatting/parsing behavior."""
import re,sys,ipaddress,json

def fmt_mac(mac):
    c=''.join(ch for ch in (mac or '') if ch in '0123456789abcdefABCDEF').upper()
    return '-'.join(c[i:i+2] for i in range(0,12,2)) if len(c)==12 else ''

def rf_metrics(text):
    out={}
    for k in ('RSSI','SNR'):
        m=re.search(rf'''(?i)["']?{k}["']?\s*[:=]\s*["']?(-?\d+(?:\.\d+)?)''',text or '')
        out[k]=float(m.group(1)) if m else None
    return out

def csv_field(v):
    v='' if v is None else str(v)
    if re.match(r'^[=+\-@]',v): v="'"+v
    return '"'+v.replace('"','""')+'"'

def hosts(cidr):
    n=ipaddress.IPv4Network(cidr,strict=False)
    if n.prefixlen>=31: return [str(x) for x in n]
    return [str(x) for x in n.hosts()]

c={}
c['mac_plain_normalized']=fmt_mac('F859713A2339')=='F8-59-71-3A-23-39'
c['mac_separator_normalized']=fmt_mac('f8:59:71:3a:23:39')=='F8-59-71-3A-23-39'
c['invalid_mac_blank']=fmt_mac('abc')==''
c['rf_plain']=rf_metrics('RSSI=-67, SNR=18')=={'RSSI':-67.0,'SNR':18.0}
c['rf_jsonish']=rf_metrics('{"rssi":-71.5,"snr":"12.25"}')=={'RSSI':-71.5,'SNR':12.25}
c['csv_formula_equals']=csv_field('=1+1').startswith('"\'=')
c['csv_formula_at']=csv_field('@SUM(A1:A2)').startswith('"\'@')
c['csv_quote_escape']=csv_field('a"b')=='"a""b"'
c['cidr_24_host_count']=len(hosts('192.168.0.0/24'))==254 and hosts('192.168.0.0/24')[0]=='192.168.0.1' and hosts('192.168.0.0/24')[-1]=='192.168.0.254'
failed=[k for k,v in c.items() if not v]
for k,v in c.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(c),'FAILED',len(failed));sys.exit(1 if failed else 0)