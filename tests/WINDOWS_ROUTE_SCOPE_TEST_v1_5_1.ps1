param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$planner=Join-Path $root 'RF-Network-Tool-RoutePlanner.ps1'
$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$condition,[string]$name){if($condition){Write-Host "PASS $name" -ForegroundColor Green}else{Write-Host "FAIL $name" -ForegroundColor Red;[void]$fail.Add($name)}}
function Assert-Throws([scriptblock]$body,[string]$name){$threw=$false;try{& $body}catch{$threw=$true};Assert-True $threw $name}

Assert-True (Test-Path -LiteralPath $planner) 'Route planner script exists'
if(Test-Path -LiteralPath $planner){. $planner}

$routes=@(
    [pscustomobject]@{DestinationPrefix='192.168.10.0/24';InterfaceIndex=36;NextHop='0.0.0.0';RouteMetric=50},
    [pscustomobject]@{DestinationPrefix='192.168.20.0/24';InterfaceIndex=36;NextHop='192.168.10.1';RouteMetric=20},
    [pscustomobject]@{DestinationPrefix='10.20.30.0/24';InterfaceIndex=36;NextHop='192.168.10.1';RouteMetric=10},
    [pscustomobject]@{DestinationPrefix='172.16.4.0/23';InterfaceIndex=36;NextHop='192.168.10.1';RouteMetric=5},
    [pscustomobject]@{DestinationPrefix='8.8.8.0/24';InterfaceIndex=36;NextHop='192.168.10.1';RouteMetric=1},
    [pscustomobject]@{DestinationPrefix='192.168.30.0/24';InterfaceIndex=99;NextHop='0.0.0.0';RouteMetric=1},
    [pscustomobject]@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=36;NextHop='192.168.10.1';RouteMetric=1},
    [pscustomobject]@{DestinationPrefix='192.168.50.12/32';InterfaceIndex=36;NextHop='0.0.0.0';RouteMetric=1}
)
if(Test-Path -LiteralPath $planner){
    $plan=New-RftRouteAwareScanPlan -PrimaryCidr '192.168.10.0/24' -InterfaceIndex 36 -RouteEntries $routes
    Assert-True ([int]$plan.TotalTargets -eq 762) 'Primary plus two eligible /24 routes yields 762 unique targets'
    Assert-True (@($plan.Targets|Select-Object -Unique).Count -eq @($plan.Targets).Count) 'Route-aware targets are unique'
    Assert-True (@($plan.Scopes).Count -eq 3) 'Route-aware plan exposes three accepted scopes'
    Assert-True (@($plan.Scopes|Where-Object {$_.Cidr -eq '192.168.20.0/24'}).Count -eq 1) 'Private routed /24 accepted'
    Assert-True (@($plan.Scopes|Where-Object {$_.Cidr -eq '10.20.30.0/24'}).Count -eq 1) 'Second RFC1918 routed /24 accepted'
    $reasons=@($plan.SkippedRoutes|ForEach-Object {[string]$_.Reason})
    foreach($reason in @('duplicate-scope','auto-scope-too-wide','non-private','wrong-interface','default-route','no-host-range')){
        Assert-True ($reasons -contains $reason) ("Rejected route reason "+$reason)
    }

    $limitPlan=New-RftRouteAwareScanPlan -PrimaryCidr '10.0.0.0/22' -InterfaceIndex 36 -RouteEntries @([pscustomobject]@{DestinationPrefix='192.168.20.0/24';InterfaceIndex=36;NextHop='10.0.0.1';RouteMetric=1})
    Assert-True ([int]$limitPlan.TotalTargets -eq 1022) 'Primary /22 remains within 1024-target hard cap'
    Assert-True (@($limitPlan.SkippedRoutes|Where-Object {$_.Reason -eq 'total-target-limit'}).Count -eq 1) 'Auto route skipped instead of exceeding total target cap'

    $many=@()
    1..5|ForEach-Object {$many += [pscustomobject]@{DestinationPrefix=("192.168.{0}.0/24" -f (100+$_));InterfaceIndex=36;NextHop='192.168.1.1';RouteMetric=$_}}
    $subnetPlan=New-RftRouteAwareScanPlan -PrimaryCidr '192.168.1.0/24' -InterfaceIndex 36 -RouteEntries $many -MaxTotalHosts 2000
    Assert-True ([int]$subnetPlan.AutoScopeCount -eq 4) 'Auto route expansion capped at four subnets'
    Assert-True (@($subnetPlan.SkippedRoutes|Where-Object {$_.Reason -eq 'max-auto-subnets'}).Count -eq 1) 'Fifth auto route skipped by subnet cap'

    $priorityRoutes=@(
      [pscustomobject]@{DestinationPrefix='192.168.60.0/24';InterfaceIndex=36;NextHop='192.168.1.1';RouteMetric=50},
      [pscustomobject]@{DestinationPrefix='192.168.61.0/24';InterfaceIndex=36;NextHop='192.168.1.1';RouteMetric=5}
    )
    $priority=New-RftRouteAwareScanPlan -PrimaryCidr '192.168.1.0/24' -InterfaceIndex 36 -RouteEntries $priorityRoutes -MaxAutoSubnets 1 -MaxTotalHosts 600
    Assert-True (@($priority.Scopes|Where-Object {$_.Cidr -eq '192.168.61.0/24'}).Count -eq 1) 'Lower route metric wins deterministic bounded slot'
    Assert-True (@($priority.Scopes|Where-Object {$_.Cidr -eq '192.168.60.0/24'}).Count -eq 0) 'Higher metric route excluded after cap'

    $empty=New-RftRouteAwareScanPlan -PrimaryCidr '192.168.77.0/24' -InterfaceIndex 36 -RouteEntries @()
    Assert-True ([int]$empty.TotalTargets -eq 254 -and [int]$empty.AutoScopeCount -eq 0) 'Empty route fixture degrades to primary CIDR only'

    Assert-Throws { New-RftRouteAwareScanPlan -PrimaryCidr '8.8.8.0/24' -InterfaceIndex 36 -RouteEntries @() | Out-Null } 'Route-aware primary CIDR must be RFC1918 private'
    Assert-Throws { New-RftRouteAwareScanPlan -PrimaryCidr '192.168.999.0/24' -InterfaceIndex 36 -RouteEntries @() | Out-Null } 'Invalid dotted-quad CIDR rejected'
}
if($fail.Count){Write-Host ("FAILED: "+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL WINDOWS ROUTE-SCOPE PLANNER TESTS PASSED' -ForegroundColor Green
exit 0
