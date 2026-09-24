# Pure route-aware IPv4 scope planner for RF-Network-Tool.
# This file is dot-sourced by the WinForms UI and can be tested independently on Windows PowerShell 5.1.

function Convert-RftIPv4ToUInt32Strict([string]$Address) {
    if([string]::IsNullOrWhiteSpace($Address) -or $Address -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$'){
        throw "IPv4 không hợp lệ: $Address"
    }
    $parts=$Address.Split('.')
    $value=[uint64]0
    foreach($part in $parts){
        $octet=0
        if(-not [int]::TryParse($part,[ref]$octet) -or $octet -lt 0 -or $octet -gt 255){
            throw "IPv4 không hợp lệ: $Address"
        }
        $value=($value -shl 8) -bor [uint64]$octet
    }
    return [uint32]$value
}

function Convert-RftUInt32ToIPv4([uint32]$Value) {
    $bytes=[byte[]]@(
        [byte](($Value -shr 24) -band 0xff),
        [byte](($Value -shr 16) -band 0xff),
        [byte](($Value -shr 8) -band 0xff),
        [byte]($Value -band 0xff)
    )
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-RftCidrInfo([string]$Cidr) {
    if([string]::IsNullOrWhiteSpace($Cidr) -or $Cidr -notmatch '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*/\s*(\d{1,2})\s*$'){
        throw "CIDR không hợp lệ: $Cidr"
    }
    $address=$Matches[1]
    $prefix=[int]$Matches[2]
    if($prefix -lt 0 -or $prefix -gt 32){throw "Prefix CIDR không hợp lệ: $Cidr"}
    $ipValue=Convert-RftIPv4ToUInt32Strict $address
    $full=[uint64][uint32]::MaxValue
    $hostMask=if($prefix -eq 0){$full}else{[uint64]([math]::Pow(2,32-$prefix)-1)}
    $mask=[uint32]($full-$hostMask)
    $network=[uint32]($ipValue -band $mask)
    $broadcast=[uint32]([uint64]$network+$hostMask)
    $hostCount=if($prefix -le 30){[int64]([math]::Pow(2,32-$prefix)-2)}else{0}
    return [pscustomobject]@{
        Address=$address
        Prefix=$prefix
        NetworkValue=$network
        BroadcastValue=$broadcast
        Network=(Convert-RftUInt32ToIPv4 $network)
        Broadcast=(Convert-RftUInt32ToIPv4 $broadcast)
        HostCount=$hostCount
        Canonical=("$(Convert-RftUInt32ToIPv4 $network)/$prefix")
    }
}

function Test-RftPrivateIPv4Range([uint32]$NetworkValue,[uint32]$BroadcastValue) {
    $ranges=@(
        @((Convert-RftIPv4ToUInt32Strict '10.0.0.0'),(Convert-RftIPv4ToUInt32Strict '10.255.255.255')),
        @((Convert-RftIPv4ToUInt32Strict '172.16.0.0'),(Convert-RftIPv4ToUInt32Strict '172.31.255.255')),
        @((Convert-RftIPv4ToUInt32Strict '192.168.0.0'),(Convert-RftIPv4ToUInt32Strict '192.168.255.255'))
    )
    foreach($range in $ranges){
        if([uint64]$NetworkValue -ge [uint64]$range[0] -and [uint64]$BroadcastValue -le [uint64]$range[1]){return $true}
    }
    return $false
}

function Get-RftHostsFromCidr([string]$Cidr,[int]$MaxHosts=1024) {
    $info=Get-RftCidrInfo $Cidr
    if($info.Prefix -lt 16 -or $info.Prefix -gt 30){
        throw "CIDR $($info.Canonical) phải nằm trong /16.. /30."
    }
    if([int64]$info.HostCount -gt [int64]$MaxHosts){
        throw "CIDR $($info.Canonical) có $($info.HostCount) host; vượt giới hạn $MaxHosts."
    }
    $list=New-Object System.Collections.Generic.List[string]
    for($offset=1;$offset -le [int]$info.HostCount;$offset++){
        [void]$list.Add((Convert-RftUInt32ToIPv4 ([uint32]([uint64]$info.NetworkValue+[uint64]$offset))))
    }
    return $list.ToArray()
}

function Add-RftSkippedRoute($List,[string]$DestinationPrefix,[string]$Reason) {
    [void]$List.Add([pscustomobject]@{DestinationPrefix=$DestinationPrefix;Reason=$Reason})
}

function New-RftRouteAwareScanPlan(
    [Parameter(Mandatory=$true)][string]$PrimaryCidr,
    [Parameter(Mandatory=$true)][int]$InterfaceIndex,
    [object[]]$RouteEntries=$null,
    [int]$MaxAutoSubnets=4,
    [int]$MaxTotalHosts=1024,
    [int]$MaxAutoHostsPerSubnet=254
) {
    if($InterfaceIndex -le 0){throw 'InterfaceIndex phải là số dương.'}
    if($MaxAutoSubnets -lt 0){throw 'MaxAutoSubnets không hợp lệ.'}
    if($MaxTotalHosts -lt 1){throw 'MaxTotalHosts không hợp lệ.'}
    if($MaxAutoHostsPerSubnet -lt 1){throw 'MaxAutoHostsPerSubnet không hợp lệ.'}

    $primaryInfo=Get-RftCidrInfo $PrimaryCidr
    if(-not (Test-RftPrivateIPv4Range $primaryInfo.NetworkValue $primaryInfo.BroadcastValue)){
        throw "Route-aware chỉ cho phép primary CIDR thuộc RFC1918 private IPv4."
    }
    $primaryHosts=@(Get-RftHostsFromCidr $primaryInfo.Canonical $MaxTotalHosts)

    $targetSet=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach($ip in $primaryHosts){[void]$targetSet.Add([string]$ip)}

    $scopes=New-Object System.Collections.Generic.List[object]
    [void]$scopes.Add([pscustomobject]@{
        Cidr=$primaryInfo.Canonical;Source='Primary';HostCount=$primaryHosts.Count;NextHop='';RouteMetric=0
    })
    $skipped=New-Object System.Collections.Generic.List[object]
    $routeQueryError=''

    $routes=$RouteEntries
    if($null -eq $RouteEntries){
        if(Get-Command Get-NetRoute -ErrorAction SilentlyContinue){
            try{
                $routes=@(Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $InterfaceIndex -ErrorAction Stop)
            }catch{
                $routeQueryError=$_.Exception.Message
                $routes=@()
            }
        }else{
            $routeQueryError='Get-NetRoute unavailable'
            $routes=@()
        }
    }

    $candidates=New-Object System.Collections.Generic.List[object]
    foreach($route in @($routes)){
        if($null -eq $route){continue}
        $dest=([string]$route.DestinationPrefix).Trim()
        if([string]::IsNullOrWhiteSpace($dest)){continue}
        if($dest -eq '0.0.0.0/0'){Add-RftSkippedRoute $skipped $dest 'default-route';continue}

        $routeIf=$InterfaceIndex
        try{
            if($route.PSObject.Properties['InterfaceIndex']){$routeIf=[int]$route.InterfaceIndex}
        }catch{$routeIf=-1}
        if($routeIf -ne $InterfaceIndex){Add-RftSkippedRoute $skipped $dest 'wrong-interface';continue}

        try{$info=Get-RftCidrInfo $dest}catch{Add-RftSkippedRoute $skipped $dest 'invalid-cidr';continue}
        if(-not (Test-RftPrivateIPv4Range $info.NetworkValue $info.BroadcastValue)){Add-RftSkippedRoute $skipped $dest 'non-private';continue}
        if($info.Prefix -lt 24){Add-RftSkippedRoute $skipped $dest 'auto-scope-too-wide';continue}
        if($info.Prefix -gt 30 -or $info.HostCount -le 0){Add-RftSkippedRoute $skipped $dest 'no-host-range';continue}
        if($info.Canonical -eq $primaryInfo.Canonical){Add-RftSkippedRoute $skipped $dest 'duplicate-scope';continue}
        if($info.HostCount -gt $MaxAutoHostsPerSubnet){Add-RftSkippedRoute $skipped $dest 'auto-scope-too-wide';continue}

        $metric=[int]::MaxValue
        try{if($route.PSObject.Properties['RouteMetric']){$metric=[int]$route.RouteMetric}}catch{}
        $nextHop=''
        try{if($route.PSObject.Properties['NextHop']){$nextHop=[string]$route.NextHop}}catch{}
        [void]$candidates.Add([pscustomobject]@{
            Cidr=$info.Canonical;Prefix=[int]$info.Prefix;HostCount=[int]$info.HostCount;RouteMetric=$metric;NextHop=$nextHop
        })
    }

    $autoScopeCount=0
    foreach($candidate in @($candidates | Sort-Object RouteMetric,Cidr)){
        if($autoScopeCount -ge $MaxAutoSubnets){
            Add-RftSkippedRoute $skipped ([string]$candidate.Cidr) 'max-auto-subnets'
            continue
        }

        $hosts=@(Get-RftHostsFromCidr ([string]$candidate.Cidr) $MaxAutoHostsPerSubnet)
        $newHosts=New-Object System.Collections.Generic.List[string]
        foreach($ip in $hosts){if(-not $targetSet.Contains([string]$ip)){[void]$newHosts.Add([string]$ip)}}
        if($newHosts.Count -eq 0){Add-RftSkippedRoute $skipped ([string]$candidate.Cidr) 'duplicate-scope';continue}
        if(($targetSet.Count+$newHosts.Count) -gt $MaxTotalHosts){
            Add-RftSkippedRoute $skipped ([string]$candidate.Cidr) 'total-target-limit'
            continue
        }

        foreach($ip in $newHosts){[void]$targetSet.Add([string]$ip)}
        [void]$scopes.Add([pscustomobject]@{
            Cidr=[string]$candidate.Cidr;Source='Route';HostCount=$newHosts.Count;NextHop=[string]$candidate.NextHop;RouteMetric=[int]$candidate.RouteMetric
        })
        $autoScopeCount++
    }

    $targets=@($targetSet | Sort-Object {[uint64](Convert-RftIPv4ToUInt32Strict ([string]$_))})
    return [pscustomobject]@{
        Mode='RouteAware'
        PrimaryCidr=$primaryInfo.Canonical
        InterfaceIndex=$InterfaceIndex
        Scopes=@($scopes.ToArray())
        Targets=$targets
        SkippedRoutes=@($skipped.ToArray())
        RouteQueryError=$routeQueryError
        TotalTargets=$targets.Count
        AutoScopeCount=$autoScopeCount
    }
}
