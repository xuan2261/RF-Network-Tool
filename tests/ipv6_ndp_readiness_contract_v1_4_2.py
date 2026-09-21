#!/usr/bin/env python3
from pathlib import Path
import re,sys

root=Path(__file__).resolve().parents[1]
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
win=(root/'tests/WINDOWS_IPV6_NDP_READINESS_v1_4_2.ps1').read_text(encoding='utf-8-sig')
ci=(root/'.github/workflows/ci.yml').read_text(encoding='utf-8')
harness=(root/'RF-Network-Tool-RealMachineQualification.ps1').read_text(encoding='utf-8-sig')

checks={
 'ipv6_diagnostics_function':'function Get-AdapterIPv6Diagnostics' in main,
 'ipv6_address_inventory':all(x in main for x in ['Get-NetIPAddress','-AddressFamily IPv6','-InterfaceIndex $idx']),
 'ipv6_ndp_inventory':all(x in main for x in ['Get-NetNeighbor','-AddressFamily IPv6','NeighborStateSummary','NeighborSamples']),
 'ipv6_inventory_bounded':all(x in main for x in ['[Math]::Min([Math]::Max($MaxNeighbors,1),16)','Select-Object -First 256']),
 'ipv6_link_local_scope':all(x in main for x in ['IsIPv6LinkLocal',"$display+='%'+$idx"]),
 'ipv6_filters_non_unicast':all(x in main for x in ['IsIPv6Multicast','IPv6Loopback','IPv6None']),
 'ipv6_ui_visible':all(x in main for x in ['IPv6     : $ipv6Text','NDP      : $ndpText','NDP sample: $ndpSample']),
 'ipv6_no_host_range_generator':'Get-IPv6Hosts' not in main and 'Build-IPv6Targets' not in main,
 'ipv6_windows_test_read_only':all(x in win for x in ['Get-NetIPAddress -AddressFamily IPv6','Get-NetNeighbor -AddressFamily IPv6','Select-Object -First 256','ALL WINDOWS IPV6/NDP READINESS TESTS PASSED']),
 'ipv6_windows_test_no_active_probe':not any(x in win for x in ['Test-Connection','ping.exe','SendPingAsync','Start-Process','Invoke-WebRequest','Invoke-RestMethod']),
 'ipv6_ci_gate':'IPv6/NDP read-only readiness' in ci and 'WINDOWS_IPV6_NDP_READINESS_v1_4_2.ps1' in ci,
 'ipv6_harness_gate':'ipv6_ndp_readiness' in harness and 'WINDOWS_IPV6_NDP_READINESS_v1_4_2.ps1' in harness,
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
if failed:print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)
