[CmdletBinding()]
param(
    [string]$Profiles='FAST,BALANCED',
    [int]$InterfaceIndex=0
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$worker=Join-Path $root 'RF-Network-Tool-ScanWorker.ps1'
$artifactDir=Join-Path $root 'ci-artifacts'
New-Item -ItemType Directory -Path $artifactDir -Force|Out-Null
$fail=New-Object System.Collections.Generic.List[string]

function Assert-True([bool]$condition,[string]$name){
    if($condition){Write-Host "PASS $name" -ForegroundColor Green}
    else{Write-Host "FAIL $name" -ForegroundColor Red;[void]$fail.Add($name)}
}
function Convert-IPv4ToUInt64([string]$ip){
    $b=[Net.IPAddress]::Parse($ip).GetAddressBytes()
    return ([uint64]$b[0]*16777216)+([uint64]$b[1]*65536)+([uint64]$b[2]*256)+[uint64]$b[3]
}
function Convert-UInt64ToIPv4([uint64]$n){
    return ('{0}.{1}.{2}.{3}' -f (($n -shr 24)-band 255),(($n -shr 16)-band 255),(($n -shr 8)-band 255),($n-band 255))
}
function Test-LocalSafeIPv4([string]$ip){
    $b=[Net.IPAddress]::Parse($ip).GetAddressBytes()
    return (
        $b[0] -eq 10 -or
        ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168) -or
        ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or
        ($b[0] -eq 169 -and $b[1] -eq 254)
    )
}
function Get-LanContext{
    $configs=if($InterfaceIndex -gt 0){
        @(Get-NetIPConfiguration -InterfaceIndex $InterfaceIndex -ErrorAction Stop)
    }else{
        @(Get-NetIPConfiguration -ErrorAction Stop|Where-Object {$_.IPv4Address -and $_.IPv4DefaultGateway})
    }
    foreach($c in $configs){
        $a=Get-NetAdapter -InterfaceIndex $c.InterfaceIndex -ErrorAction SilentlyContinue
        if(-not $a -or [string]$a.Status -ne 'Up'){continue}
        if($InterfaceIndex -le 0 -and -not [bool]$a.HardwareInterface){continue}
        if($InterfaceIndex -le 0 -and [string]$a.InterfaceDescription -match '(?i)Tailscale|WireGuard|ZeroTier|VPN|Hyper-V|vEthernet|Loopback|WSL|VMware|VirtualBox'){continue}
        $ipObj=@($c.IPv4Address|Where-Object {$_.IPAddress -and $_.IPAddress -ne '127.0.0.1'}|Select-Object -First 1)
        if(-not $ipObj){continue}
        $ip=[string]$ipObj[0].IPAddress
        if($InterfaceIndex -le 0 -and -not(Test-LocalSafeIPv4 $ip)){continue}
        $gw=@($c.IPv4DefaultGateway|Select-Object -First 1)
        return [pscustomobject]@{
            IfIndex=[int]$c.InterfaceIndex
            Name=[string]$a.Name
            Description=[string]$a.InterfaceDescription
            Mac=[string]$a.MacAddress
            IP=$ip
            Prefix=[int]$ipObj[0].PrefixLength
            Gateway=if($gw){[string]$gw[0].NextHop}else{''}
        }
    }
    return $null
}
function Build-Targets([string]$ip,[int]$prefix){
    if($prefix -gt 30){throw "Prefix /$prefix is too narrow."}
    $scanPrefix=[Math]::Max($prefix,24)
    $block=[uint64][Math]::Pow(2,32-$scanPrefix)
    $value=Convert-IPv4ToUInt64 $ip
    $network=[uint64]([Math]::Floor([double]$value/[double]$block)*[double]$block)
    $targets=New-Object System.Collections.Generic.List[string]
    for($n=$network+1;$n -le $network+$block-2;$n++){[void]$targets.Add((Convert-UInt64ToIPv4 $n))}
    if($targets.Count -gt 254){throw "Refusing to probe more than 254 hosts."}
    return $targets.ToArray()
}
function Write-Json([string]$path,$value){
    [IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
}

Assert-True (Test-Path -LiteralPath $worker) 'ScanWorker exists'
if($fail.Count){exit 1}

$ctx=Get-LanContext
if($null -eq $ctx){
    Write-Host 'SKIP Real-LAN: no active physical private/link-local/CGNAT IPv4 adapter with a default gateway.' -ForegroundColor Yellow
    exit 3
}
Write-Host ("Selected interface: ifIndex={0} name={1} ip={2}/{3} gateway={4}" -f $ctx.IfIndex,$ctx.Name,$ctx.IP,$ctx.Prefix,$ctx.Gateway)
if(-not(Test-LocalSafeIPv4 $ctx.IP)){
    Write-Host 'SKIP Real-LAN: refusing to probe a public IPv4 subnet.' -ForegroundColor Yellow
    exit 3
}

$targets=Build-Targets $ctx.IP $ctx.Prefix
Assert-True ($targets.Count -ge 2 -and $targets.Count -le 254) 'Target count bounded to 2..254'
$profileList=@($Profiles.Split(',')|ForEach-Object {$_.Trim().ToUpperInvariant()}|Where-Object {$_})
foreach($profile in $profileList){Assert-True ($profile -in @('FAST','BALANCED')) "Profile allowed: $profile"}
if($fail.Count){exit 1}

$tmp=Join-Path $env:TEMP ('RFT-real-lan-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force|Out-Null
$summary=New-Object System.Collections.Generic.List[object]
try{
    foreach($profile in $profileList){
        $runId='real-lan-'+$profile.ToLowerInvariant()+'-'+[guid]::NewGuid().ToString('N')
        $cfg=Join-Path $tmp ($profile+'.config.json')
        $state=Join-Path $tmp ($profile+'.state.json')
        $cancel=Join-Path $tmp ($profile+'.cancel.flag')
        $log=Join-Path $tmp ($profile+'.worker.log')
        $config=[ordered]@{
            schemaVersion=3;RunId=$runId;Targets=$targets;Profile=$profile
            LocalIP=$ctx.IP;LocalMAC=$ctx.Mac;InterfaceIndex=$ctx.IfIndex
            FastPingTimeoutMs=250;RetryEnabled=($profile -ne 'FAST');RetryPingTimeoutMs=700
            PingConcurrency=if($profile -eq 'FAST'){128}else{64}
            ArpConcurrency=64;DiscoveryDurationSec=if($profile -eq 'FAST'){1}else{4};DiscoveryMode=$profile
        }
        Write-Json $cfg $config
        $sw=[Diagnostics.Stopwatch]::StartNew()
        & $worker -ConfigFile $cfg -StateFile $state -CancelFile $cancel -LogFile $log -ParentPid $PID -ParentStartTicks ([long](Get-Process -Id $PID).StartTime.Ticks)
        $rc=$LASTEXITCODE;$sw.Stop()
        Assert-True ($rc -eq 0) "$profile worker exit 0"
        Assert-True (Test-Path $state) "$profile state exists"
        if(Test-Path $state){
            $s=[IO.File]::ReadAllText($state)|ConvertFrom-Json
            $rows=@($s.results);$unique=@($rows|ForEach-Object {[string]$_.IP}|Sort-Object -Unique)
            Assert-True ([string]$s.runId -eq $runId) "$profile runId matches"
            Assert-True ([bool]$s.complete -and -not [bool]$s.cancelled) "$profile completes"
            Assert-True (-not [string]$s.error) "$profile no worker error"
            Assert-True ([int]$s.total -eq $targets.Count) "$profile target count preserved"
            Assert-True ($unique.Count -eq $rows.Count) "$profile no duplicate result IPs"
            Assert-True (@($rows|Where-Object {$_.IP -eq $ctx.IP}).Count -eq 1) "$profile local IPv4 discovered exactly once"
            if($targets -contains $ctx.Gateway){Assert-True (@($rows|Where-Object {$_.IP -eq $ctx.Gateway}).Count -le 1) "$profile gateway row not duplicated"}
            [void]$summary.Add([pscustomobject]@{profile=$profile;elapsedMs=[int64]$sw.ElapsedMilliseconds;targets=$targets.Count;online=[int]$s.online;seen=[int]$s.seen;discovered=$rows.Count})
            Copy-Item $state (Join-Path $artifactDir ("real-lan-$($profile.ToLowerInvariant())-state.json")) -Force
        }
        if(Test-Path $log){Copy-Item $log (Join-Path $artifactDir ("real-lan-$($profile.ToLowerInvariant())-worker.log")) -Force}
    }
    Write-Json (Join-Path $artifactDir 'real-lan-summary.json') ([ordered]@{schemaVersion=1;interfaceIndex=$ctx.IfIndex;interfaceName=$ctx.Name;localIP=$ctx.IP;prefix=$ctx.Prefix;gateway=$ctx.Gateway;profiles=$summary.ToArray()})
}finally{Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue}

if($fail.Count){Write-Host ("FAILED: "+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL REAL-LAN QUALIFICATION TESTS PASSED' -ForegroundColor Green
exit 0
