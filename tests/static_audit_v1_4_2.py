#!/usr/bin/env python3
from pathlib import Path
import re,json,sys
root=Path(__file__).resolve().parents[1]
names=['RF-Network-Tool-Portable.ps1','RF-Network-Tool-Launcher.ps1','RF-Network-Tool-DiscoveryWorker.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1']
paths=[root/n for n in names];texts={p.name:p.read_text(encoding='utf-8-sig') for p in paths}
mt=texts[names[0]];lt=texts[names[1]];dt=texts[names[2]];st=texts[names[3]];pt=texts[names[4]];tt=texts[names[5]];rtp=texts[names[6]]
version=(root/'VERSION').read_text(encoding='ascii').strip()

def strip_ps(s):
    out=[];i=0;n=len(s);state='normal';end=None
    while i<n:
        c=s[i]
        if state=='normal':
            if s.startswith('<#',i):state='block';out.extend('  ');i+=2;continue
            if c=='#':state='line';out.append(' ');i+=1;continue
            if s.startswith("@'",i):state='here';end="'@";out.extend('  ');i+=2;continue
            if s.startswith('@"',i):state='here';end='"@';out.extend('  ');i+=2;continue
            if c=="'":state='single';out.append(' ');i+=1;continue
            if c=='"':state='double';out.append(' ');i+=1;continue
            out.append(c);i+=1;continue
        if state=='line':out.append('\n' if c=='\n' else ' ');state='normal' if c=='\n' else state;i+=1;continue
        if state=='block':
            if s.startswith('#>',i):state='normal';out.extend('  ');i+=2
            else:out.append('\n' if c=='\n' else ' ');i+=1
            continue
        if state=='single':
            if c=="'":
                if i+1<n and s[i+1]=="'":out.extend('  ');i+=2
                else:state='normal';out.append(' ');i+=1
            else:out.append('\n' if c=='\n' else ' ');i+=1
            continue
        if state=='double':
            if c=='`' and i+1<n:out.extend('  ');i+=2
            elif c=='"':state='normal';out.append(' ');i+=1
            else:out.append('\n' if c=='\n' else ' ');i+=1
            continue
        if state=='here':
            if s.startswith(end,i) and (i==0 or s[i-1]=='\n'):state='normal';out.extend('  ');i+=2
            else:out.append('\n' if c=='\n' else ' ');i+=1
    return ''.join(out)
def balanced(s):
    t=strip_ps(s);stack=[];pairs={')':'(',']':'[','}':'{'}
    for c in t:
        if c in '([{':stack.append(c)
        elif c in ')]}':
            if not stack or stack.pop()!=pairs[c]:return False
    return not stack
def dups(s):
    fs=[x.lower() for x in re.findall(r'(?im)^\s*function\s+([A-Za-z0-9_-]+)',s)]
    return sorted({x for x in fs if fs.count(x)>1})
def def_only(s):
    fs=re.findall(r'(?im)^\s*function\s+([A-Za-z0-9_-]+)',s)
    return [f for f in fs if len(re.findall(r'(?i)(?<![\w-])'+re.escape(f)+r'(?![\w-])',s))==1]
def ambiguous_colon_interpolation(s):
    """Return expandable-string refs like "$name:" that PowerShell parses as a scope qualifier."""
    hits=[]
    # Bounded static guard for ordinary double-quoted strings. Braced refs (${name}:) are valid.
    string_pat=re.compile(r'"(?:`.|[^"`])*"')
    bad_pat=re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*):(?=$|[\s\'"}`)\],.;!?-])')
    for i,line in enumerate(s.splitlines(),1):
        for string_match in string_pat.finditer(line):
            for m in bad_pat.finditer(string_match.group(0)):
                hits.append((i,m.group(0)))
    return hits
def bad_auto(s):
    autos={'host','home','pid','pwd','pshome','psversiontable','error','args','input','matches','null','true','false','this','executioncontext','myinvocation','psboundparameters','profile','sender'}
    hits=[]
    for i,l in enumerate(strip_ps(s).splitlines(),1):
        m=re.match(r'^\s*\$([A-Za-z_]\w*)\s*(?:=|\+=|-=|\+\+|--)',l,re.I)
        if m and m.group(1).lower() in autos:hits.append((i,m.group(1)))
    for name in ['args','error','input','host','profile','sender']:
        if re.search(r'(?i)(?:param\s*\(|function\s+[\w-]+\s*\([^)]*)[^)]*\$'+name+r'\b',strip_ps(s),re.S):hits.append((-1,name))
    return hits
vbs=(root/'START-RF-NETWORK-TOOL.vbs').read_bytes()
cmds=[(root/n).read_bytes() for n in ['RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd','RUN-TESTS.cmd']]
rt=(root/'README.txt').read_text(encoding='utf-8-sig')
checks={
 'version_main_dynamic':'$AppVersion' in mt and 'VERSION' in mt and 'v1.4.2 Full QA / CI-E2E' not in mt,
 'version_launcher_dynamic':'$AppVersion' in lt and 'VERSION' in lt and 'v1.4.2 Full QA / CI-E2E' not in lt,
 'task_useragents_dynamic':tt.count('$UserAgent')>=3 and 'RF-Network-Tool/1.4.2' not in tt,
 'discovery_useragent_dynamic':'$UserAgent' in dt and 'RF-Network-Tool/1.4.2' not in dt,
 'runtime_scripts_present':all(p.exists() for p in paths),
 'all_delimiters_balanced':all(balanced(x) for x in texts.values()),
 'no_duplicate_functions':all(not dups(x) for x in texts.values()),
 'no_definition_only_functions':all(not def_only(x) for x in texts.values()),
 'no_auto_variable_regression':all(not bad_auto(x) for x in texts.values()),
 'null_comparisons_left_safe':all(not re.search(r'(?i)\$(?!null\b)[A-Za-z_][\w.]*\s+-(?:eq|ne)\s+\$null\b',strip_ps(x)) for x in texts.values()),
 'no_ambiguous_colon_interpolation':all(not ambiguous_colon_interpolation(x) for x in texts.values()),
 'no_ordered_parameter_regression':all('[ordered]$' not in x.lower() for x in texts.values()),
 'no_uint64_hex_regression':'[uint64]0xffffffff' not in mt.lower(),
 'single_instance_lock':'Acquire-InstanceLock' in lt and 'Release-InstanceLock' in lt and 'FileShare]::None' in lt,
 'launcher_parses_all_workers':all(n in lt for n in ['RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-DiscoveryWorker.ps1']),
 'session_scoped_ping_ipc':'PingIpcDir' in mt and 'RuntimeSessionId' in mt,
 'ping_async_worker':'SendPingAsync' in pt and 'Enqueue-PingRequest' in mt,
 'no_sync_ping_in_ui':'.Send(' not in mt,
 'no_doevents_anywhere':all('DoEvents' not in x for x in texts.values()),
 'latest_ping_request_guard':'PingLatestRequest' in mt and 'PING-RESULT-STALE' in mt,
 'monitor_tab':"$tabMonitor.Text = 'MONITORING'" in mt or "$tabMonitor.Text='MONITORING'" in mt,
 'monitor_persistence':'RF-Network-Tool.monitoring.json' in mt and 'RF-Network-Tool.monitoring-history.json' in mt,
 'monitor_bounded_history':'MonitoringMaxEvents = 500' in mt and 'RemoveAt(0)' in mt,
 'monitor_async_ping':"Enqueue-PingRequest 'MONITOR'" in mt and "elseif($kind -eq 'MONITOR')" in mt,
 'monitor_intervals':"@('1','2','5','10','30')" in mt,
 'monitor_metrics':all(x in mt for x in ['MonCurrent','MonMin','MonAvg','MonMax','MonLoss','MonUptime','MonDowntime','MonOutages']),
 'monitor_nonmodal_alert':'$monitorAlertTip.Show(' in mt and 'NotifyIcon' not in mt,
 'monitor_timer_cleanup':'$monitorTimer' in mt and '@($udpTimer,$timer,$discoveryTimer,$scanWorkerTimer,$pingWorkerTimer,$monitorTimer' in mt,
 'monitor_worker_failure_freezes_clock':'A worker failure is not a network outage' in mt and 'Worker error: $message' in mt,
 'scan_runtime_integrity':all(x in mt for x in ['function Get-ScanIpKey','function Find-ScanGridRowByIp','function Repair-ScanGridIndex','$script:ScanRecordByIp = @{}','SCAN-INTEGRITY']),
 'ping_request_finalization':all(x in mt for x in ['function Set-PingTargetEngineError','function Finalize-PingRequest','$completedTargets=@{}','PING-RESULT-INCOMPLETE','PingLatestRequest.Remove($target)']),
 'monitor_engine_state_ui':all(x in mt for x in ["'PENDING'","'WAITING'","'ENGINE ERROR'",'Engine error:']),
 'oui_background':"Start-OuiTaskWorker 'OUI_UPDATE'" in mt and "'OUI_UPDATE'" in tt,
 'oui_compact_cache':'oui-prefix-cache.v1.tsv' in mt and 'Build-OuiCache' in tt,
 'deep_background':"'-Mode','DEEP'" in mt and "'DEEP'" in tt,
 'safe_http_worker':'$req.Proxy=$null' in tt and 'AllowAutoRedirect=$false' in tt,
 'safe_upnp_xml_worker':'DtdProcessing' in tt and 'XmlResolver=$null' in tt,
 'bounded_http_worker':'Read-ResponseLimited' in tt,
 'process_async_read_worker':'ReadToEndAsync' in tt and 'ReadToEndAsync' in dt,
 'worker_parent_identity':all('ParentStartTicks' in x and 'StartTime.Ticks' in x for x in [pt,tt,st,dt]),
 'atomic_worker_files':all('.$PID.$([guid]::NewGuid().ToString' in x and '[IO.File]::Replace' in x for x in [pt,tt,st,dt]),
 'scan_active_arp':'SendARP' in st and 'Get-NetNeighbor' in st,
 'scan_passive_ipv6_ndp':all(x in st for x in ['Get-NetNeighbor -AddressFamily IPv6 -InterfaceIndex $interfaceIndex','ipv6Neighbors=@($ipv6Neighbors)','IPv6NeighborCount=@($ipv6Neighbors).Count','ipv6-neighbor-snapshot']),
 'scan_ipv6_no_mutation':all(x not in st for x in ['New-NetNeighbor','Set-NetNeighbor','Remove-NetNeighbor','New-NetIPAddress','Set-NetIPAddress']),
 'route_planner_private_bounded':all(x in rtp for x in ['Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $InterfaceIndex','MaxAutoSubnets=4','MaxTotalHosts=1024','MaxAutoHostsPerSubnet=254','Test-RftPrivateIPv4Range']),
 'route_planner_no_mutation':all(x not in rtp for x in ['New-NetRoute','Set-NetRoute','Remove-NetRoute','New-NetIPAddress','Set-NetIPAddress']),
 'route_planner_opt_in_ui':all(x in mt for x in ["$chkRouteAware.Text='Route-aware'","$chkRouteAware.Checked=$false",'New-RftRouteAwareScanPlan']),
 'scan_ipv6_ui_surface':'NDP6 $ipv6Count' in mt and 'IPv6Neighbors=$(if($state.PSObject.Properties' in mt,
 'scan_profiles':all(x in mt for x in ["@('FAST','BALANCED','DEEP')","SelectedItem='BALANCED'"]),
 'evidence_retained':"'DISCOVERY EVIDENCE'" in mt and 'Get-ScanEvidenceRecords' in mt,
 'rf_udp_retained':'function Process-UdpPackets' in mt,
 'known_oui_retained':'KnownOui' in mt and 'GPS / GNSS receiver' in mt and 'Edge AI / Single-board computer' in mt,
 'csv_formula_guard':'function ConvertTo-SafeCsvField' in mt and 'Export-ScanCsv' in mt,
 'bounded_gui_log':'if($box.TextLength -gt 600000)' in mt,
 'ui_exception_boundary':'SetUnhandledExceptionMode' in mt and 'add_ThreadException' in mt,
 'vbs_ascii_no_bom':not vbs.startswith(b'\xef\xbb\xbf') and all(x<128 for x in vbs),
 'cmd_ascii_no_bom':all(not b.startswith(b'\xef\xbb\xbf') and all(x<128 for x in b) for b in cmds),
 'readme_current_version':('v'+version) in rt and 'MONITORING' in rt,
 'ci_workflow_present':(root/'.github/workflows/ci.yml').is_file(),
 'ui_e2e_workflow_present':(root/'.github/workflows/ui-e2e-selfhosted.yml').is_file(),
 'windows_integration_v142':(root/'tests/WINDOWS_INTEGRATION_TEST_v1_4_2.ps1').is_file(),
 'windows_lint_gate_v142':(root/'tests/WINDOWS_LINT_GATE_v1_4_2.ps1').is_file(),
 'windows_launcher_e2e_v142':(root/'tests/WINDOWS_LAUNCHER_E2E_v1_4_2.ps1').is_file(),
 'windows_machine_cleanliness_v142':(root/'tests/WINDOWS_MACHINE_CLEANLINESS_v1_4_2.ps1').is_file(),
 'windows_machine_cleanliness_test_v142':(root/'tests/WINDOWS_MACHINE_CLEANLINESS_TEST_v1_4_2.ps1').is_file(),
 'release_sbom_builder':(root/'release_tools/build_sbom.py').is_file(),
 'release_sbom_test':(root/'tests/release_sbom_test_v1_4_2.py').is_file(),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
(root/f'BUILD_CHECKS_v{version}.json').write_text(json.dumps({'release':f'v{version} Full QA / CI-E2E','all_pass':not failed,'checks':checks,'limitations':['Static/deterministic source audit only. Hosted Windows PowerShell 5.1 runtime evidence is owned by GitHub Actions; interactive WinForms UI E2E remains a separate self-hosted gate.']},ensure_ascii=False,indent=2),encoding='utf-8')
if failed:print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)