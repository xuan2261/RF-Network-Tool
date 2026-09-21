param(
    [Parameter(Mandatory=$true)][string]$ConfigFile,
    [Parameter(Mandatory=$true)][string]$StateFile,
    [Parameter(Mandatory=$true)][string]$CancelFile,
    [string]$LogFile = '',
    [int]$ParentPid = 0,
    [long]$ParentStartTicks = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-WorkerLog([string]$message) {
    if([string]::IsNullOrWhiteSpace($LogFile)){return}
    try{[IO.File]::AppendAllText($LogFile,"[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))] [SCAN-WORKER] $message"+[Environment]::NewLine,[Text.Encoding]::UTF8)}catch{}
}

function Write-TextAtomic([string]$path,[string]$text) {
    $tmp="$path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $enc=New-Object System.Text.UTF8Encoding($true)
    try {
        [IO.File]::WriteAllText($tmp,$text,$enc)
        if(Test-Path -LiteralPath $path){
            try{[IO.File]::Replace($tmp,$path,$null);return}catch{}
        }
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } finally {
        if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
    }
}

function Format-Mac([string]$mac) {
    if([string]::IsNullOrWhiteSpace($mac)){return ''}
    $c=($mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
    if($c.Length -ne 12){return ''}
    return (($c -split '(.{2})' | Where-Object {$_}) -join '-')
}

function Test-ParentAlive {
    if($ParentPid -le 0 -or $ParentStartTicks -le 0){return $true}
    try{$parentProcess=Get-Process -Id $ParentPid -ErrorAction Stop;return ([long]$parentProcess.StartTime.Ticks -eq $ParentStartTicks)}catch{return $false}
}
function Test-Cancelled { return ((Test-Path -LiteralPath $CancelFile) -or -not(Test-ParentAlive)) }

$config=$null
try {
    $config=[IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-WorkerLog ('CONFIG ERROR: '+$_.Exception.Message)
    exit 2
}

$targets=@($config.Targets | ForEach-Object {[string]$_} | Where-Object {$_} | Select-Object -Unique)
$total=$targets.Count
$localIp=[string]$config.LocalIP
$localMac=Format-Mac ([string]$config.LocalMAC)
$interfaceIndex=[int]$config.InterfaceIndex
$scanProfile=if($config.PSObject.Properties['Profile']){([string]$config.Profile).ToUpperInvariant()}else{'BALANCED'}
if($scanProfile -notin @('FAST','BALANCED','DEEP')){$scanProfile='BALANCED'}
$fastTimeout=[Math]::Max(100,[Math]::Min(2000,[int]$config.FastPingTimeoutMs))
$retryTimeout=[Math]::Max($fastTimeout,[Math]::Min(3000,[int]$config.RetryPingTimeoutMs))
$pingConcurrency=[Math]::Max(8,[Math]::Min(128,[int]$config.PingConcurrency))
$arpConcurrency=[Math]::Max(4,[Math]::Min(64,[int]$config.ArpConcurrency))
$retryEnabled=$true
if($config.PSObject.Properties['RetryEnabled']){$retryEnabled=[bool]$config.RetryEnabled}
$discoveryDurationSec=if($config.PSObject.Properties['DiscoveryDurationSec']){[Math]::Max(0,[Math]::Min(120,[int]$config.DiscoveryDurationSec))}else{20}
$discoveryMode=if($config.PSObject.Properties['DiscoveryMode']){[string]$config.DiscoveryMode}else{$scanProfile}

$results=@{}
$online=0
$seen=0
$phase='starting'
$done=0
$runId=if($config.PSObject.Properties['RunId'] -and -not [string]::IsNullOrWhiteSpace([string]$config.RunId)){[string]$config.RunId}else{[guid]::NewGuid().ToString('N')}
$startedAt=(Get-Date).ToString('o')
$workerSw=[Diagnostics.Stopwatch]::StartNew()
$fastSuccessCount=0
$fastResponseRate=0.0
$fastAverageMs=0.0
$effectivePingConcurrency=$pingConcurrency
$effectiveRetryConcurrency=[Math]::Min($pingConcurrency,64)
$effectiveArpConcurrency=$arpConcurrency
$ipv6Neighbors=@()
$ipv6NeighborError=''

function Get-OrCreateResult([string]$ip) {
    if(-not $results.ContainsKey($ip)){
        $results[$ip]=[pscustomobject]@{
            IP=$ip;Status='Unknown';MAC='';Latency='';TTL='';
            IcmpFast=$false;IcmpFastStatus='Not attempted';IcmpFastMs='';IcmpFastTTL='';
            IcmpRetry=$false;IcmpRetryStatus='Not attempted';IcmpRetryMs='';IcmpRetryTTL='';
            Arp=$false;ArpStatus='Not attempted';ArpError='';ArpMAC='';
            Neighbor=$false;NeighborState='Not observed';NeighborMAC='';
            Evidence=''
        }
    }
    return $results[$ip]
}

function Recount {
    $script:online=@($results.Values | Where-Object {$_.Status -eq 'Online'}).Count
    $script:seen=@($results.Values | Where-Object {$_.Status -eq 'L2 Seen'}).Count
}

function Write-State([bool]$complete=$false,[bool]$cancelled=$false,[string]$errorMessage='') {
    try {
        Recount
        $payload=[ordered]@{
            schemaVersion=3
            runId=$runId
            profile=$scanProfile
            startedAt=$startedAt
            elapsedMs=[int]$workerSw.ElapsedMilliseconds
            phase=$phase
            complete=$complete
            cancelled=$cancelled
            error=$errorMessage
            done=$done
            total=$total
            online=$online
            seen=$seen
            ipv6Neighbors=@($ipv6Neighbors)
            updatedAt=(Get-Date).ToString('o')
            metrics=[ordered]@{
                FastSuccessCount=$fastSuccessCount
                FastResponseRate=$fastResponseRate
                FastAverageMs=$fastAverageMs
                EffectivePingConcurrency=$effectivePingConcurrency
                EffectiveRetryConcurrency=$effectiveRetryConcurrency
                EffectiveArpConcurrency=$effectiveArpConcurrency
                IPv6NeighborCount=@($ipv6Neighbors).Count
                IPv6NeighborError=$ipv6NeighborError
                RetryEnabled=$retryEnabled
                DiscoveryMode=$discoveryMode
                DiscoveryDurationSec=$discoveryDurationSec
            }
            results=@($results.Values | Where-Object {$_.Status -ne 'Unknown'} | Sort-Object IP)
        }
        Write-TextAtomic $StateFile (ConvertTo-Json -InputObject $payload -Depth 5)
    } catch { Write-WorkerLog ('STATE WRITE ERROR: '+$_.Exception.Message) }
}

$native=@'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public sealed class RftPingResult {
    public string IP;
    public bool Success;
    public long RoundtripTime;
    public int TTL;
    public string Status;
}

public sealed class RftArpResult {
    public string IP;
    public string MAC;
    public int Error;
}

public static class RftDiscoveryNative {
    [DllImport("iphlpapi.dll", ExactSpelling=true)]
    private static extern int SendARP(uint DestIP, uint SrcIP, [Out] byte[] pMacAddr, ref int PhyAddrLen);

    private static uint ToIpAddr(string ip) {
        byte[] b = IPAddress.Parse(ip).GetAddressBytes();
        return BitConverter.ToUInt32(b, 0);
    }

    public static RftPingResult[] PingSweep(string[] ips, int timeoutMs, int maxDegree) {
        var bag = new ConcurrentBag<RftPingResult>();
        var opts = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxDegree) };
        Parallel.ForEach(ips, opts, ip => {
            var rr = new RftPingResult { IP=ip, Success=false, RoundtripTime=-1, TTL=-1, Status="Error" };
            try {
                using (var p = new Ping()) {
                    var reply = p.Send(ip, timeoutMs);
                    rr.Status = reply.Status.ToString();
                    if (reply.Status == IPStatus.Success) {
                        rr.Success = true;
                        rr.RoundtripTime = reply.RoundtripTime;
                        if (reply.Options != null) rr.TTL = reply.Options.Ttl;
                    }
                }
            } catch (Exception ex) { rr.Status = ex.GetType().Name; }
            bag.Add(rr);
        });
        return bag.ToArray();
    }

    public static RftArpResult[] ArpSweep(string[] ips, string sourceIp, int maxDegree) {
        var bag = new ConcurrentBag<RftArpResult>();
        uint src = 0;
        if (!String.IsNullOrWhiteSpace(sourceIp)) {
            try { src = ToIpAddr(sourceIp); } catch { src = 0; }
        }
        var opts = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, maxDegree) };
        Parallel.ForEach(ips, opts, ip => {
            var rr = new RftArpResult { IP=ip, MAC="", Error=-1 };
            try {
                byte[] mac = new byte[8];
                int len = 6;
                int rc = SendARP(ToIpAddr(ip), src, mac, ref len);
                rr.Error = rc;
                if (rc == 0 && len >= 6) {
                    rr.MAC = String.Join("-", mac.Take(6).Select(x => x.ToString("X2")).ToArray());
                }
            } catch { rr.Error = -2; }
            bag.Add(rr);
        });
        return bag.ToArray();
    }
}
'@

try {
    if(-not ('RftDiscoveryNative' -as [type])){Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop}
} catch {
    $phase='error';Write-State $true $false ('Native helper compile failed: '+$_.Exception.Message);Write-WorkerLog ('NATIVE ERROR: '+$_.Exception.Message);exit 3
}

try {
    Write-WorkerLog "START Profile=$scanProfile Targets=$total Local=$localIp IfIndex=$interfaceIndex Fast=${fastTimeout}ms Retry=$retryEnabled/${retryTimeout}ms PingConcurrency=$pingConcurrency ArpConcurrency=$arpConcurrency Discovery=$discoveryMode/${discoveryDurationSec}s"
    if($total -eq 0){$phase='done';$done=0;Write-State $true $false '';exit 0}

    # PASS 1: fast ICMP across the complete requested range first, publishing after each bounded chunk.
    $phase='icmp-fast';$done=0;Write-State $false $false ''
    $fastTimes=New-Object System.Collections.Generic.List[double]
    $chunkSize=[Math]::Max(8,$effectivePingConcurrency)
    for($offset=0;$offset -lt $total;$offset+=$chunkSize){
        if(Test-Cancelled){$phase='cancelled';Write-State $true $true '';exit 0}
        $last=[Math]::Min($total-1,$offset+$chunkSize-1)
        $chunk=[string[]]@($targets[$offset..$last])
        $part=@([RftDiscoveryNative]::PingSweep($chunk,$fastTimeout,$effectivePingConcurrency))
        foreach($r in $part){
            $x=Get-OrCreateResult ([string]$r.IP)
            $x.IcmpFastStatus=[string]$r.Status
            if($r.Success){
                $x.Status='Online';$x.Latency=([string]$r.RoundtripTime+' ms');$x.TTL=[string]$r.TTL
                $x.IcmpFast=$true;$x.IcmpFastMs=[string]$r.RoundtripTime;$x.IcmpFastTTL=[string]$r.TTL;$x.Evidence='ICMP fast'
                [void]$fastTimes.Add([double]$r.RoundtripTime)
            }
        }
        $done=[Math]::Min($total,$last+1);Write-State $false $false ''
    }
    $fastSuccessCount=$fastTimes.Count
    $fastResponseRate=if($total -gt 0){[Math]::Round(100.0*$fastSuccessCount/$total,1)}else{0}
    $fastAverageMs=if($fastTimes.Count -gt 0){[Math]::Round(($fastTimes | Measure-Object -Average).Average,1)}else{0}

    # Adaptive limits: slow/high-loss networks get lower retry/ARP concurrency to avoid self-induced loss.
    if($fastSuccessCount -eq 0){
        # Zero replies gives no latency signal; use a conservative retry without treating unused IPs as packet loss.
        $effectiveRetryConcurrency=[Math]::Min($effectiveRetryConcurrency,32)
        $effectiveArpConcurrency=[Math]::Min($effectiveArpConcurrency,32)
    } elseif($fastAverageMs -ge 120){
        $effectiveRetryConcurrency=[Math]::Min($effectiveRetryConcurrency,32)
        $effectiveArpConcurrency=[Math]::Min($effectiveArpConcurrency,24)
    } elseif($fastAverageMs -ge 60){
        $effectiveRetryConcurrency=[Math]::Min($effectiveRetryConcurrency,48)
        $effectiveArpConcurrency=[Math]::Min($effectiveArpConcurrency,32)
    }
    if($total -gt 512){$effectiveRetryConcurrency=[Math]::Min($effectiveRetryConcurrency,32);$effectiveArpConcurrency=[Math]::Min($effectiveArpConcurrency,24)}
    Write-WorkerLog "FAST METRICS success=$fastSuccessCount/$total rate=$fastResponseRate% avg=${fastAverageMs}ms -> retryConcurrency=$effectiveRetryConcurrency arpConcurrency=$effectiveArpConcurrency"
    Write-State $false $false ''

    # PASS 2: retry only misses when the profile enables it.
    $retryTargets=@($targets | Where-Object { -not $results.ContainsKey($_) -or $results[$_].Status -ne 'Online' })
    $phase=if($retryEnabled){'icmp-retry'}else{'icmp-retry-skipped'}
    $done=0;Write-State $false $false ''
    if($retryEnabled -and $retryTargets.Count -gt 0){
        $chunkSize=[Math]::Max(4,$effectiveRetryConcurrency)
        for($offset=0;$offset -lt $retryTargets.Count;$offset+=$chunkSize){
            if(Test-Cancelled){$phase='cancelled';Write-State $true $true '';exit 0}
            $last=[Math]::Min($retryTargets.Count-1,$offset+$chunkSize-1)
            $chunk=[string[]]@($retryTargets[$offset..$last])
            $part=@([RftDiscoveryNative]::PingSweep($chunk,$retryTimeout,$effectiveRetryConcurrency))
            foreach($r in $part){
                $x=Get-OrCreateResult ([string]$r.IP)
                $x.IcmpRetryStatus=[string]$r.Status
                if($r.Success){
                    $x.Status='Online';$x.Latency=([string]$r.RoundtripTime+' ms');$x.TTL=[string]$r.TTL
                    $x.IcmpRetry=$true;$x.IcmpRetryMs=[string]$r.RoundtripTime;$x.IcmpRetryTTL=[string]$r.TTL;$x.Evidence='ICMP retry'
                }
            }
            $done=[Math]::Min($retryTargets.Count,$last+1);Write-State $false $false ''
        }
    }
    foreach($ip in $targets){
        if($results.ContainsKey($ip)){
            if($results[$ip].IcmpFast -and $results[$ip].IcmpRetryStatus -eq 'Not attempted'){$results[$ip].IcmpRetryStatus='Skipped - fast ICMP success'}
            elseif(-not $retryEnabled -and $results[$ip].IcmpRetryStatus -eq 'Not attempted'){$results[$ip].IcmpRetryStatus='Skipped - FAST profile'}
        }
    }
    $done=$retryTargets.Count;Write-State $false $false ''

    # PASS 3: active ARP across the whole on-link range, progressively publishing L2-only hosts.
    if(Test-Cancelled){$phase='cancelled';Write-State $true $true '';exit 0}
    $phase='arp-active';$done=0;Write-State $false $false ''
    $chunkSize=[Math]::Max(4,$effectiveArpConcurrency)
    for($offset=0;$offset -lt $total;$offset+=$chunkSize){
        if(Test-Cancelled){$phase='cancelled';Write-State $true $true '';exit 0}
        $last=[Math]::Min($total-1,$offset+$chunkSize-1)
        $chunk=[string[]]@($targets[$offset..$last])
        $part=@([RftDiscoveryNative]::ArpSweep($chunk,$localIp,$effectiveArpConcurrency))
        foreach($a in $part){
            $x=Get-OrCreateResult ([string]$a.IP)
            if(-not $retryEnabled -and $x.IcmpRetryStatus -eq 'Not attempted'){$x.IcmpRetryStatus='Skipped - FAST profile'}
            $x.ArpError=[string]$a.Error
            if([string]::IsNullOrWhiteSpace([string]$a.MAC)){
                $x.ArpStatus=if([int]$a.Error -eq 0){'No MAC returned'}else{"No response / error $($a.Error)"}
                continue
            }
            $x.MAC=Format-Mac ([string]$a.MAC);$x.Arp=$true;$x.ArpStatus='Success';$x.ArpMAC=$x.MAC
            if($x.Status -ne 'Online'){$x.Status='L2 Seen';$x.Latency='No ICMP';$x.Evidence='Active ARP'}
            elseif([string]::IsNullOrWhiteSpace($x.Evidence)){$x.Evidence='ICMP + ARP'}elseif($x.Evidence -notmatch 'ARP'){$x.Evidence=$x.Evidence+' + ARP'}
        }
        $done=[Math]::Min($total,$last+1);Write-State $false $false ''
    }
    if($localIp -and $localMac -and ($targets -contains $localIp)){
        $x=Get-OrCreateResult $localIp;$x.MAC=$localMac
        if($x.Status -ne 'Online'){$x.Status='L2 Seen';$x.Latency='Local';$x.Evidence='Local adapter'}
    }
    Write-State $false $false ''

    # PASS 4: merge the Windows neighbor cache after ICMP + ARP warmed it.
    if(Test-Cancelled){$phase='cancelled';Write-State $true $true '';exit 0}
    $phase='neighbor-merge';$done=0;Write-State $false $false ''
    try {
        if(Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue){
            $targetSet=@{};foreach($ip in $targets){$targetSet[$ip]=$true}
            $neighbors=@(Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue | Where-Object {
                $_.IPAddress -and $targetSet.ContainsKey([string]$_.IPAddress) -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and $_.State -notin @('Unreachable','Incomplete')
            })
            foreach($n in $neighbors){
                $ip=[string]$n.IPAddress;$mac=Format-Mac -mac ([string]$n.LinkLayerAddress)
                if(-not $mac){continue}
                $x=Get-OrCreateResult $ip
                if(-not $x.MAC){$x.MAC=$mac}
                $x.Neighbor=$true;$x.NeighborState=[string]$n.State;$x.NeighborMAC=$mac
                if($x.Status -ne 'Online'){$x.Status='L2 Seen';$x.Latency='No ICMP';$x.Evidence='Neighbor cache'}
                elseif($x.Evidence -notmatch 'Neighbor'){$x.Evidence=$x.Evidence+' + Neighbor'}
            }
        }
    } catch { Write-WorkerLog ('Get-NetNeighbor failed: '+$_.Exception.Message) }
    $done=$total;Write-State $false $false ''

    # PASS 5: passive IPv6 Neighbor Discovery snapshot on the selected interface.
    # Never enumerate the IPv6 address space; only report entries already observed by Windows NDP.
    if(Test-Cancelled){$phase='cancelled';Write-State -complete $true -cancelled $true -errorMessage '';exit 0}
    $phase='ipv6-neighbor-snapshot';$done=0;Write-State -complete $false -cancelled $false -errorMessage ''
    try {
        $ipv6Map=@{}
        if(Get-Command -Name Get-NetNeighbor -ErrorAction SilentlyContinue){
            $neighbors6=@(Get-NetNeighbor -AddressFamily IPv6 -InterfaceIndex $interfaceIndex -ErrorAction Stop | Where-Object -FilterScript {
                $_.IPAddress -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and $_.State -notin @('Unreachable','Incomplete')
            })
            foreach($n in $neighbors6){
                $ip=[string]$n.IPAddress
                $mac=Format-Mac -mac ([string]$n.LinkLayerAddress)
                if(-not $mac){continue}
                try {
                    $parsed=[Net.IPAddress]::Parse($ip)
                    if($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6){continue}
                    if($parsed.Equals([Net.IPAddress]::IPv6Any) -or $parsed.Equals([Net.IPAddress]::IPv6Loopback) -or $parsed.IsIPv6Multicast){continue}
                    $key=$parsed.ToString().ToLowerInvariant()
                    $ipv6Map[$key]=[pscustomobject]@{
                        IP=$parsed.ToString()
                        MAC=$mac
                        State=[string]$n.State
                        Scope=$(if($parsed.IsIPv6LinkLocal){'LinkLocal'}else{'Unicast'})
                        InterfaceIndex=$interfaceIndex
                        Evidence='Windows IPv6 neighbor cache (passive NDP)'
                    }
                } catch {
                    Write-WorkerLog -message ('Ignored invalid IPv6 neighbor entry: '+$ip)
                }
            }
        }
        $ipv6Neighbors=@($ipv6Map.Values | Sort-Object -Property IP)
        $ipv6NeighborError=''
        Write-WorkerLog -message "IPv6 NDP snapshot observed=$(@($ipv6Neighbors).Count) interface=$interfaceIndex"
    } catch {
        $ipv6Neighbors=@()
        $ipv6NeighborError=$_.Exception.Message
        Write-WorkerLog -message ('IPv6 NDP snapshot failed: '+$ipv6NeighborError)
    }
    $done=@($ipv6Neighbors).Count;Write-State -complete $false -cancelled $false -errorMessage ''

    $phase='done';$done=$total;Write-State $true $false ''
    $discoveredCount=@($results.Values | Where-Object {$_.Status -ne 'Unknown'}).Count
    Write-WorkerLog "DONE Profile=$scanProfile Online=$online Seen=$seen TotalDiscovered=$discoveredCount ElapsedMs=$($workerSw.ElapsedMilliseconds)"
    exit 0
} catch {
    $msg=$_.Exception.Message
    Write-WorkerLog ('FATAL: '+($_ | Out-String))
    $phase='error';Write-State $true $false $msg
    exit 4
}