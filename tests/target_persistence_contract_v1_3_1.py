#!/usr/bin/env python3
"""Persistence/migration contracts for the Ping target table."""
import sys

def load_shape(parsed,legacy=None):
    seen=set();out=[]
    if isinstance(parsed,dict) and 'schemaVersion' in parsed and 'targets' in parsed: src=parsed.get('targets') or []
    elif parsed is None: src=[]
    elif isinstance(parsed,list): src=parsed
    else: src=[parsed]
    for x in src:
        if not isinstance(x,dict): continue
        t=str(x.get('Target','')).strip();n=str(x.get('Name','')).strip()
        if not t or t.lower() in seen: continue
        seen.add(t.lower());out.append({'Target':t,'Name':n})
    if not out and legacy:
        for line in legacy:
            t=str(line).strip()
            if not t or t.lower() in seen: continue
            seen.add(t.lower());out.append({'Target':t,'Name':''})
    return out

def assign_defaults(rows):
    used={r['Name'] for r in rows if r['Name']}
    nextn=1
    for r in rows:
        if not r['Name']:
            while f'Default {nextn}' in used: nextn+=1
            r['Name']=f'Default {nextn}';used.add(r['Name']);nextn+=1
    return rows
c={}
one=load_shape({'schemaVersion':2,'targets':[{'Target':'192.168.0.1','Name':'Router'}]});c['one_row']=len(one)==1 and one[0]['Name']=='Router'
two=load_shape([{'Target':'192.168.0.1','Name':'A'},{'Target':'192.168.0.2','Name':'B'}]);c['legacy_v1_array']=len(two)==2
fifty=load_shape({'schemaVersion':2,'targets':[{'Target':f'192.168.55.{i}','Name':f'Device {i}'} for i in range(1,51)]});c['fifty_rows_restore']=len(fifty)==50 and len({x['Target'] for x in fifty})==50
dup=load_shape({'schemaVersion':2,'targets':[{'Target':'HOST','Name':'A'},{'Target':'host','Name':'B'}]});c['case_insensitive_dedupe']=len(dup)==1 and dup[0]['Name']=='A'
legacy=assign_defaults(load_shape(None,['192.168.0.10','192.168.0.11']));c['legacy_txt_defaults']=[x['Name'] for x in legacy]==['Default 1','Default 2']
failed=[k for k,v in c.items() if not v]
for k,v in c.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(c),'FAILED',len(failed));sys.exit(1 if failed else 0)