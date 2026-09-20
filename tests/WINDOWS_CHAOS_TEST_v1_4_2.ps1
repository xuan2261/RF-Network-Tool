param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pingWorker=Join-Path $root 'RF-Network-Tool-PingWorker.ps1'
$scanWorker=Join-Path $root 'RF-Network-Tool-ScanWorker.ps1'
$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$c,[string]$n){if($c){Write-Host "PASS $n" -ForegroundColor Green}else{Write-Host "FAIL $n" -ForegroundColor Red;[void]$fail.Add($n)}}
function Wait-Path([string]$path,[int]$timeoutMs=7000){$sw=[Diagnostics.Stopwatch]::StartNew();while($sw.ElapsedMilliseconds -lt $timeoutMs){if(Test-Path -LiteralPath $path){return $true};Start-Sleep -Milliseconds 80};return $false}
function Wait-Removed([string]$path,[int]$timeoutMs=7000){$sw=[Diagnostics.Stopwatch]::StartNew();while($sw.ElapsedMilliseconds -lt $timeoutMs){if(-not(Test-Path -LiteralPath $path)){return $true};Start-Sleep -Milliseconds 80};return $false}
function Wait-JsonSession([string]$path,[string]$session,[int]$timeoutMs=7000){
  $sw=[Diagnostics.Stopwatch]::StartNew()
  while($sw.ElapsedMilliseconds -lt $timeoutMs){
    if(Test-Path -LiteralPath $path){try{$j=[IO.File]::ReadAllText($path)|ConvertFrom-Json;if([string]$j.sessionId -eq $session){return $true}}catch{}}
    Start-Sleep -Milliseconds 80
  }
  return $false
}
function Start-HiddenPs([string]$scriptPath,[string[]]$argumentList){
  $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $parts=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'))+$argumentList
  $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$psExe;$psi.Arguments=($parts -join ' ');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  $proc=New-Object Diagnostics.Process;$proc.StartInfo=$psi;if(-not $proc.Start()){throw "Cannot start $scriptPath"};return $proc
}
function Wait-Exit($proc,[int]$timeoutMs=10000){try{return $proc.WaitForExit($timeoutMs)}catch{return $false}}
function Write-JsonFile([string]$path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
function New-ScanConfig([string]$path,[string]$runId,[object[]]$targets,[string]$profile='FAST'){
  $cfg=[ordered]@{schemaVersion=3;RunId=$runId;Targets=$targets;Profile=$profile;LocalIP='127.0.0.1';LocalMAC='02-00-00-00-00-01';InterfaceIndex=1;FastPingTimeoutMs=100;RetryEnabled=$false;RetryPingTimeoutMs=300;PingConcurrency=32;ArpConcurrency=16;DiscoveryDurationSec=0;DiscoveryMode=$profile}
  Write-JsonFile $path $cfg
}
$tmp=Join-Path $env:TEMP ('RFT-v142-chaos-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tmp -Force|Out-Null
$parentTicks=[long](Get-Process -Id $PID).StartTime.Ticks
try{
  $ipc=Join-Path $tmp 'ping';New-Item -ItemType Directory -Path $ipc -Force|Out-Null
  $session='chaos-'+[guid]::NewGuid().ToString('N')
  $ping=Start-HiddenPs $pingWorker @('-IpcDir',('"'+$ipc+'"'),'-SessionId',$session,'-ParentPid',[string]$PID,'-ParentStartTicks',[string]$parentTicks,'-DefaultConcurrency','8')
  try{
    $hb=Join-Path $ipc 'worker-state.json';Assert-True (Wait-JsonSession $hb $session 5000) 'Chaos ping worker started'
    $mal=Join-Path $ipc 'request-malformed.json';[IO.File]::WriteAllText($mal,'{"broken":',[Text.Encoding]::UTF8)
    Assert-True (Wait-Removed $mal 5000) 'Malformed IPC request consumed'
    Assert-True (-not $ping.HasExited) 'Worker survives malformed IPC'
    $wrongId='wrong-'+[guid]::NewGuid().ToString('N');$wrongPath=Join-Path $ipc ("request-$wrongId.json")
    Write-JsonFile $wrongPath ([ordered]@{schemaVersion=1;sessionId='stale-session';requestId=$wrongId;kind='PING_SINGLE';timeoutMs=500;concurrency=2;targets=@([ordered]@{Target='127.0.0.1';Alias='Wrong session'})})
    Assert-True (Wait-Removed $wrongPath 5000) 'Stale-session request discarded'
    Start-Sleep -Milliseconds 250
    Assert-True (-not(Test-Path (Join-Path $ipc ("result-$wrongId.json")))) 'Stale-session request creates no result'
    $burstIds=@()
    1..8|ForEach-Object{
      $id='burst-'+$_+'-'+[guid]::NewGuid().ToString('N');$burstIds+=$id
      Write-JsonFile (Join-Path $ipc ("request-$id.json")) ([ordered]@{schemaVersion=1;sessionId=$session;requestId=$id;kind='PING_SINGLE';timeoutMs=750;concurrency=4;targets=@([ordered]@{Target='127.0.0.1';Alias="Burst $_"})})
    }
    foreach($id in $burstIds){
      $rp=Join-Path $ipc ("result-$id.json");Assert-True (Wait-Path $rp 8000) "Burst result $id"
      if(Test-Path $rp){$j=[IO.File]::ReadAllText($rp)|ConvertFrom-Json;$rows=@($j.results);Assert-True ([string]$j.requestId -eq $id -and $rows.Count -eq 1 -and [bool]$rows[0].Success) "Burst payload $id"}
    }
    try{$ping.Kill()}catch{};Assert-True (Wait-Exit $ping 5000) 'Abrupt worker termination observed'
  } finally {try{$ping.Dispose()}catch{}}
  $session2='restart-'+[guid]::NewGuid().ToString('N')
  $ping2=Start-HiddenPs $pingWorker @('-IpcDir',('"'+$ipc+'"'),'-SessionId',$session2,'-ParentPid',[string]$PID,'-ParentStartTicks',[string]$parentTicks,'-DefaultConcurrency','4')
  try{
    Assert-True (Wait-JsonSession (Join-Path $ipc 'worker-state.json') $session2 5000) 'Ping worker restarts on stale IPC directory'
    $id='restart-req-'+[guid]::NewGuid().ToString('N')
    Write-JsonFile (Join-Path $ipc ("request-$id.json")) ([ordered]@{schemaVersion=1;sessionId=$session2;requestId=$id;kind='PING_SINGLE';timeoutMs=750;concurrency=2;targets=@([ordered]@{Target='127.0.0.1';Alias='Restart'})})
    $rp=Join-Path $ipc ("result-$id.json");Assert-True (Wait-Path $rp 7000) 'Restarted worker returns result'
    if(Test-Path $rp){$j=[IO.File]::ReadAllText($rp)|ConvertFrom-Json;$row=@($j.results|Select-Object -First 1);Assert-True ($row.Count -eq 1 -and [bool]$row[0].Success) 'Restarted worker loopback success'}
    [IO.File]::WriteAllText((Join-Path $ipc 'stop.flag'),'stop',[Text.Encoding]::ASCII)
    Assert-True (Wait-Exit $ping2 5000) 'Stop flag terminates worker'
    if(Test-Path (Join-Path $ipc 'worker-state.json')){$st=[IO.File]::ReadAllText((Join-Path $ipc 'worker-state.json'))|ConvertFrom-Json;Assert-True ([string]$st.state -eq 'Stopped') 'Stop flag publishes Stopped heartbeat'}
  } finally {if(-not $ping2.HasExited){try{$ping2.Kill()}catch{}};try{$ping2.Dispose()}catch{}}
  $parentExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $parent=Start-Process -FilePath $parentExe -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  try{
    $pt=[long]$parent.StartTime.Ticks;$ipcParent=Join-Path $tmp 'parent-ipc';New-Item -ItemType Directory -Path $ipcParent -Force|Out-Null
    $child=Start-HiddenPs $pingWorker @('-IpcDir',('"'+$ipcParent+'"'),'-SessionId','parent-watch','-ParentPid',[string]$parent.Id,'-ParentStartTicks',[string]$pt,'-DefaultConcurrency','2')
    try{
      Assert-True (Wait-JsonSession (Join-Path $ipcParent 'worker-state.json') 'parent-watch' 5000) 'Parent-watch worker started'
      try{$parent.Kill()}catch{};[void]$parent.WaitForExit(3000)
      Assert-True (Wait-Exit $child 5000) 'Worker exits after parent death'
      if(Test-Path (Join-Path $ipcParent 'worker-state.json')){$st=[IO.File]::ReadAllText((Join-Path $ipcParent 'worker-state.json'))|ConvertFrom-Json;Assert-True ([string]$st.state -eq 'Stopped') 'Parent death publishes Stopped heartbeat'}
    } finally {if(-not $child.HasExited){try{$child.Kill()}catch{}};try{$child.Dispose()}catch{}}
  } finally {if(-not $parent.HasExited){try{$parent.Kill()}catch{}};try{$parent.Dispose()}catch{}}
  $badCfg=Join-Path $tmp 'bad-scan.json';[IO.File]::WriteAllText($badCfg,'{not json',[Text.Encoding]::UTF8)
  $badState=Join-Path $tmp 'bad-state.json';$badCancel=Join-Path $tmp 'bad-cancel.flag'
  $badProc=Start-HiddenPs $scanWorker @('-ConfigFile',('"'+$badCfg+'"'),'-StateFile',('"'+$badState+'"'),'-CancelFile',('"'+$badCancel+'"'))
  try{Assert-True (Wait-Exit $badProc 8000) 'Invalid scan config exits';if($badProc.HasExited){Assert-True ($badProc.ExitCode -eq 2) 'Invalid scan config exit code 2'}}finally{if(-not $badProc.HasExited){try{$badProc.Kill()}catch{}};try{$badProc.Dispose()}catch{}}
  $cfg=Join-Path $tmp 'cancel.json';$state=Join-Path $tmp 'cancel-state.json';$cancel=Join-Path $tmp 'cancel.flag';New-ScanConfig $cfg 'cancel-run' @('127.0.0.1','127.0.0.2') 'FAST';[IO.File]::WriteAllText($cancel,'cancel',[Text.Encoding]::ASCII)
  $cp=Start-HiddenPs $scanWorker @('-ConfigFile',('"'+$cfg+'"'),'-StateFile',('"'+$state+'"'),'-CancelFile',('"'+$cancel+'"'))
  try{Assert-True (Wait-Exit $cp 10000) 'Pre-cancelled scan exits';Assert-True (Wait-Path $state 3000) 'Pre-cancelled scan state exists';if(Test-Path $state){$s=[IO.File]::ReadAllText($state)|ConvertFrom-Json;Assert-True ([bool]$s.complete -and [bool]$s.cancelled -and [string]$s.phase -eq 'cancelled') 'Pre-cancelled scan state contract'}}finally{if(-not $cp.HasExited){try{$cp.Kill()}catch{}};try{$cp.Dispose()}catch{}}
  $cfg2=Join-Path $tmp 'parent-scan.json';$state2=Join-Path $tmp 'parent-scan-state.json';$cancel2=Join-Path $tmp 'parent-scan-cancel.flag';New-ScanConfig $cfg2 'parent-mismatch' @('127.0.0.1') 'FAST'
  $sp=Start-HiddenPs $scanWorker @('-ConfigFile',('"'+$cfg2+'"'),'-StateFile',('"'+$state2+'"'),'-CancelFile',('"'+$cancel2+'"'),'-ParentPid',[string]$PID,'-ParentStartTicks',[string]($parentTicks+1))
  try{Assert-True (Wait-Exit $sp 10000) 'Parent-mismatch scan exits';Assert-True (Wait-Path $state2 3000) 'Parent-mismatch state exists';if(Test-Path $state2){$s=[IO.File]::ReadAllText($state2)|ConvertFrom-Json;Assert-True ([bool]$s.cancelled) 'Parent mismatch fails closed as cancelled'}}finally{if(-not $sp.HasExited){try{$sp.Kill()}catch{}};try{$sp.Dispose()}catch{}}
  $cfg3=Join-Path $tmp 'dedupe.json';$state3=Join-Path $tmp 'dedupe-state.json';$cancel3=Join-Path $tmp 'dedupe-cancel.flag';New-ScanConfig $cfg3 'dedupe-run' @('127.0.0.1','127.0.0.1','127.0.0.1') 'TURBO'
  $dp=Start-HiddenPs $scanWorker @('-ConfigFile',('"'+$cfg3+'"'),'-StateFile',('"'+$state3+'"'),'-CancelFile',('"'+$cancel3+'"'))
  try{Assert-True (Wait-Exit $dp 12000) 'Dedupe/fallback scan exits';Assert-True (Wait-Path $state3 3000) 'Dedupe/fallback state exists';if(Test-Path $state3){$s=[IO.File]::ReadAllText($state3)|ConvertFrom-Json;Assert-True ([int]$s.total -eq 1) 'Duplicate scan targets deduplicated';Assert-True ([string]$s.profile -eq 'BALANCED') 'Unknown profile falls back to BALANCED';Assert-True ([bool]$s.complete -and -not [string]$s.error) 'Dedupe/fallback scan completes cleanly'}}finally{if(-not $dp.HasExited){try{$dp.Kill()}catch{}};try{$dp.Dispose()}catch{}}
} finally {Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
if($fail.Count){Write-Host ("FAILED: "+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL WINDOWS CHAOS/RECOVERY TESTS PASSED' -ForegroundColor Green
exit 0
