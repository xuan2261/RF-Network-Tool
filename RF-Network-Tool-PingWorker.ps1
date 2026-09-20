param(
    [Parameter(Mandatory=$true)][string]$IpcDir,
    [Parameter(Mandatory=$true)][string]$SessionId,
    [Parameter(Mandatory=$true)][int]$ParentPid,
    [Parameter(Mandatory=$true)][long]$ParentStartTicks,
    [int]$DefaultConcurrency = 24
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

function Write-JsonAtomic([string]$Path,$Value,[int]$Depth=8) {
    $dir=Split-Path -Parent $Path
    if($dir -and -not(Test-Path -LiteralPath $dir)){[void](New-Item -ItemType Directory -Path $dir -Force)}
    $tmp="$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json=ConvertTo-Json -InputObject $Value -Depth $Depth
        [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($true)))
        if(Test-Path -LiteralPath $Path){try{[IO.File]::Replace($tmp,$Path,$null);return}catch{}}
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    } finally {if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}}
}

function Test-ParentAlive {
    try {
        $p=Get-Process -Id $ParentPid -ErrorAction Stop
        return ([long]$p.StartTime.Ticks -eq $ParentStartTicks)
    } catch {return $false}
}

function Write-Heartbeat([string]$State='Idle',[string]$RequestId='') {
    try {
        Write-JsonAtomic (Join-Path $IpcDir 'worker-state.json') ([ordered]@{
            schemaVersion=1;sessionId=$SessionId;pid=$PID;parentPid=$ParentPid;parentStartTicks=$ParentStartTicks;
            state=$State;requestId=$RequestId;heartbeatAt=(Get-Date).ToString('o')
        }) 5
    } catch { }
}

function Invoke-PingBatch($Request) {
    $requestId=[string]$Request.requestId
    $kind=[string]$Request.kind
    $timeout=[Math]::Max(50,[Math]::Min(10000,[int]$Request.timeoutMs))
    $concurrency=[Math]::Max(1,[Math]::Min(64, $(if($Request.PSObject.Properties['concurrency']){[int]$Request.concurrency}else{$DefaultConcurrency})))
    $targets=@($Request.targets)
    $results=New-Object System.Collections.Generic.List[object]
    $completed=0

    for($offset=0;$offset -lt $targets.Count;$offset += $concurrency){
        if(-not(Test-ParentAlive)){break}
        $take=[Math]::Min($concurrency,$targets.Count-$offset)
        $jobs=New-Object System.Collections.Generic.List[object]
        for($i=0;$i -lt $take;$i++){
            $t=$targets[$offset+$i]
            $ping=New-Object Net.NetworkInformation.Ping
            try {
                $task=$ping.SendPingAsync([string]$t.Target,$timeout)
                [void]$jobs.Add([pscustomobject]@{Target=[string]$t.Target;Alias=[string]$t.Alias;Ping=$ping;Task=$task})
            } catch {
                try{$ping.Dispose()}catch{}
                [void]$results.Add([pscustomobject]@{Target=[string]$t.Target;Alias=[string]$t.Alias;Success=$false;Status='ERROR';Time='-';TTL='-';Address='-';Detail=$_.Exception.Message})
                $completed++
            }
        }
        foreach($j in $jobs.ToArray()){
            try {
                $waitMs=$timeout+1500
                if(-not $j.Task.Wait($waitMs)){throw "Timeout after ${timeout} ms"}
                if($j.Task.IsFaulted){throw $j.Task.Exception.GetBaseException()}
                $reply=$j.Task.Result
                if($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success){
                    $ttl=if($reply.Options){$reply.Options.Ttl}else{'-'}
                    [void]$results.Add([pscustomobject]@{Target=$j.Target;Alias=$j.Alias;Success=$true;Status='ONLINE';Time=[int64]$reply.RoundtripTime;TTL=$ttl;Address=$reply.Address.ToString();Detail='Success'})
                } else {
                    [void]$results.Add([pscustomobject]@{Target=$j.Target;Alias=$j.Alias;Success=$false;Status='OFFLINE';Time='-';TTL='-';Address='-';Detail=$reply.Status.ToString()})
                }
            } catch {
                [void]$results.Add([pscustomobject]@{Target=$j.Target;Alias=$j.Alias;Success=$false;Status='ERROR';Time='-';TTL='-';Address='-';Detail=$_.Exception.Message})
            } finally {
                try{$j.Ping.Dispose()}catch{}
                $completed++
            }
        }
        Write-Heartbeat 'Working' $requestId
    }

    return [ordered]@{
        schemaVersion=1;sessionId=$SessionId;requestId=$requestId;kind=$kind;completedAt=(Get-Date).ToString('o');
        requested=$targets.Count;completed=$completed;results=$results.ToArray()
    }
}

if(-not(Test-Path -LiteralPath $IpcDir)){[void](New-Item -ItemType Directory -Path $IpcDir -Force)}
$stopFile=Join-Path $IpcDir 'stop.flag'
Write-Heartbeat 'Starting' ''
try {
    while($true){
        if(Test-Path -LiteralPath $stopFile){break}
        if(-not(Test-ParentAlive)){break}
        $requests=@(Get-ChildItem -LiteralPath $IpcDir -Filter 'request-*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc,Name)
        if($requests.Count -eq 0){Write-Heartbeat 'Idle' '';Start-Sleep -Milliseconds 120;continue}
        foreach($reqFile in $requests){
            if(Test-Path -LiteralPath $stopFile){break}
            if(-not(Test-ParentAlive)){break}
            $requestId=''
            try {
                $raw=[IO.File]::ReadAllText($reqFile.FullName)
                $req=$raw | ConvertFrom-Json -ErrorAction Stop
                $requestId=[string]$req.requestId
                if([string]$req.sessionId -ne $SessionId){Remove-Item -LiteralPath $reqFile.FullName -Force -ErrorAction SilentlyContinue;continue}
                Write-Heartbeat 'Working' $requestId
                $out=Invoke-PingBatch $req
                Write-JsonAtomic (Join-Path $IpcDir ("result-$requestId.json")) $out 8
            } catch {
                if($requestId){
                    Write-JsonAtomic (Join-Path $IpcDir ("result-$requestId.json")) ([ordered]@{schemaVersion=1;sessionId=$SessionId;requestId=$requestId;kind='ERROR';completedAt=(Get-Date).ToString('o');requested=0;completed=0;error=$_.Exception.Message;results=@()}) 6
                }
            } finally {Remove-Item -LiteralPath $reqFile.FullName -Force -ErrorAction SilentlyContinue}
        }
    }
} finally {
    Write-Heartbeat 'Stopped' ''
}