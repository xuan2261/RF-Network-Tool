param(
    [Parameter(Mandatory=$true)][string]$TargetsFile,
    [Parameter(Mandatory=$true)][string]$CacheFile,
    [string]$RunId = '',
    [string]$SessionId = '',
    [string]$ResultFile = '',
    [string]$CancelFile = '',
    [int]$DurationSec = 45,
    [Alias('Profile')][string]$DiscoveryProfile = 'BALANCED',
    [string]$Gateway = '',
    [string]$LocalIP = '',
    [string]$LogFile = '',
    [int]$ParentPid = 0,
    [long]$ParentStartTicks = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VersionFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VERSION'
if (-not (Test-Path -LiteralPath $VersionFile)) { throw "Missing VERSION: $VersionFile" }
$AppVersion = ([IO.File]::ReadAllText($VersionFile)).Trim()
if ($AppVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid VERSION: $AppVersion" }
$UserAgent = "RF-Network-Tool/$AppVersion"
if($DurationSec -lt 5){$DurationSec=5}elseif($DurationSec -gt 120){$DurationSec=120}
$DiscoveryProfile=if([string]::IsNullOrWhiteSpace($DiscoveryProfile)){'BALANCED'}else{$DiscoveryProfile.ToUpperInvariant()}
if($DiscoveryProfile -notin @('FAST','BALANCED','DEEP')){$DiscoveryProfile='BALANCED'}
if([string]::IsNullOrWhiteSpace($RunId)){$RunId=[guid]::NewGuid().ToString('N')}
$map = @{}
$evidenceMap = @{}
$targetMeta=@{}
if(-not $ResultFile){$ResultFile=$CacheFile+'.result.json'}
$script:CacheWriteFailed=$false

function Assert-DiscoveryActive {
    if(-not (Test-ParentAlive) -or ($CancelFile -and (Test-Path -LiteralPath $CancelFile))){
        throw [OperationCanceledException]::new('Discovery cancelled or parent ended')
    }
}

function Write-DiscoveryTerminal($value) {
    $tmp=$ResultFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$tmp+'.previous'
    try {
        [IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $value -Depth 5),(New-Object Text.UTF8Encoding($true)))
        # Use an explicit unique backup path: Windows PowerShell may bind $null as an empty string.
        if(Test-Path -LiteralPath $ResultFile){[IO.File]::Replace($tmp,$ResultFile,$backup)}
        else{[IO.File]::Move($tmp,$ResultFile)}
    } finally {
        foreach($path in @($tmp,$backup)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
    }
}

function Write-WorkerLog([string]$message) {
    if([string]::IsNullOrWhiteSpace($LogFile)){return}
    try{[IO.File]::AppendAllText($LogFile,"[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))] $message"+[Environment]::NewLine,[Text.Encoding]::UTF8)}catch{}
}
Write-WorkerLog "START RunId=$RunId Profile=$DiscoveryProfile Duration=${DurationSec}s Gateway=$Gateway LocalIP=$LocalIP"


function Test-ParentAlive {
    if($ParentPid -le 0 -or $ParentStartTicks -le 0){return $true}
    try{$parentProcess=Get-Process -Id $ParentPid -ErrorAction Stop;return ([long]$parentProcess.StartTime.Ticks -eq $ParentStartTicks)}catch{return $false}
}

function Normalize-Name([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return '' }
    $n = ($name -replace '[\x00-\x1F\x7F]',' ').Trim().TrimEnd('.')
    $n = [regex]::Replace($n,'\s+',' ')
    $n = $n -replace '(?i)\.local$',''
    if ($n -match '^\d{1,3}(?:\.\d{1,3}){3}$') { return '' }
    if ($n.Length -gt 253) { $n=$n.Substring(0,253) }
    return $n
}

function Get-EvidenceRank([string]$state) {
    switch -Regex ($state) {
        '^PASS$' { return 50 }
        '^INFO$' { return 40 }
        '^SKIPPED$' { return 30 }
        '^NOT OBSERVED$' { return 20 }
        '^NO RESPONSE$' { return 20 }
        '^ERROR$' { return 10 }
        default { return 0 }
    }
}

function Add-Evidence([string]$ip,[string]$source,[string]$state,[string]$value='',[string]$detail='') {
    if([string]::IsNullOrWhiteSpace($ip) -or [string]::IsNullOrWhiteSpace($source)){return}
    if(-not $evidenceMap.ContainsKey($ip)){$evidenceMap[$ip]=@()}
    $now=(Get-Date).ToString('s')
    $existing=@($evidenceMap[$ip])
    $idx=-1
    for($i=0;$i -lt $existing.Count;$i++){if([string]$existing[$i].Source -eq $source){$idx=$i;break}}
    $rec=[pscustomobject]@{Source=$source;State=$state;Value=$value;Detail=$detail;ObservedAt=$now}
    if($idx -lt 0){$evidenceMap[$ip]=@($existing + $rec);return}
    $old=$existing[$idx]
    if((Get-EvidenceRank $state) -ge (Get-EvidenceRank ([string]$old.State))){$existing[$idx]=$rec;$evidenceMap[$ip]=$existing}
}

function Has-EvidenceMatching([string]$ip,[string]$pattern) {
    if(-not $evidenceMap.ContainsKey($ip)){return $false}
    foreach($e in @($evidenceMap[$ip])){if([string]$e.Source -match $pattern -and [string]$e.State -eq 'PASS'){return $true}}
    return $false
}

function Set-Discovery([string]$ip,[string]$name,[string]$source,[int]$score) {
    $n = Normalize-Name $name
    if (-not $ip -or -not $n) { return $false }
    Add-Evidence $ip $source 'PASS' $n "Name discovered; score=$score"
    if (-not $map.ContainsKey($ip) -or $score -gt [int]$map[$ip].Score) {
        $map[$ip] = [pscustomobject]@{ IP=$ip; Name=$n; Source=$source; Score=$score; UpdatedAt=(Get-Date).ToString('s') }
        return $true
    }
    return $false
}

function Write-Cache {
    try {
        $keys=@{}
        foreach($ip in @($ips)){if($ip){$keys[[string]$ip]=$true}}
        foreach($ip in @($map.Keys)){if($ip){$keys[[string]$ip]=$true}}
        foreach($ip in @($evidenceMap.Keys)){if($ip){$keys[[string]$ip]=$true}}
        $items=@()
        foreach($ip in @($keys.Keys | Sort-Object)){
            $best=$null;if($map.ContainsKey($ip)){$best=$map[$ip]}
            $ev=@();if($evidenceMap.ContainsKey($ip)){$ev=@($evidenceMap[$ip] | Sort-Object Source)}
            $items += [pscustomobject]@{
                IP=$ip;Name=$(if($best){[string]$best.Name}else{''});Source=$(if($best){[string]$best.Source}else{'Unknown'});
                Score=$(if($best){[int]$best.Score}else{0});UpdatedAt=$(if($best){[string]$best.UpdatedAt}else{(Get-Date).ToString('s')});Evidence=$ev
            }
        }
        $payload=[ordered]@{schemaVersion=4;runId=$RunId;sessionId=$SessionId;profile=$DiscoveryProfile;updatedAt=(Get-Date).ToString('o');records=$items}
        $json = $payload | ConvertTo-Json -Depth 7
        $tmp = "$CacheFile.$PID.$([guid]::NewGuid().ToString('N')).tmp"
        $enc=New-Object System.Text.UTF8Encoding -ArgumentList $true
        try{
            [IO.File]::WriteAllText($tmp, $json, $enc)
            if(Test-Path -LiteralPath $CacheFile){try{[IO.File]::Replace($tmp,$CacheFile,$null);return}catch{}}
            Move-Item -LiteralPath $tmp -Destination $CacheFile -Force -ErrorAction Stop
        } finally {if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}}
    } catch { $script:CacheWriteFailed=$true;Write-WorkerLog ('Cache write failed: '+$_.Exception.Message) }
}

function Invoke-ProcessText([string]$file,[string]$argumentLine,[int]$timeoutMs=800) {
    $p = $null
    try {
        if(-not (Test-Path -LiteralPath $file)){return ''}
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $file
        $psi.Arguments = $argumentLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = New-Object Diagnostics.Process
        $p.StartInfo = $psi
        if (-not $p.Start()) { return '' }
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($timeoutMs)) { try { $p.Kill() } catch { };try{$p.WaitForExit(250)}catch{}; return '' }
        try{[void]$outTask.Wait(250);[void]$errTask.Wait(250)}catch{}
        $out=if($outTask.IsCompleted){$outTask.Result}else{''};$err=if($errTask.IsCompleted){$errTask.Result}else{''}
        return ($out + "`n" + $err)
    } catch { Write-WorkerLog ("Process '$file' failed: "+$_.Exception.Message); return '' }
    finally { if ($p) { try { $p.Dispose() } catch { } } }
}

function Get-SystemDnsName([string]$ip,[int]$timeoutMs=350) {
    try {
        $t = [Net.Dns]::GetHostEntryAsync($ip)
        if ($t.Wait($timeoutMs) -and $t.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
            return (Normalize-Name ([string]$t.Result.HostName))
        }
    } catch { }
    return ''
}

function Get-GatewayPtrName([string]$ip,[string]$server) {
    if (-not $server) { return '' }
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $a=[Net.IPAddress]::Parse($ip);$b=$a.GetAddressBytes();$rev="$($b[3]).$($b[2]).$($b[1]).$($b[0]).in-addr.arpa"
            $r = @(Resolve-DnsName -Name $rev -Type PTR -Server $server -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue)
            foreach ($x in $r) { if ($x.NameHost) { return (Normalize-Name ([string]$x.NameHost)) } }
        }
    } catch { }
    return ''
}

function Get-PingAName([string]$ip) {
    $out = Invoke-ProcessText "$env:SystemRoot\System32\ping.exe" "-a -n 1 -w 300 $ip" 900
    if (-not $out) { return '' }
    try {
        $m = [regex]::Match($out, '(?im)^\s*Pinging\s+([^\s\[]+)\s*\[' + [regex]::Escape($ip) + '\]')
        if ($m.Success) { return (Normalize-Name $m.Groups[1].Value) }
    } catch { }
    return ''
}

function Get-NetbiosName([string]$ip) {
    $out = Invoke-ProcessText "$env:SystemRoot\System32\nbtstat.exe" "-A $ip" 1000
    if (-not $out) { return '' }
    try {
        foreach ($line in ($out -split "`r?`n")) {
            if ($line -match '^\s*([^<]{1,15})\s+<00>\s+UNIQUE') {
                $n = Normalize-Name $matches[1]
                if ($n -and $n -notmatch '^(WORKGROUP|MSHOME)$') { return $n }
            }
        }
    } catch { }
    return ''
}

function Read-U16BE([byte[]]$b,[int]$o) {
    if (-not $b -or $o -lt 0 -or ($o+1) -ge $b.Length) { return 0 }
    return (([int]$b[$o] -shl 8) -bor [int]$b[$o+1])
}

function Read-DnsName([byte[]]$b,[ref]$offset,[int]$depth=0) {
    if (-not $b -or $depth -gt 10) { return '' }
    $pos=[int]$offset.Value; $labels=New-Object Collections.Generic.List[string]; $next=$pos; $jumped=$false
    while ($pos -lt $b.Length) {
        $len=[int]$b[$pos]
        if ($len -eq 0) { $pos++; if(-not $jumped){$next=$pos}; break }
        if (($len -band 0xC0) -eq 0xC0) {
            if (($pos+1) -ge $b.Length) { break }
            $ptr=(($len -band 0x3F) -shl 8) -bor [int]$b[$pos+1]
            if(-not $jumped){$next=$pos+2}
            $tmp=$ptr; $suffix=Read-DnsName $b ([ref]$tmp) ($depth+1)
            if($suffix){[void]$labels.Add($suffix)}
            $jumped=$true; break
        }
        if ($len -lt 1 -or $len -gt 63 -or ($pos+1+$len) -gt $b.Length) { break }
        [void]$labels.Add([Text.Encoding]::UTF8.GetString($b,$pos+1,$len)); $pos += 1+$len
        if(-not $jumped){$next=$pos}
    }
    $offset.Value=$next
    return ([string]::Join('.', $labels.ToArray())).Trim('.')
}

function New-DnsQuery([string]$name,[int]$type=12) {
    $ms=New-Object IO.MemoryStream; $bw=New-Object IO.BinaryWriter -ArgumentList $ms
    try {
        $bw.Write([byte[]](0,0,0,0,0,1,0,0,0,0,0,0))
        foreach($label in ($name.TrimEnd('.') -split '\.')) {
            $lb=[Text.Encoding]::UTF8.GetBytes($label); if($lb.Length -gt 63){return $null}; $bw.Write([byte]$lb.Length); $bw.Write($lb)
        }
        $bw.Write([byte]0); $bw.Write([byte](($type -shr 8) -band 0xFF)); $bw.Write([byte]($type -band 0xFF))
        $bw.Write([byte]0x80); $bw.Write([byte]0x01) # QU bit + IN class: request unicast response
        return $ms.ToArray()
    } finally { $bw.Close(); $ms.Close() }
}

function Parse-MdnsPacket([byte[]]$data,[string]$sourceIp) {
    $changed=$false
    try {
        if(-not $data -or $data.Length -lt 12){return $false}
        $qd=Read-U16BE $data 4; $an=Read-U16BE $data 6; $ns=Read-U16BE $data 8; $ar=Read-U16BE $data 10; $off=12
        for($i=0;$i -lt $qd;$i++){[void](Read-DnsName $data ([ref]$off));$off+=4;if($off -gt $data.Length){return $false}}
        $count=$an+$ns+$ar
        for($i=0;$i -lt $count -and ($off+10) -le $data.Length;$i++){
            $owner=Read-DnsName $data ([ref]$off); if(($off+10) -gt $data.Length){break}
            $type=Read-U16BE $data $off;$off+=2; $off+=2; $off+=4; $rdlen=Read-U16BE $data $off;$off+=2; $rstart=$off
            if(($rstart+$rdlen) -gt $data.Length){break}
            if($type -eq 1 -and $rdlen -eq 4){
                $ipb=New-Object byte[] 4; [Array]::Copy($data,$rstart,$ipb,0,4); $a=(New-Object Net.IPAddress -ArgumentList (,$ipb)).ToString()
                if(($ips -contains $a) -and $owner -and $owner -notmatch '^_'){ if(Set-Discovery $a $owner 'mDNS host' 96){$changed=$true} }
            } elseif($type -eq 12) {
                $to=$rstart; $value=Read-DnsName $data ([ref]$to)
                if($owner -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)\.in-addr\.arpa\.?$'){
                    $ip="$($matches[4]).$($matches[3]).$($matches[2]).$($matches[1])"
                    if(($ips -contains $ip) -and (Set-Discovery $ip $value 'mDNS reverse PTR' 95)){$changed=$true}
                } elseif($sourceIp -and $value -and $value -notmatch '^_') {
                    $cand=$value -replace '(?i)\._[^.]+\._(?:tcp|udp)\.local\.?$',''
                    if(Set-Discovery $sourceIp $cand 'mDNS/DNS-SD' 78){$changed=$true}
                }
            } elseif($type -eq 33 -and $rdlen -ge 7) {
                $to=$rstart+6; $target=Read-DnsName $data ([ref]$to)
                if(($ips -contains $sourceIp) -and $target -and $target -notmatch '^_'){if(Set-Discovery $sourceIp $target 'mDNS SRV' 90){$changed=$true}}
            }
            $off=$rstart+$rdlen
        }
    } catch { }
    return $changed
}

function New-MulticastListener([int]$port,[string]$group,[string]$localIp='') {
    $u=$null
    try {
        $u=New-Object Net.Sockets.UdpClient -ArgumentList ([Net.Sockets.AddressFamily]::InterNetwork)
        $u.ExclusiveAddressUse=$false
        $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket,[Net.Sockets.SocketOptionName]::ReuseAddress,$true)
        $u.Client.Bind((New-Object Net.IPEndPoint -ArgumentList ([Net.IPAddress]::Any,$port)))
        if($localIp){
            try{$u.JoinMulticastGroup([Net.IPAddress]::Parse($group),[Net.IPAddress]::Parse($localIp))}catch{$u.JoinMulticastGroup([Net.IPAddress]::Parse($group))}
        } else {$u.JoinMulticastGroup([Net.IPAddress]::Parse($group))}
        return $u
    } catch { if($u){try{$u.Close()}catch{}}; return $null }
}

function Parse-LlmnrPacket([byte[]]$data,[string]$sourceIp) {
    $changed=$false
    try {
        if(-not $data -or $data.Length -lt 12){return $false}
        $qd=Read-U16BE $data 4;$an=Read-U16BE $data 6;$ns=Read-U16BE $data 8;$ar=Read-U16BE $data 10;$off=12
        for($i=0;$i -lt $qd;$i++){[void](Read-DnsName $data ([ref]$off));$off+=4;if($off -gt $data.Length){return $false}}
        $count=$an+$ns+$ar
        for($i=0;$i -lt $count -and ($off+10) -le $data.Length;$i++){
            $owner=Read-DnsName $data ([ref]$off);if(($off+10) -gt $data.Length){break}
            $type=Read-U16BE $data $off;$off+=2;$off+=2;$off+=4;$rdlen=Read-U16BE $data $off;$off+=2;$rstart=$off
            if(($rstart+$rdlen) -gt $data.Length){break}
            if($type -eq 1 -and $rdlen -eq 4 -and $owner){
                $ipb=New-Object byte[] 4;[Array]::Copy($data,$rstart,$ipb,0,4);$a=(New-Object Net.IPAddress -ArgumentList (,$ipb)).ToString()
                if(($ips -contains $a) -and (Set-Discovery $a $owner 'LLMNR passive' 89)){$changed=$true}
            }
            $off=$rstart+$rdlen
        }
    } catch { }
    return $changed
}

function Get-UpnpFriendlyName([string]$location,[string]$expectedIp) {
    if(-not $location){return ''}
    try {
        $u=[Uri]$location; if($u.Scheme -notin @('http','https')){return ''}; if($expectedIp -and $u.Host -ne $expectedIp){return ''}
        $req=[Net.HttpWebRequest]::Create($u);$req.Timeout=700;$req.ReadWriteTimeout=700;$req.AllowAutoRedirect=$false;$req.Proxy=$null;$req.UserAgent=$UserAgent
        $resp=$null;$sr=$null
        try{$resp=$req.GetResponse();$sr=New-Object IO.StreamReader -ArgumentList (,$resp.GetResponseStream());$buf=New-Object char[] 4096;$sb=New-Object Text.StringBuilder;while($sb.Length -lt 262144){$want=[Math]::Min($buf.Length,262144-$sb.Length);$n=$sr.Read($buf,0,$want);if($n -le 0){break};[void]$sb.Append($buf,0,$n)};$txt=$sb.ToString()}finally{if($sr){try{$sr.Dispose()}catch{}};if($resp){try{$resp.Close()}catch{}}}
        $m=[regex]::Match($txt,'(?is)<friendlyName>\s*([^<]+)\s*</friendlyName>');if($m.Success){return (Normalize-Name $m.Groups[1].Value)}
    } catch { }
    return ''
}

$runClock=[Diagnostics.Stopwatch]::StartNew();$sw=$null
$terminalStatus='ERROR';$terminalError='';$exitCode=1;$ips=@()
try {
    Assert-DiscoveryActive
$targets=@()
$targets=@(Get-Content -LiteralPath $TargetsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
$ips=@()
foreach($t in $targets){
    $ip=if($t.IP){[string]$t.IP}else{[string]$t};$addr=$null
    if([Net.IPAddress]::TryParse($ip,[ref]$addr) -and $addr.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){
        $norm=$addr.ToString();$ips += $norm
        if($t -and $t.PSObject -and $t.PSObject.Properties['IP']){$targetMeta[$norm]=$t}
    }
}
$ips=@($ips | Select-Object -Unique)
if($ips.Count -eq 0){throw 'No valid IPv4 targets'}
Write-WorkerLog "Targets=$($ips.Count) Profile=$DiscoveryProfile"

# Quick per-target probes run in this helper process, never on the WinForms UI thread.
foreach($ip in $ips){
        Assert-DiscoveryActive
    Add-Evidence $ip 'Discovery profile' 'INFO' $DiscoveryProfile "Profile=$DiscoveryProfile; observation window=${DurationSec}s"
    if($targetMeta.ContainsKey($ip)){
        $meta=$targetMeta[$ip];$existing=Normalize-Name ([string]$meta.CurrentName);$src=[string]$meta.CurrentSource
        if($existing -and $src -notin @('Unknown','PING alias','History')){Add-Evidence $ip 'Existing name' 'INFO' $existing "Existing source=$src"}
    }

    $dnsTimeout=if($DiscoveryProfile -eq 'DEEP'){650}elseif($DiscoveryProfile -eq 'FAST'){250}else{350}
    $n=Get-SystemDnsName $ip $dnsTimeout
    if($n){[void](Set-Discovery $ip $n 'System DNS' 100)}else{Add-Evidence $ip 'System DNS' 'NO RESPONSE' '' "No hostname returned within ${dnsTimeout}ms"}

    if($DiscoveryProfile -eq 'FAST'){
        Add-Evidence $ip 'Gateway DNS PTR' 'SKIPPED' '' 'FAST profile skips gateway PTR per-target probe'
        Add-Evidence $ip 'Ping -a reverse' 'SKIPPED' '' 'FAST profile skips ping -a per-target probe'
        Add-Evidence $ip 'NetBIOS' 'SKIPPED' '' 'FAST profile skips NetBIOS per-target probe'
    } else {
        if(-not $map.ContainsKey($ip) -and $Gateway){
            $n=Get-GatewayPtrName $ip $Gateway
            if($n){[void](Set-Discovery $ip $n 'Gateway DNS PTR' 94)}else{Add-Evidence $ip 'Gateway DNS PTR' 'NO RESPONSE' '' "No PTR name from gateway $Gateway"}
        } elseif(-not $Gateway){Add-Evidence $ip 'Gateway DNS PTR' 'SKIPPED' '' 'No gateway configured'}
        else{Add-Evidence $ip 'Gateway DNS PTR' 'SKIPPED' '' 'A stronger name source already succeeded'}

        if(-not $map.ContainsKey($ip)){
            $n=Get-PingAName $ip
            if($n){[void](Set-Discovery $ip $n 'Ping -a reverse' 88)}else{Add-Evidence $ip 'Ping -a reverse' 'NO RESPONSE' '' 'No reverse name returned by ping -a'}
        } else{Add-Evidence $ip 'Ping -a reverse' 'SKIPPED' '' 'A stronger name source already succeeded'}

        if(-not $map.ContainsKey($ip)){
            $n=Get-NetbiosName $ip
            if($n){[void](Set-Discovery $ip $n 'NetBIOS' 86)}else{Add-Evidence $ip 'NetBIOS' 'NO RESPONSE' '' 'No NetBIOS <00> UNIQUE name returned'}
        } else{Add-Evidence $ip 'NetBIOS' 'SKIPPED' '' 'A stronger name source already succeeded'}
    }
    Write-Cache
}

$mdns=$null;$ssdp=$null;$mdnsPassive=$null;$ssdpPassive=$null;$llmnrPassive=$null
try {
    if($LocalIP){
        try{
            $localAddr=[Net.IPAddress]::Parse($LocalIP)
            $localEp1=New-Object Net.IPEndPoint -ArgumentList ($localAddr,0)
            $localEp2=New-Object Net.IPEndPoint -ArgumentList ($localAddr,0)
            $mdns=New-Object Net.Sockets.UdpClient -ArgumentList (,$localEp1)
            $ssdp=New-Object Net.Sockets.UdpClient -ArgumentList (,$localEp2)
        }catch{}
    }
    if(-not $mdns){$mdns=New-Object Net.Sockets.UdpClient}
    if(-not $ssdp){$ssdp=New-Object Net.Sockets.UdpClient}
    $mdns.Client.ReceiveTimeout=1
    $ssdp.Client.ReceiveTimeout=1
    $mdnsPassive=New-MulticastListener 5353 '224.0.0.251' $LocalIP
    $ssdpPassive=New-MulticastListener 1900 '239.255.255.250' $LocalIP
    $llmnrPassive=New-MulticastListener 5355 '224.0.0.252' $LocalIP
    $sw=[Diagnostics.Stopwatch]::StartNew();$nextQuery=-1;$nextWrite=-1
    $serviceNames=if($DiscoveryProfile -eq 'FAST'){
        @('_workstation._tcp.local','_device-info._tcp.local','_http._tcp.local')
    } else {
        @('_services._dns-sd._udp.local','_workstation._tcp.local','_device-info._tcp.local','_googlecast._tcp.local','_airplay._tcp.local','_companion-link._tcp.local','_ipp._tcp.local','_printer._tcp.local','_http._tcp.local','_https._tcp.local')
    }
    while($sw.Elapsed.TotalSeconds -lt $DurationSec){
        Assert-DiscoveryActive
        if($sw.Elapsed.TotalSeconds -ge $nextQuery){
            foreach($qn in $serviceNames){$q=New-DnsQuery $qn 12;if($q){try{[void]$mdns.Send($q,$q.Length,'224.0.0.251',5353)}catch{}}}
            foreach($ip in $ips){
        Assert-DiscoveryActive
                try{$a=[Net.IPAddress]::Parse($ip);$b=$a.GetAddressBytes();$rev="$($b[3]).$($b[2]).$($b[1]).$($b[0]).in-addr.arpa";$q=New-DnsQuery $rev 12;if($q){[void]$mdns.Send($q,$q.Length,'224.0.0.251',5353)}}catch{}
            }
            $msg="M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 1`r`nST: ssdp:all`r`n`r`n"
            $bb=[Text.Encoding]::ASCII.GetBytes($msg);try{[void]$ssdp.Send($bb,$bb.Length,'239.255.255.250',1900)}catch{}
            $nextQuery=$sw.Elapsed.TotalSeconds+5
        }
        $changed=$false
        for($k=0;$k -lt 24 -and $mdns.Available -gt 0;$k++){
            $ep=New-Object Net.IPEndPoint -ArgumentList ([Net.IPAddress]::Any,0);try{$data=$mdns.Receive([ref]$ep);if(Parse-MdnsPacket $data $ep.Address.ToString()){$changed=$true}}catch{}
        }
        if($mdnsPassive){
            for($k=0;$k -lt 24 -and $mdnsPassive.Available -gt 0;$k++){
                $ep=New-Object Net.IPEndPoint -ArgumentList ([Net.IPAddress]::Any,0);try{$data=$mdnsPassive.Receive([ref]$ep);if(Parse-MdnsPacket $data $ep.Address.ToString()){$changed=$true}}catch{}
            }
        }
        if($llmnrPassive){
            for($k=0;$k -lt 16 -and $llmnrPassive.Available -gt 0;$k++){
                $ep=New-Object Net.IPEndPoint -ArgumentList ([Net.IPAddress]::Any,0);try{$data=$llmnrPassive.Receive([ref]$ep);if(Parse-LlmnrPacket $data $ep.Address.ToString()){$changed=$true}}catch{}
            }
        }
        for($k=0;$k -lt 16 -and $ssdp.Available -gt 0;$k++){
            $ep=New-Object Net.IPEndPoint -ArgumentList ([Net.IPAddress]::Any,0);try{$data=$ssdp.Receive([ref]$ep)}catch{continue}
            $src=$ep.Address.ToString();if($ips -notcontains $src){continue};$txt=[Text.Encoding]::UTF8.GetString($data);$loc='';$server=''
            foreach($line in ($txt -split "`r?`n")){
                if($line -match '^\s*LOCATION:\s*(.+)$'){$loc=$matches[1].Trim()}
                elseif($line -match '^\s*SERVER:\s*(.+)$'){$server=$matches[1].Trim()}
            }
            if($ips -contains $src){Add-Evidence $src 'SSDP / UPnP' 'PASS' $(if($server){$server}else{$loc}) $(if($loc){"LOCATION=$loc"}else{'SSDP response observed'})}
            if($loc -and (-not $map.ContainsKey($src) -or [int]$map[$src].Score -lt 90)){$n=Get-UpnpFriendlyName $loc $src;if($n){if(Set-Discovery $src $n 'UPnP/SSDP' 92){$changed=$true}}}
        }
        if($ssdpPassive){
            for($k=0;$k -lt 16 -and $ssdpPassive.Available -gt 0;$k++){
                $ep=New-Object Net.IPEndPoint -ArgumentList ([Net.IPAddress]::Any,0);try{$data=$ssdpPassive.Receive([ref]$ep)}catch{continue}
                $src=$ep.Address.ToString();if($ips -notcontains $src){continue};$txt=[Text.Encoding]::UTF8.GetString($data);$loc='';$server=''
                foreach($line in ($txt -split "`r?`n")){
                    if($line -match '^\s*LOCATION:\s*(.+)$'){$loc=$matches[1].Trim()}
                    elseif($line -match '^\s*SERVER:\s*(.+)$'){$server=$matches[1].Trim()}
                }
                if($ips -contains $src){Add-Evidence $src 'SSDP / UPnP' 'PASS' $(if($server){$server}else{$loc}) $(if($loc){"LOCATION=$loc"}else{'SSDP announcement observed'})}
                if($loc -and (-not $map.ContainsKey($src) -or [int]$map[$src].Score -lt 90)){$n=Get-UpnpFriendlyName $loc $src;if($n){if(Set-Discovery $src $n 'UPnP/SSDP passive' 93){$changed=$true}}}
            }
        }
        if($changed -or $sw.Elapsed.TotalSeconds -ge $nextWrite){Write-Cache;$nextWrite=$sw.Elapsed.TotalSeconds+2}
        Start-Sleep -Milliseconds 100
    }
} finally {
    foreach($ip in $ips){
        if(-not (Has-EvidenceMatching $ip '(?i)^mDNS|DNS-SD')){Add-Evidence $ip 'mDNS / DNS-SD' 'NOT OBSERVED' '' 'No mDNS/DNS-SD response observed during discovery window'}
        if(-not (Has-EvidenceMatching $ip '(?i)^LLMNR')){Add-Evidence $ip 'LLMNR' 'NOT OBSERVED' '' 'No LLMNR response observed during discovery window'}
        if(-not (Has-EvidenceMatching $ip '(?i)SSDP|UPnP')){Add-Evidence $ip 'SSDP / UPnP' 'NOT OBSERVED' '' 'No SSDP/UPnP response observed during discovery window'}
    }
    if($mdns){try{$mdns.Close()}catch{}};if($ssdp){try{$ssdp.Close()}catch{}};if($mdnsPassive){try{$mdnsPassive.Close()}catch{}};if($ssdpPassive){try{$ssdpPassive.Close()}catch{}};if($llmnrPassive){try{$llmnrPassive.Close()}catch{}};Write-Cache;Write-WorkerLog "END RunId=$RunId Profile=$DiscoveryProfile Names=$($map.Count)"
}
    Assert-DiscoveryActive
    if($script:CacheWriteFailed){throw 'One or more discovery cache writes failed'}
    if(-not $sw -or $sw.Elapsed.TotalSeconds -lt $DurationSec){throw 'Observation window did not complete'}
    $terminalStatus='SUCCESS';$exitCode=0
} catch [OperationCanceledException] {
    $terminalStatus='CANCELLED';$terminalError=$_.Exception.Message;$exitCode=3
} catch {
    $terminalStatus='ERROR';$terminalError=$_.Exception.Message;$exitCode=1
    Write-WorkerLog ('ERROR: '+$terminalError)
} finally {
    $windowMs=if($sw){$sw.ElapsedMilliseconds}else{0}
    $terminal=[ordered]@{schemaVersion=1;sessionId=$SessionId;runId=$RunId;status=$terminalStatus;
        completedWindow=($terminalStatus -eq 'SUCCESS');durationSec=$DurationSec;windowElapsedMs=$windowMs;
        totalElapsedMs=$runClock.ElapsedMilliseconds;names=$map.Count;error=$terminalError}
    try {Write-DiscoveryTerminal $terminal}
    catch {$exitCode=1;Write-WorkerLog ('Terminal write failed: '+$_.Exception.Message)}
}
exit $exitCode
