param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('OUI_BUILD_CACHE','OUI_UPDATE','DEEP')]
    [string]$Mode,
    [Parameter(Mandatory=$true)][string]$ConfigFile,
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [Parameter(Mandatory=$true)][string]$SessionId,
    [Parameter(Mandatory=$true)][string]$RunId,
    [Parameter(Mandatory=$true)][int]$ParentPid,
    [Parameter(Mandatory=$true)][long]$ParentStartTicks,
    [Parameter(Mandatory=$true)][string]$HeartbeatFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VersionFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VERSION'
if (-not (Test-Path -LiteralPath $VersionFile)) { throw "Missing VERSION: $VersionFile" }
$AppVersion = ([IO.File]::ReadAllText($VersionFile)).Trim()
if ($AppVersion -notmatch '^\d+\.\d+\.\d+
function Write-TextAtomic([string]$Path,[string]$Text,[System.Text.Encoding]$Encoding=$null) {
    if ($null -eq $Encoding) { $Encoding = New-Object System.Text.UTF8Encoding($true) }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp,$Text,$Encoding)
        if (Test-Path -LiteralPath $Path) {
            try { [IO.File]::Replace($tmp,$Path,$null); return } catch { }
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-JsonAtomic([string]$Path,$Value,[int]$Depth=10) {
    Write-TextAtomic $Path (ConvertTo-Json -InputObject $Value -Depth $Depth)
}

function Test-ParentAlive {
    try {
        $p = Get-Process -Id $ParentPid -ErrorAction Stop
        return ([long]$p.StartTime.Ticks -eq $ParentStartTicks)
    } catch { return $false }
}

function Assert-ParentAlive {
    if (-not (Test-ParentAlive)) { throw 'Parent process is no longer the expected process instance.' }
}

function Write-Heartbeat([string]$Phase) {
    try {
        Write-JsonAtomic $HeartbeatFile ([ordered]@{
            schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;pid=$PID;
            phase=$Phase;heartbeatAt=(Get-Date).ToString('o')
        }) 5
    } catch { }
}

function Download-FileSafe([string]$Url,[string]$Destination,[int]$TimeoutMs=12000,[int64]$MaxBytes=33554432) {
    $resp=$null;$stream=$null;$fs=$null
    $tmp="$Destination.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $uri=[Uri]$Url
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'standards-oui.ieee.org') { throw 'OUI source must be standards-oui.ieee.org over HTTPS.' }
        $req=[Net.HttpWebRequest]::Create($uri)
        $req.Method='GET';$req.Timeout=$TimeoutMs;$req.ReadWriteTimeout=$TimeoutMs
        $req.AllowAutoRedirect=$true;$req.MaximumAutomaticRedirections=3;$req.Proxy=$null
        $req.UserAgent=$UserAgent
        $resp=$req.GetResponse()
        if ($resp.ResponseUri.Scheme -ne 'https' -or $resp.ResponseUri.Host -ne 'standards-oui.ieee.org') { throw "Unexpected IEEE redirect: $($resp.ResponseUri)" }
        if ($resp.ContentLength -gt $MaxBytes) { throw "OUI file exceeds $MaxBytes bytes." }
        $stream=$resp.GetResponseStream()
        $fs=[IO.File]::Open($tmp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buf=New-Object byte[] 65536;$total=[int64]0
        while (($n=$stream.Read($buf,0,$buf.Length)) -gt 0) {
            $total += $n
            if ($total -gt $MaxBytes) { throw "OUI file exceeds $MaxBytes bytes." }
            $fs.Write($buf,0,$n)
        }
        $fs.Flush();$fs.Dispose();$fs=$null
        Move-Item -LiteralPath $tmp -Destination $Destination -Force -ErrorAction Stop
    } finally {
        if ($fs) { try{$fs.Dispose()}catch{} }
        if ($stream) { try{$stream.Dispose()}catch{} }
        if ($resp) { try{$resp.Close()}catch{} }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Build-OuiCache([string]$OuiDir,[string]$CacheFile) {
    $specs=@(
        [pscustomobject]@{File='oui.csv';Len=6},
        [pscustomobject]@{File='mam.csv';Len=7},
        [pscustomobject]@{File='oui36.csv';Len=9}
    )
    $tmp="$CacheFile.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $writer=$null;$count=0
    try {
        $cacheDir=Split-Path -Parent $CacheFile
        if ($cacheDir -and -not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
        $writer=New-Object IO.StreamWriter($tmp,$false,(New-Object Text.UTF8Encoding($false)))
        foreach($spec in $specs) {
            Assert-ParentAlive
            Write-Heartbeat ("Parse-"+$spec.File)
            $path=Join-Path $OuiDir $spec.File
            if (-not (Test-Path -LiteralPath $path)) { continue }
            foreach($row in (Import-Csv -LiteralPath $path)) {
                $key=([string]$row.Assignment -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
                $org=[string]$row.'Organization Name'
                if (-not $key -or -not $org) { continue }
                $org=[regex]::Replace($org,'[\t\r\n]+',' ').Trim()
                $writer.WriteLine("$($spec.Len)`t$key`t$org")
                $count++
            }
        }
        $writer.Flush();$writer.Dispose();$writer=$null
        if (Test-Path -LiteralPath $CacheFile) {
            try { [IO.File]::Replace($tmp,$CacheFile,$null); return $count } catch { }
        }
        Move-Item -LiteralPath $tmp -Destination $CacheFile -Force -ErrorAction Stop
        return $count
    } finally {
        if ($writer) { try{$writer.Dispose()}catch{} }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-PingStatistics([string]$Ip,[int]$Count=4,[int]$Timeout=650) {
    $times=@();$ttl=$null;$ok=0
    for($i=0;$i -lt $Count;$i++) {
        Assert-ParentAlive
        $ping=New-Object Net.NetworkInformation.Ping
        try {
            $task=$ping.SendPingAsync($Ip,$Timeout)
            if ($task.Wait($Timeout+1000) -and -not $task.IsFaulted) {
                $reply=$task.Result
                if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                    $ok++;$times += [int]$reply.RoundtripTime
                    if ($reply.Options) { $ttl=$reply.Options.Ttl }
                }
            }
        } catch { } finally { try{$ping.Dispose()}catch{} }
        Write-Heartbeat 'Deep-Ping'
    }
    $loss=[Math]::Round((($Count-$ok)*100.0/$Count),0)
    if ($times.Count) {
        $m=$times|Measure-Object -Minimum -Maximum -Average
        $min=$m.Minimum;$max=$m.Maximum;$avg=[Math]::Round($m.Average,1)
    } else { $min='-';$max='-';$avg='-' }
    return [pscustomobject]@{Sent=$Count;Received=$ok;LossPercent=$loss;Min=$min;Avg=$avg;Max=$max;TTL=$(if($ttl){$ttl}else{'-'})}
}

function Test-Tcp([string]$Ip,[int]$Port,[int]$Timeout=220) {
    $client=New-Object Net.Sockets.TcpClient;$ar=$null
    try {
        $ar=$client.BeginConnect($Ip,$Port,$null,$null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Timeout,$false)) { return [pscustomobject]@{State='Filtered / Timeout';Detail="No response within ${Timeout} ms"} }
        try {
            $client.EndConnect($ar)
            if ($client.Connected) { return [pscustomobject]@{State='Open';Detail='TCP connection established'} }
        } catch { return [pscustomobject]@{State='Closed / Refused';Detail=$_.Exception.Message} }
        return [pscustomobject]@{State='Closed / Refused';Detail='Connection not established'}
    } catch { return [pscustomobject]@{State='Closed / Refused';Detail=$_.Exception.Message} }
    finally {
        if ($ar -and $ar.AsyncWaitHandle) { try{$ar.AsyncWaitHandle.Close()}catch{} }
        try{$client.Close()}catch{}
    }
}

function Test-CommonPorts([string]$Ip,[int]$Timeout=220) {
    $ports=[ordered]@{21='FTP';22='SSH';23='Telnet';53='DNS';80='HTTP';443='HTTPS';445='SMB';554='RTSP';631='IPP';1883='MQTT';3389='RDP';5900='VNC';8000='HTTP/API';8080='HTTP-alt';8443='HTTPS-alt';8883='MQTT/TLS';9100='Printer/JetDirect'}
    $out=New-Object Collections.Generic.List[object]
    foreach($portKey in $ports.Keys) {
        Assert-ParentAlive
        $port=[int]$portKey;$r=Test-Tcp $Ip $port $Timeout
        [void]$out.Add([pscustomobject]@{Port=$port;Service=$ports[$portKey];State=$r.State;Detail=$r.Detail})
        Write-Heartbeat 'Deep-Ports'
    }
    return $out.ToArray()
}

function Read-ResponseLimited($Response,[int]$MaxChars=262144) {
    $reader=$null
    try {
        $reader=New-Object IO.StreamReader($Response.GetResponseStream())
        $buf=New-Object char[] 4096;$sb=New-Object Text.StringBuilder
        while($sb.Length -lt $MaxChars) {
            $want=[Math]::Min($buf.Length,$MaxChars-$sb.Length);$n=$reader.Read($buf,0,$want)
            if ($n -le 0) { break }
            [void]$sb.Append($buf,0,$n)
        }
        return $sb.ToString()
    } finally { if ($reader) { try{$reader.Dispose()}catch{} } }
}

function Get-Http([string]$Ip,[int]$Port,[int]$Timeout=850) {
    $resp=$null
    try {
        $uri="http://$Ip" + $(if($Port -ne 80){":$Port"}else{''}) + '/'
        $req=[Net.HttpWebRequest]::Create($uri);$req.Method='GET';$req.Timeout=$Timeout;$req.ReadWriteTimeout=$Timeout
        $req.AllowAutoRedirect=$false;$req.Proxy=$null;$req.UserAgent=$UserAgent
        $resp=$req.GetResponse();$body=Read-ResponseLimited $resp 262144;$title=''
        if ($body -match '(?is)<title[^>]*>\s*(.*?)\s*</title>') {
            $title=([regex]::Replace($matches[1],'<[^>]+>','')).Trim();if($title.Length -gt 160){$title=$title.Substring(0,160)}
        }
        return [pscustomobject]@{URL=$uri;Status=[int]$resp.StatusCode;Server=[string]$resp.Headers['Server'];PoweredBy=[string]$resp.Headers['X-Powered-By'];Title=$title}
    } catch { return $null }
    finally { if($resp){try{$resp.Close()}catch{}} }
}

function Get-Ssdp([string]$Ip,[int]$WindowMs=1050) {
    $result=[ordered]@{Server='';ST='';USN='';Location='';CacheControl=''};$udp=$null
    try {
        $udp=New-Object Net.Sockets.UdpClient;$udp.Client.ReceiveTimeout=220
        $msg="M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 1`r`nST: ssdp:all`r`n`r`n"
        $bytes=[Text.Encoding]::ASCII.GetBytes($msg);[void]$udp.Send($bytes,$bytes.Length,'239.255.255.250',1900)
        $sw=[Diagnostics.Stopwatch]::StartNew()
        while($sw.ElapsedMilliseconds -lt $WindowMs) {
            Assert-ParentAlive
            $ep=New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
            try{$data=$udp.Receive([ref]$ep)}catch{continue}
            if($ep.Address.ToString() -ne $Ip){continue}
            $txt=[Text.Encoding]::UTF8.GetString($data)
            foreach($line in ($txt -split "`r?`n")) {
                if($line -match '^\s*([^:]+):\s*(.*)$') {
                    $k=$matches[1].Trim().ToUpperInvariant();$v=$matches[2].Trim()
                    if($k -eq 'SERVER' -and -not $result.Server){$result.Server=$v}
                    elseif($k -eq 'ST' -and -not $result.ST){$result.ST=$v}
                    elseif($k -eq 'USN' -and -not $result.USN){$result.USN=$v}
                    elseif($k -eq 'LOCATION' -and -not $result.Location){$result.Location=$v}
                    elseif($k -eq 'CACHE-CONTROL' -and -not $result.CacheControl){$result.CacheControl=$v}
                }
            }
            if($result.Location){break}
        }
    } catch { }
    finally { if($udp){try{$udp.Close()}catch{}} }
    return [pscustomobject]$result
}

function ConvertFrom-SafeXml([string]$Text) {
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    $sr=$null;$xr=$null
    try {
        $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=1048576
        $sr=New-Object IO.StringReader($Text);$xr=[Xml.XmlReader]::Create($sr,$settings)
        $doc=New-Object Xml.XmlDocument;$doc.XmlResolver=$null;$doc.Load($xr);return $doc
    } finally { if($xr){try{$xr.Dispose()}catch{}};if($sr){try{$sr.Dispose()}catch{}} }
}

function Get-Upnp([string]$Location,[string]$Ip,[int]$Timeout=900) {
    if([string]::IsNullOrWhiteSpace($Location)){return $null};$resp=$null
    try {
        $uri=[Uri]$Location
        if($uri.Scheme -notin @('http','https') -or $uri.Host -ne $Ip){return $null}
        $req=[Net.HttpWebRequest]::Create($uri);$req.Method='GET';$req.Timeout=$Timeout;$req.ReadWriteTimeout=$Timeout;$req.AllowAutoRedirect=$false;$req.Proxy=$null;$req.UserAgent=$UserAgent
        $resp=$req.GetResponse();$xml=ConvertFrom-SafeXml (Read-ResponseLimited $resp 524288);if(-not $xml){return $null}
        function Get-NodeText([string]$Name){$node=$xml.SelectSingleNode("//*[local-name()='device']/*[local-name()='$Name']");if($node){return [string]$node.InnerText}else{return ''}}
        return [pscustomobject]@{FriendlyName=(Get-NodeText 'friendlyName');Manufacturer=(Get-NodeText 'manufacturer');ModelName=(Get-NodeText 'modelName');ModelNumber=(Get-NodeText 'modelNumber');SerialNumber=(Get-NodeText 'serialNumber');DeviceType=(Get-NodeText 'deviceType');ManufacturerURL=(Get-NodeText 'manufacturerURL');ModelURL=(Get-NodeText 'modelURL')}
    } catch { return $null }
    finally { if($resp){try{$resp.Close()}catch{}} }
}

function Invoke-ProcessText([string]$File,[string]$Arguments,[int]$Timeout=1200) {
    $p=$null
    try {
        $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$File;$psi.Arguments=$Arguments;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;if(-not $p.Start()){return ''}
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit($Timeout)){try{$p.Kill()}catch{};return ''}
        try{[void]$outTask.Wait(250);[void]$errTask.Wait(250)}catch{}
        return $(if($outTask.IsCompleted){$outTask.Result}else{''})
    } catch { return '' }
    finally { if($p){try{$p.Dispose()}catch{}} }
}

function Get-Netbios([string]$Ip) {
    $exe=Join-Path $env:SystemRoot 'System32\nbtstat.exe';$out=Invoke-ProcessText $exe "-A $Ip" 1200
    if(-not $out){return ''};return (@($out -split "`r?`n" | Where-Object {$_ -match '<[0-9A-Fa-f]{2}>'}) -join "`r`n").Trim()
}

function Get-Neighbor([string]$Ip,[int]$InterfaceIndex) {
    try {
        if(Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue){
            $n=Get-NetNeighbor -AddressFamily IPv4 -IPAddress $Ip -ErrorAction SilentlyContinue | Where-Object {$InterfaceIndex -eq 0 -or $_.InterfaceIndex -eq $InterfaceIndex} | Select-Object -First 1
            if($n){return [string]$n.State}
        }
    } catch { }
    return 'Unknown'
}

function Get-MacInfo([string]$Mac) {
    $clean=if($Mac){($Mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()}else{''}
    if($clean.Length -lt 12){return [pscustomobject]@{Scope='Unknown';Traffic='Unknown'}}
    try {
        $first=[Convert]::ToInt32($clean.Substring(0,2),16)
        return [pscustomobject]@{Scope=$(if(($first -band 2)-ne 0){'Locally administered / randomized'}else{'Universally administered'});Traffic=$(if(($first -band 1)-ne 0){'Multicast'}else{'Unicast'})}
    } catch { return [pscustomobject]@{Scope='Unknown';Traffic='Unknown'} }
}

try {
    Assert-ParentAlive;Write-Heartbeat 'Starting'
    $config=[IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json -ErrorAction Stop
    if([string]$config.sessionId -ne $SessionId -or [string]$config.runId -ne $RunId){throw 'Task config session/run mismatch.'}

    if($Mode -in @('OUI_UPDATE','OUI_BUILD_CACHE')) {
        $ouiDir=[string]$config.ouiDir;$cacheFile=[string]$config.cacheFile
        if(-not(Test-Path -LiteralPath $ouiDir)){[void](New-Item -ItemType Directory -Path $ouiDir -Force)}
        if($Mode -eq 'OUI_UPDATE') {
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            foreach($f in @(
                @('https://standards-oui.ieee.org/oui/oui.csv','oui.csv'),
                @('https://standards-oui.ieee.org/oui28/mam.csv','mam.csv'),
                @('https://standards-oui.ieee.org/oui36/oui36.csv','oui36.csv')
            )) {
                Assert-ParentAlive;Write-Heartbeat ('Download-'+$f[1]);Download-FileSafe $f[0] (Join-Path $ouiDir $f[1]) 12000
            }
        }
        Assert-ParentAlive;Write-Heartbeat 'Build-Cache';$count=Build-OuiCache $ouiDir $cacheFile
        Write-JsonAtomic $ResultFile ([ordered]@{schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;success=$true;completedAt=(Get-Date).ToString('o');count=$count;cacheFile=$cacheFile}) 6
    }
    elseif($Mode -eq 'DEEP') {
        $d=$config.device;$ip=[string]$d.IP;$idx=[int]$config.interfaceIndex
        Write-Heartbeat 'Deep-Ping';$ping=Invoke-PingStatistics $ip 4 550
        Assert-ParentAlive;Write-Heartbeat 'Deep-Ports';$checks=@(Test-CommonPorts $ip 220)
        $open=@($checks | Where-Object {$_.State -eq 'Open'} | Select-Object Port,Service)
        $portText=if($open.Count){($open | ForEach-Object {"$($_.Port)/$($_.Service)"}) -join ', '}else{'No open ports detected in the common TCP probe set'}
        $http=$null
        foreach($port in @(80,8080,8000)){if($open.Port -contains $port){Write-Heartbeat 'Deep-HTTP';$http=Get-Http $ip $port 850;if($http){break}}}
        Write-Heartbeat 'Deep-SSDP';$ssdp=Get-Ssdp $ip 1050
        Write-Heartbeat 'Deep-UPnP';$upnp=if($ssdp.Location){Get-Upnp $ssdp.Location $ip 900}else{$null}
        $nbt=if($open.Port -contains 445){Write-Heartbeat 'Deep-NetBIOS';Get-Netbios $ip}else{''}

        $brand=[string]$d.Brand;$model=[string]$d.Model;$type=[string]$d.Type;$name=[string]$d.Name;$os=[string]$d.OS
        if($upnp){
            if($upnp.Manufacturer){$brand=$upnp.Manufacturer}
            if($upnp.ModelName){$model=$upnp.ModelName}elseif($upnp.ModelNumber){$model=$upnp.ModelNumber}
            if($upnp.FriendlyName){$name=[string]$upnp.FriendlyName}
            $dt=([string]$upnp.DeviceType).ToLowerInvariant()
            if($dt -match 'printer'){$type='Printer'}elseif($dt -match 'camera|video'){$type='IP Camera / Media'}elseif($dt -match 'router|internetgateway'){$type='Router / Gateway'}
        }
        if($open.Port -contains 554 -and $type -eq 'Unknown'){$type='IP Camera / Media (heuristic)'}
        if(($open.Port -contains 9100 -or $open.Port -contains 631) -and $type -eq 'Unknown'){$type='Printer (heuristic)'}
        if(($open.Port -contains 445 -or $open.Port -contains 3389) -and $type -eq 'Unknown'){$type='PC / NAS (heuristic)'}
        if($http){
            $sig=("$($http.Server) $($http.Title) $($http.PoweredBy)").ToLowerInvariant()
            if($sig -match 'dahua'){if($brand -eq 'Unknown' -or -not $brand){$brand='Dahua Technology'};if($type -eq 'Unknown'){$type='IP Camera / NVR'}}
            if($sig -match 'hikvision'){if($brand -eq 'Unknown' -or -not $brand){$brand='Hikvision'};if($type -eq 'Unknown'){$type='IP Camera / NVR'}}
        }
        $deep=[ordered]@{Ping=$ping;PortChecks=$checks;Ports=$open;PortText=$portText;HTTP=$http;SSDP=$ssdp;UPnP=$upnp;NetBIOS=$nbt;MacInfo=(Get-MacInfo ([string]$d.MAC));NeighborState=(Get-Neighbor $ip $idx);Brand=$brand;Model=$model;Type=$type;Name=$name;OS=$os}
        Write-JsonAtomic $ResultFile ([ordered]@{schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;success=$true;completedAt=(Get-Date).ToString('o');deep=$deep}) 12
    }
}
catch {
    try{Write-JsonAtomic $ResultFile ([ordered]@{schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;success=$false;completedAt=(Get-Date).ToString('o');error=$_.Exception.Message}) 6}catch{}
    exit 1
}
finally {
    Write-Heartbeat 'Stopped'
}) { throw "Invalid VERSION: $AppVersion" }
$UserAgent = "RF-Network-Tool/$AppVersion"

function Write-TextAtomic([string]$Path,[string]$Text,[System.Text.Encoding]$Encoding=$null) {
    if ($null -eq $Encoding) { $Encoding = New-Object System.Text.UTF8Encoding($true) }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp,$Text,$Encoding)
        if (Test-Path -LiteralPath $Path) {
            try { [IO.File]::Replace($tmp,$Path,$null); return } catch { }
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-JsonAtomic([string]$Path,$Value,[int]$Depth=10) {
    Write-TextAtomic $Path (ConvertTo-Json -InputObject $Value -Depth $Depth)
}

function Test-ParentAlive {
    try {
        $p = Get-Process -Id $ParentPid -ErrorAction Stop
        return ([long]$p.StartTime.Ticks -eq $ParentStartTicks)
    } catch { return $false }
}

function Assert-ParentAlive {
    if (-not (Test-ParentAlive)) { throw 'Parent process is no longer the expected process instance.' }
}

function Write-Heartbeat([string]$Phase) {
    try {
        Write-JsonAtomic $HeartbeatFile ([ordered]@{
            schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;pid=$PID;
            phase=$Phase;heartbeatAt=(Get-Date).ToString('o')
        }) 5
    } catch { }
}

function Download-FileSafe([string]$Url,[string]$Destination,[int]$TimeoutMs=12000,[int64]$MaxBytes=33554432) {
    $resp=$null;$stream=$null;$fs=$null
    $tmp="$Destination.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $uri=[Uri]$Url
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'standards-oui.ieee.org') { throw 'OUI source must be standards-oui.ieee.org over HTTPS.' }
        $req=[Net.HttpWebRequest]::Create($uri)
        $req.Method='GET';$req.Timeout=$TimeoutMs;$req.ReadWriteTimeout=$TimeoutMs
        $req.AllowAutoRedirect=$true;$req.MaximumAutomaticRedirections=3;$req.Proxy=$null
        $req.UserAgent=$UserAgent
        $resp=$req.GetResponse()
        if ($resp.ResponseUri.Scheme -ne 'https' -or $resp.ResponseUri.Host -ne 'standards-oui.ieee.org') { throw "Unexpected IEEE redirect: $($resp.ResponseUri)" }
        if ($resp.ContentLength -gt $MaxBytes) { throw "OUI file exceeds $MaxBytes bytes." }
        $stream=$resp.GetResponseStream()
        $fs=[IO.File]::Open($tmp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buf=New-Object byte[] 65536;$total=[int64]0
        while (($n=$stream.Read($buf,0,$buf.Length)) -gt 0) {
            $total += $n
            if ($total -gt $MaxBytes) { throw "OUI file exceeds $MaxBytes bytes." }
            $fs.Write($buf,0,$n)
        }
        $fs.Flush();$fs.Dispose();$fs=$null
        Move-Item -LiteralPath $tmp -Destination $Destination -Force -ErrorAction Stop
    } finally {
        if ($fs) { try{$fs.Dispose()}catch{} }
        if ($stream) { try{$stream.Dispose()}catch{} }
        if ($resp) { try{$resp.Close()}catch{} }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Build-OuiCache([string]$OuiDir,[string]$CacheFile) {
    $specs=@(
        [pscustomobject]@{File='oui.csv';Len=6},
        [pscustomobject]@{File='mam.csv';Len=7},
        [pscustomobject]@{File='oui36.csv';Len=9}
    )
    $tmp="$CacheFile.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $writer=$null;$count=0
    try {
        $cacheDir=Split-Path -Parent $CacheFile
        if ($cacheDir -and -not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
        $writer=New-Object IO.StreamWriter($tmp,$false,(New-Object Text.UTF8Encoding($false)))
        foreach($spec in $specs) {
            Assert-ParentAlive
            Write-Heartbeat ("Parse-"+$spec.File)
            $path=Join-Path $OuiDir $spec.File
            if (-not (Test-Path -LiteralPath $path)) { continue }
            foreach($row in (Import-Csv -LiteralPath $path)) {
                $key=([string]$row.Assignment -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
                $org=[string]$row.'Organization Name'
                if (-not $key -or -not $org) { continue }
                $org=[regex]::Replace($org,'[\t\r\n]+',' ').Trim()
                $writer.WriteLine("$($spec.Len)`t$key`t$org")
                $count++
            }
        }
        $writer.Flush();$writer.Dispose();$writer=$null
        if (Test-Path -LiteralPath $CacheFile) {
            try { [IO.File]::Replace($tmp,$CacheFile,$null); return $count } catch { }
        }
        Move-Item -LiteralPath $tmp -Destination $CacheFile -Force -ErrorAction Stop
        return $count
    } finally {
        if ($writer) { try{$writer.Dispose()}catch{} }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-PingStatistics([string]$Ip,[int]$Count=4,[int]$Timeout=650) {
    $times=@();$ttl=$null;$ok=0
    for($i=0;$i -lt $Count;$i++) {
        Assert-ParentAlive
        $ping=New-Object Net.NetworkInformation.Ping
        try {
            $task=$ping.SendPingAsync($Ip,$Timeout)
            if ($task.Wait($Timeout+1000) -and -not $task.IsFaulted) {
                $reply=$task.Result
                if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                    $ok++;$times += [int]$reply.RoundtripTime
                    if ($reply.Options) { $ttl=$reply.Options.Ttl }
                }
            }
        } catch { } finally { try{$ping.Dispose()}catch{} }
        Write-Heartbeat 'Deep-Ping'
    }
    $loss=[Math]::Round((($Count-$ok)*100.0/$Count),0)
    if ($times.Count) {
        $m=$times|Measure-Object -Minimum -Maximum -Average
        $min=$m.Minimum;$max=$m.Maximum;$avg=[Math]::Round($m.Average,1)
    } else { $min='-';$max='-';$avg='-' }
    return [pscustomobject]@{Sent=$Count;Received=$ok;LossPercent=$loss;Min=$min;Avg=$avg;Max=$max;TTL=$(if($ttl){$ttl}else{'-'})}
}

function Test-Tcp([string]$Ip,[int]$Port,[int]$Timeout=220) {
    $client=New-Object Net.Sockets.TcpClient;$ar=$null
    try {
        $ar=$client.BeginConnect($Ip,$Port,$null,$null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Timeout,$false)) { return [pscustomobject]@{State='Filtered / Timeout';Detail="No response within ${Timeout} ms"} }
        try {
            $client.EndConnect($ar)
            if ($client.Connected) { return [pscustomobject]@{State='Open';Detail='TCP connection established'} }
        } catch { return [pscustomobject]@{State='Closed / Refused';Detail=$_.Exception.Message} }
        return [pscustomobject]@{State='Closed / Refused';Detail='Connection not established'}
    } catch { return [pscustomobject]@{State='Closed / Refused';Detail=$_.Exception.Message} }
    finally {
        if ($ar -and $ar.AsyncWaitHandle) { try{$ar.AsyncWaitHandle.Close()}catch{} }
        try{$client.Close()}catch{}
    }
}

function Test-CommonPorts([string]$Ip,[int]$Timeout=220) {
    $ports=[ordered]@{21='FTP';22='SSH';23='Telnet';53='DNS';80='HTTP';443='HTTPS';445='SMB';554='RTSP';631='IPP';1883='MQTT';3389='RDP';5900='VNC';8000='HTTP/API';8080='HTTP-alt';8443='HTTPS-alt';8883='MQTT/TLS';9100='Printer/JetDirect'}
    $out=New-Object Collections.Generic.List[object]
    foreach($portKey in $ports.Keys) {
        Assert-ParentAlive
        $port=[int]$portKey;$r=Test-Tcp $Ip $port $Timeout
        [void]$out.Add([pscustomobject]@{Port=$port;Service=$ports[$portKey];State=$r.State;Detail=$r.Detail})
        Write-Heartbeat 'Deep-Ports'
    }
    return $out.ToArray()
}

function Read-ResponseLimited($Response,[int]$MaxChars=262144) {
    $reader=$null
    try {
        $reader=New-Object IO.StreamReader($Response.GetResponseStream())
        $buf=New-Object char[] 4096;$sb=New-Object Text.StringBuilder
        while($sb.Length -lt $MaxChars) {
            $want=[Math]::Min($buf.Length,$MaxChars-$sb.Length);$n=$reader.Read($buf,0,$want)
            if ($n -le 0) { break }
            [void]$sb.Append($buf,0,$n)
        }
        return $sb.ToString()
    } finally { if ($reader) { try{$reader.Dispose()}catch{} } }
}

function Get-Http([string]$Ip,[int]$Port,[int]$Timeout=850) {
    $resp=$null
    try {
        $uri="http://$Ip" + $(if($Port -ne 80){":$Port"}else{''}) + '/'
        $req=[Net.HttpWebRequest]::Create($uri);$req.Method='GET';$req.Timeout=$Timeout;$req.ReadWriteTimeout=$Timeout
        $req.AllowAutoRedirect=$false;$req.Proxy=$null;$req.UserAgent=$UserAgent
        $resp=$req.GetResponse();$body=Read-ResponseLimited $resp 262144;$title=''
        if ($body -match '(?is)<title[^>]*>\s*(.*?)\s*</title>') {
            $title=([regex]::Replace($matches[1],'<[^>]+>','')).Trim();if($title.Length -gt 160){$title=$title.Substring(0,160)}
        }
        return [pscustomobject]@{URL=$uri;Status=[int]$resp.StatusCode;Server=[string]$resp.Headers['Server'];PoweredBy=[string]$resp.Headers['X-Powered-By'];Title=$title}
    } catch { return $null }
    finally { if($resp){try{$resp.Close()}catch{}} }
}

function Get-Ssdp([string]$Ip,[int]$WindowMs=1050) {
    $result=[ordered]@{Server='';ST='';USN='';Location='';CacheControl=''};$udp=$null
    try {
        $udp=New-Object Net.Sockets.UdpClient;$udp.Client.ReceiveTimeout=220
        $msg="M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 1`r`nST: ssdp:all`r`n`r`n"
        $bytes=[Text.Encoding]::ASCII.GetBytes($msg);[void]$udp.Send($bytes,$bytes.Length,'239.255.255.250',1900)
        $sw=[Diagnostics.Stopwatch]::StartNew()
        while($sw.ElapsedMilliseconds -lt $WindowMs) {
            Assert-ParentAlive
            $ep=New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
            try{$data=$udp.Receive([ref]$ep)}catch{continue}
            if($ep.Address.ToString() -ne $Ip){continue}
            $txt=[Text.Encoding]::UTF8.GetString($data)
            foreach($line in ($txt -split "`r?`n")) {
                if($line -match '^\s*([^:]+):\s*(.*)$') {
                    $k=$matches[1].Trim().ToUpperInvariant();$v=$matches[2].Trim()
                    if($k -eq 'SERVER' -and -not $result.Server){$result.Server=$v}
                    elseif($k -eq 'ST' -and -not $result.ST){$result.ST=$v}
                    elseif($k -eq 'USN' -and -not $result.USN){$result.USN=$v}
                    elseif($k -eq 'LOCATION' -and -not $result.Location){$result.Location=$v}
                    elseif($k -eq 'CACHE-CONTROL' -and -not $result.CacheControl){$result.CacheControl=$v}
                }
            }
            if($result.Location){break}
        }
    } catch { }
    finally { if($udp){try{$udp.Close()}catch{}} }
    return [pscustomobject]$result
}

function ConvertFrom-SafeXml([string]$Text) {
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    $sr=$null;$xr=$null
    try {
        $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=1048576
        $sr=New-Object IO.StringReader($Text);$xr=[Xml.XmlReader]::Create($sr,$settings)
        $doc=New-Object Xml.XmlDocument;$doc.XmlResolver=$null;$doc.Load($xr);return $doc
    } finally { if($xr){try{$xr.Dispose()}catch{}};if($sr){try{$sr.Dispose()}catch{}} }
}

function Get-Upnp([string]$Location,[string]$Ip,[int]$Timeout=900) {
    if([string]::IsNullOrWhiteSpace($Location)){return $null};$resp=$null
    try {
        $uri=[Uri]$Location
        if($uri.Scheme -notin @('http','https') -or $uri.Host -ne $Ip){return $null}
        $req=[Net.HttpWebRequest]::Create($uri);$req.Method='GET';$req.Timeout=$Timeout;$req.ReadWriteTimeout=$Timeout;$req.AllowAutoRedirect=$false;$req.Proxy=$null;$req.UserAgent=$UserAgent
        $resp=$req.GetResponse();$xml=ConvertFrom-SafeXml (Read-ResponseLimited $resp 524288);if(-not $xml){return $null}
        function Get-NodeText([string]$Name){$node=$xml.SelectSingleNode("//*[local-name()='device']/*[local-name()='$Name']");if($node){return [string]$node.InnerText}else{return ''}}
        return [pscustomobject]@{FriendlyName=(Get-NodeText 'friendlyName');Manufacturer=(Get-NodeText 'manufacturer');ModelName=(Get-NodeText 'modelName');ModelNumber=(Get-NodeText 'modelNumber');SerialNumber=(Get-NodeText 'serialNumber');DeviceType=(Get-NodeText 'deviceType');ManufacturerURL=(Get-NodeText 'manufacturerURL');ModelURL=(Get-NodeText 'modelURL')}
    } catch { return $null }
    finally { if($resp){try{$resp.Close()}catch{}} }
}

function Invoke-ProcessText([string]$File,[string]$Arguments,[int]$Timeout=1200) {
    $p=$null
    try {
        $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$File;$psi.Arguments=$Arguments;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;if(-not $p.Start()){return ''}
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit($Timeout)){try{$p.Kill()}catch{};return ''}
        try{[void]$outTask.Wait(250);[void]$errTask.Wait(250)}catch{}
        return $(if($outTask.IsCompleted){$outTask.Result}else{''})
    } catch { return '' }
    finally { if($p){try{$p.Dispose()}catch{}} }
}

function Get-Netbios([string]$Ip) {
    $exe=Join-Path $env:SystemRoot 'System32\nbtstat.exe';$out=Invoke-ProcessText $exe "-A $Ip" 1200
    if(-not $out){return ''};return (@($out -split "`r?`n" | Where-Object {$_ -match '<[0-9A-Fa-f]{2}>'}) -join "`r`n").Trim()
}

function Get-Neighbor([string]$Ip,[int]$InterfaceIndex) {
    try {
        if(Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue){
            $n=Get-NetNeighbor -AddressFamily IPv4 -IPAddress $Ip -ErrorAction SilentlyContinue | Where-Object {$InterfaceIndex -eq 0 -or $_.InterfaceIndex -eq $InterfaceIndex} | Select-Object -First 1
            if($n){return [string]$n.State}
        }
    } catch { }
    return 'Unknown'
}

function Get-MacInfo([string]$Mac) {
    $clean=if($Mac){($Mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()}else{''}
    if($clean.Length -lt 12){return [pscustomobject]@{Scope='Unknown';Traffic='Unknown'}}
    try {
        $first=[Convert]::ToInt32($clean.Substring(0,2),16)
        return [pscustomobject]@{Scope=$(if(($first -band 2)-ne 0){'Locally administered / randomized'}else{'Universally administered'});Traffic=$(if(($first -band 1)-ne 0){'Multicast'}else{'Unicast'})}
    } catch { return [pscustomobject]@{Scope='Unknown';Traffic='Unknown'} }
}

try {
    Assert-ParentAlive;Write-Heartbeat 'Starting'
    $config=[IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json -ErrorAction Stop
    if([string]$config.sessionId -ne $SessionId -or [string]$config.runId -ne $RunId){throw 'Task config session/run mismatch.'}

    if($Mode -in @('OUI_UPDATE','OUI_BUILD_CACHE')) {
        $ouiDir=[string]$config.ouiDir;$cacheFile=[string]$config.cacheFile
        if(-not(Test-Path -LiteralPath $ouiDir)){[void](New-Item -ItemType Directory -Path $ouiDir -Force)}
        if($Mode -eq 'OUI_UPDATE') {
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            foreach($f in @(
                @('https://standards-oui.ieee.org/oui/oui.csv','oui.csv'),
                @('https://standards-oui.ieee.org/oui28/mam.csv','mam.csv'),
                @('https://standards-oui.ieee.org/oui36/oui36.csv','oui36.csv')
            )) {
                Assert-ParentAlive;Write-Heartbeat ('Download-'+$f[1]);Download-FileSafe $f[0] (Join-Path $ouiDir $f[1]) 12000
            }
        }
        Assert-ParentAlive;Write-Heartbeat 'Build-Cache';$count=Build-OuiCache $ouiDir $cacheFile
        Write-JsonAtomic $ResultFile ([ordered]@{schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;success=$true;completedAt=(Get-Date).ToString('o');count=$count;cacheFile=$cacheFile}) 6
    }
    elseif($Mode -eq 'DEEP') {
        $d=$config.device;$ip=[string]$d.IP;$idx=[int]$config.interfaceIndex
        Write-Heartbeat 'Deep-Ping';$ping=Invoke-PingStatistics $ip 4 550
        Assert-ParentAlive;Write-Heartbeat 'Deep-Ports';$checks=@(Test-CommonPorts $ip 220)
        $open=@($checks | Where-Object {$_.State -eq 'Open'} | Select-Object Port,Service)
        $portText=if($open.Count){($open | ForEach-Object {"$($_.Port)/$($_.Service)"}) -join ', '}else{'No open ports detected in the common TCP probe set'}
        $http=$null
        foreach($port in @(80,8080,8000)){if($open.Port -contains $port){Write-Heartbeat 'Deep-HTTP';$http=Get-Http $ip $port 850;if($http){break}}}
        Write-Heartbeat 'Deep-SSDP';$ssdp=Get-Ssdp $ip 1050
        Write-Heartbeat 'Deep-UPnP';$upnp=if($ssdp.Location){Get-Upnp $ssdp.Location $ip 900}else{$null}
        $nbt=if($open.Port -contains 445){Write-Heartbeat 'Deep-NetBIOS';Get-Netbios $ip}else{''}

        $brand=[string]$d.Brand;$model=[string]$d.Model;$type=[string]$d.Type;$name=[string]$d.Name;$os=[string]$d.OS
        if($upnp){
            if($upnp.Manufacturer){$brand=$upnp.Manufacturer}
            if($upnp.ModelName){$model=$upnp.ModelName}elseif($upnp.ModelNumber){$model=$upnp.ModelNumber}
            if($upnp.FriendlyName){$name=[string]$upnp.FriendlyName}
            $dt=([string]$upnp.DeviceType).ToLowerInvariant()
            if($dt -match 'printer'){$type='Printer'}elseif($dt -match 'camera|video'){$type='IP Camera / Media'}elseif($dt -match 'router|internetgateway'){$type='Router / Gateway'}
        }
        if($open.Port -contains 554 -and $type -eq 'Unknown'){$type='IP Camera / Media (heuristic)'}
        if(($open.Port -contains 9100 -or $open.Port -contains 631) -and $type -eq 'Unknown'){$type='Printer (heuristic)'}
        if(($open.Port -contains 445 -or $open.Port -contains 3389) -and $type -eq 'Unknown'){$type='PC / NAS (heuristic)'}
        if($http){
            $sig=("$($http.Server) $($http.Title) $($http.PoweredBy)").ToLowerInvariant()
            if($sig -match 'dahua'){if($brand -eq 'Unknown' -or -not $brand){$brand='Dahua Technology'};if($type -eq 'Unknown'){$type='IP Camera / NVR'}}
            if($sig -match 'hikvision'){if($brand -eq 'Unknown' -or -not $brand){$brand='Hikvision'};if($type -eq 'Unknown'){$type='IP Camera / NVR'}}
        }
        $deep=[ordered]@{Ping=$ping;PortChecks=$checks;Ports=$open;PortText=$portText;HTTP=$http;SSDP=$ssdp;UPnP=$upnp;NetBIOS=$nbt;MacInfo=(Get-MacInfo ([string]$d.MAC));NeighborState=(Get-Neighbor $ip $idx);Brand=$brand;Model=$model;Type=$type;Name=$name;OS=$os}
        Write-JsonAtomic $ResultFile ([ordered]@{schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;success=$true;completedAt=(Get-Date).ToString('o');deep=$deep}) 12
    }
}
catch {
    try{Write-JsonAtomic $ResultFile ([ordered]@{schemaVersion=1;sessionId=$SessionId;runId=$RunId;mode=$Mode;success=$false;completedAt=(Get-Date).ToString('o');error=$_.Exception.Message}) 6}catch{}
    exit 1
}
finally {
    Write-Heartbeat 'Stopped'
}