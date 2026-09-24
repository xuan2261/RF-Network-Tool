[CmdletBinding()]
param([int]$InterfaceIndex=0)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$planner=Join-Path $root 'RF-Network-Tool-RoutePlanner.ps1'
$artifactDir=Join-Path $root 'ci-artifacts'
New-Item -ItemType Directory -Path $artifactDir -Force|Out-Null
$fail=New-Object System.Collections.Generic.List[string]

function Assert-True([bool]$condition,[string]$name){
    if($condition){Write-Host "PASS $name" -ForegroundColor Green}
    else{Write-Host "FAIL $name" -ForegroundColor Red;[void]$fail.Add($name)}
}
function Get-RftLiveRouteContext {
    $configs=if($InterfaceIndex -gt 0){
        @(Get-NetIPConfiguration -InterfaceIndex $InterfaceIndex -ErrorAction Stop)
    }else{
        @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {$_.IPv4Address -and $_.IPv4DefaultGateway})
    }
    foreach($c in $configs){
        $adapter=Get-NetAdapter -InterfaceIndex $c.InterfaceIndex -ErrorAction SilentlyContinue
        if(-not $adapter -or [string]$adapter.Status -ne 'Up'){continue}
        if($InterfaceIndex -le 0 -and -not [bool]$adapter.HardwareInterface){continue}
        if($InterfaceIndex -le 0 -and [string]$adapter.InterfaceDescription -match '(?i)Tailscale|WireGuard|ZeroTier|VPN|Hyper-V|vEthernet|Loopback|WSL|VMware|VirtualBox'){continue}
        $ipObj=@($c.IPv4Address | Where-Object {$_.IPAddress -and $_.IPAddress -ne '127.0.0.1'} | Select-Object -First 1)
        if(-not $ipObj){continue}
        $ip=[string]$ipObj[0].IPAddress
        try{$ipValue=Convert-RftIPv4ToUInt32Strict $ip}catch{continue}
        if(-not (Test-RftPrivateIPv4Range $ipValue $ipValue)){continue}
        $prefix=[int]$ipObj[0].PrefixLength
        if($prefix -gt 30){continue}
        $primaryPrefix=if($prefix -lt 22){24}else{$prefix}
        $primary=(Get-RftCidrInfo ("{0}/{1}" -f $ip,$primaryPrefix)).Canonical
        return [pscustomobject]@{
            InterfaceIndex=[int]$c.InterfaceIndex
            InterfaceName=[string]$adapter.Name
            LocalIP=$ip
            AdapterPrefix=$prefix
            PrimaryPrefix=$primaryPrefix
            PrimaryCidr=$primary
        }
    }
    return $null
}

Assert-True (Test-Path -LiteralPath $planner) 'Route planner script exists'
if($fail.Count){exit 1}
. $planner

$ctx=Get-RftLiveRouteContext
if($null -eq $ctx){
    Write-Host 'SKIP Route-aware live probe: no active physical RFC1918 IPv4 adapter.' -ForegroundColor Yellow
    exit 3
}

$plan=New-RftRouteAwareScanPlan -PrimaryCidr $ctx.PrimaryCidr -InterfaceIndex $ctx.InterfaceIndex -MaxAutoSubnets 4 -MaxTotalHosts 1024 -MaxAutoHostsPerSubnet 254
Assert-True ([string]::IsNullOrWhiteSpace([string]$plan.RouteQueryError)) 'Live Get-NetRoute query succeeds'
Assert-True ([int]$plan.InterfaceIndex -eq [int]$ctx.InterfaceIndex) 'Live route plan stays on selected interface'
Assert-True ([int]$plan.TotalTargets -ge 2 -and [int]$plan.TotalTargets -le 1024) 'Live route plan target count bounded to 2..1024'
Assert-True ([int]$plan.AutoScopeCount -ge 0 -and [int]$plan.AutoScopeCount -le 4) 'Live route plan auto-scope count bounded to 0..4'
Assert-True (@($plan.Scopes).Count -eq (1+[int]$plan.AutoScopeCount)) 'Live route plan scope count consistent'

foreach($scope in @($plan.Scopes)){
    $info=Get-RftCidrInfo ([string]$scope.Cidr)
    Assert-True (Test-RftPrivateIPv4Range $info.NetworkValue $info.BroadcastValue) ("Live scope private: "+[string]$scope.Source)
    if([string]$scope.Source -eq 'Route'){
        Assert-True ($info.Prefix -ge 24 -and $info.Prefix -le 30) 'Live automatic scope prefix /24..30'
        Assert-True ([int]$scope.HostCount -le 254) 'Live automatic scope <=254 hosts'
    }
}

$reasonCounts=[ordered]@{}
foreach($row in @($plan.SkippedRoutes)){
    $reason=[string]$row.Reason
    if([string]::IsNullOrWhiteSpace($reason)){continue}
    if(-not $reasonCounts.Contains($reason)){$reasonCounts[$reason]=0}
    $reasonCounts[$reason]=[int]$reasonCounts[$reason]+1
}
$safe=[ordered]@{
    schemaVersion=1
    interfaceIndex=[int]$ctx.InterfaceIndex
    adapterPrefix=[int]$ctx.AdapterPrefix
    primaryPrefix=[int]$ctx.PrimaryPrefix
    scopeCount=@($plan.Scopes).Count
    autoScopeCount=[int]$plan.AutoScopeCount
    totalTargets=[int]$plan.TotalTargets
    routeQueryOk=[string]::IsNullOrWhiteSpace([string]$plan.RouteQueryError)
    skippedReasonCounts=$reasonCounts
}
[IO.File]::WriteAllText(
    (Join-Path $artifactDir 'route-aware-live-summary.json'),
    ($safe|ConvertTo-Json -Depth 5),
    (New-Object Text.UTF8Encoding($true))
)

if($fail.Count){Write-Host ("FAILED: "+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host ("ROUTE-AWARE LIVE PROBE PASSED interface={0} scopes={1} auto={2} targets={3}" -f $ctx.InterfaceIndex,@($plan.Scopes).Count,$plan.AutoScopeCount,$plan.TotalTargets) -ForegroundColor Green
exit 0
