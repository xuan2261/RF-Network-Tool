#!/usr/bin/env python3
from pathlib import Path
import sys

root=Path(__file__).resolve().parents[1]
worker=(root/'RF-Network-Tool-ScanWorker.ps1').read_text(encoding='utf-8-sig')
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
perf=(root/'tests/WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1').read_text(encoding='utf-8-sig')

checks={
    'worker_ipv6_neighbor_interface_scoped':
        'Get-NetNeighbor -AddressFamily IPv6 -InterfaceIndex $interfaceIndex' in worker,
    'worker_ipv6_snapshot_is_passive':
        "PASS 5: passive IPv6 Neighbor Discovery snapshot" in worker
        and 'Never enumerate the IPv6 address space' in worker,
    'worker_ipv6_filters_bad_states':
        "$_.State -notin @('Unreachable','Incomplete')" in worker,
    'worker_ipv6_rejects_non_unicast_noise':
        'IPv6Any' in worker and 'IPv6Loopback' in worker and 'IsIPv6Multicast' in worker,
    'worker_ipv6_state_payload':
        'ipv6Neighbors=@($ipv6Neighbors)' in worker,
    'worker_ipv6_metrics':
        'IPv6NeighborCount=@($ipv6Neighbors).Count' in worker
        and 'IPv6NeighborError=$ipv6NeighborError' in worker,
    'worker_ipv6_nonfatal_boundary':
        "Write-WorkerLog ('IPv6 NDP snapshot failed: '+$ipv6NeighborError)" in worker
        and '$ipv6Neighbors=@()' in worker,
    'worker_no_ipv6_neighbor_mutation':
        all(x not in worker for x in ['New-NetNeighbor','Set-NetNeighbor','New-NetIPAddress','Set-NetIPAddress']),
    'ui_ipv6_phase':
        "'ipv6-neighbor-snapshot' {'5/5 Snapshot IPv6 NDP thụ động'}" in main,
    'ui_ipv6_summary':
        'NDP6 $ipv6Count' in main,
    'history_ipv6_count':
        'IPv6Neighbors=$(if($state.PSObject.Properties' in main,
    'help_ipv6_no_bruteforce':
        'Tool không brute-force hay sinh dải địa chỉ IPv6.' in main,
    'no_ipv6_host_range_enumerator':
        'Get-IPv6HostsFromCidr' not in main and 'Get-IPv6HostsFromCidr' not in worker,
    'windows_perf_executes_ipv6_contract':
        "FAST synthetic /24 exposes IPv6 neighbor snapshot" in perf
        and "IPv6 neighbor metric matches snapshot" in perf,
}

failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():
    print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
if failed:
    print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)
