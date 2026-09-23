#!/usr/bin/env python3
from pathlib import Path
import sys

root=Path(__file__).resolve().parents[1]
planner_path=root/'RF-Network-Tool-RoutePlanner.ps1'
planner=planner_path.read_text(encoding='utf-8-sig') if planner_path.is_file() else ''
main=(root/'RF-Network-Tool-Portable.ps1').read_text(encoding='utf-8-sig')
qualification=(root/'RF-Network-Tool-RealMachineQualification.ps1').read_text(encoding='utf-8-sig')
physical=(root/'.github/workflows/ui-e2e-selfhosted.yml').read_text(encoding='utf-8')
live_path=root/'tests/WINDOWS_ROUTE_SCOPE_LIVE_TEST_v1_5_1.ps1'
live=live_path.read_text(encoding='utf-8-sig') if live_path.is_file() else ''

checks={
    'route_planner_exists': planner_path.is_file(),
    'route_query_interface_scoped':
        'Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $InterfaceIndex' in planner,
    'route_rfc1918_only':
        all(x in planner for x in ['10.0.0.0','172.16.0.0','192.168.0.0','Test-RftPrivateIPv4Range']),
    'route_default_excluded': "'default-route'" in planner,
    'route_auto_prefix_bounded':
        'MaxAutoHostsPerSubnet=254' in planner and '$info.Prefix -lt 24' in planner and '$info.Prefix -gt 30' in planner,
    'route_total_targets_bounded':
        'MaxTotalHosts=1024' in planner and "'total-target-limit'" in planner,
    'route_auto_subnets_bounded':
        'MaxAutoSubnets=4' in planner and "'max-auto-subnets'" in planner,
    'route_wrong_interface_excluded': "'wrong-interface'" in planner,
    'route_target_dedup':
        'System.Collections.Generic.HashSet[string]' in planner,
    'route_query_failsoft':
        'RouteQueryError' in planner and "'Get-NetRoute unavailable'" in planner,
    'route_no_mutation':
        all(x not in planner for x in ['New-NetRoute','Set-NetRoute','Remove-NetRoute','New-NetIPAddress','Set-NetIPAddress']),
    'ui_route_aware_opt_in':
        "$chkRouteAware.Text='Route-aware'" in main and '$chkRouteAware.Checked=$false' in main,
    'ui_route_aware_planner':
        'New-RftRouteAwareScanPlan' in main and '$routePlan.Targets' in main,
    'ui_manual_cidr_preserved':
        'Get-IPv4HostsFromCidr $primaryCidr 1024' in main,
    'ui_route_scope_evidence':
        'RouteAware=' in main and 'Scopes=' in main and 'ScopeCount=' in main,
    'live_probe_read_only':
        all(x in live for x in ['Get-NetIPConfiguration','New-RftRouteAwareScanPlan','route-aware-live-summary.json'])
        and all(x not in live for x in ['SendARP','PingSweep','New-NetRoute','Set-NetRoute','Remove-NetRoute']),
    'physical_route_probe_wired':
        all(x in qualification for x in ['route_scope_planner','route_scope_live','WINDOWS_ROUTE_SCOPE_LIVE_TEST_v1_5_1.ps1'])
        and all(x in physical for x in ['route_scope_planner must PASS','route_scope_live must PASS','route-aware-live-summary.json']),
}
failed=[k for k,v in checks.items() if not v]
for k,v in checks.items():
    print(('PASS' if v else 'FAIL'),k)
print('TOTAL',len(checks),'FAILED',len(failed))
if failed:
    print('FAILED_KEYS',failed)
sys.exit(1 if failed else 0)
