param([int]$ScanBudgetMs=25000,[int]$PingBudgetMs=10000)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scanWorker=Join-Path $root 'RF-Network-Tool-ScanWorker.ps1'
$pingWorker=Join-Path $root 'RF-Network-Tool-PingWorker.ps1'
$artifactDir=Join-Path $root 'ci-artifacts';New-Item -ItemType Directory -Path $artifactDir -Force|Out-Null
$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$c,[string]$n){if($c){Write-Host "PASS $n" -ForegroundColor Green}else{Write-Host "FAIL $n" -ForegroundColor Red;[void]$fail.Add($n)}}
function Wait-Path([string]$path,[int]$timeoutMs=7000){$sw=[Diagnostics.Stopwatch]::StartNew();while($sw.ElapsedMilliseconds -lt $timeoutMs){if(Test-Path -LiteralPath $path){return $true};Start-Sleep -Milliseconds 60};return $false}
function Start-HiddenPs([string]$scriptPath,[string[]]$argumentList){
  $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $parts=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'))+$argumentList
  $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$psExe;$psi.Arguments=($parts -join ' ');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;if(-not $p.Start()){throw "Cannot start $scriptPath"};return $p
}
function Write-JsonFile([string]$path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
$tmp=Join-Path $env:TEMP ('RFT-v142-perf-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tmp -Force|Out-Null
$report=[ordered]@{schemaVersion=1;generatedAt=(Get-Date).ToString('o');runner=$env:RUNNER_NAME;os=$env:RUNNER_OS;scan=$null;ping=$null}
try{
  $targets=@();1..254|ForEach-Object{$targets+="127.0.0.$_"}
  $cfg=Join-Path $tmp 'scan.json';$state=Join-Path $tmp 'state.json';$cancel=Join-Path $tmp 'cancel.flag'
  Write-JsonFile $cfg ([ordered]@{schemaVersion=3;RunId='perf-scan';Targets=$targets;Profile='FAST';LocalIP='127.0.0.1';LocalMAC='02-00-00-00-00-01';InterfaceIndex=1;FastPingTimeoutMs=100;RetryEnabled=$false;RetryPingTimeoutMs=300;PingConcurrency=128;ArpConcurrency=64;DiscoveryDurationSec=0;DiscoveryMode='FAST'})
  $sw=[Diagnostics.Stopwatch]::StartNew();$p=Start-HiddenPs $scanWorker @('-ConfigFile',('"'+$cfg+'"'),'-StateFile',('"'+$state+'"'),'-CancelFile',('"'+$cancel+'"'))
  try{$exited=$p.WaitForExit($ScanBudgetMs+5000);$sw.Stop();Assert-True $exited 'FAST synthetic /24 process exits';if(-not $exited){try{$p.Kill()}catch{}}}finally{try{$p.Dispose()}catch{}}
  Assert-True (Wait-Path $state 2000) 'FAST synthetic /24 state exists'
  if(Test-Path $state){
    $s=[IO.File]::ReadAllText($state)|ConvertFrom-Json
    $elapsed=[int64]$s.elapsedMs
    Assert-True ([bool]$s.complete -and -not [string]$s.error) 'FAST synthetic /24 completes cleanly'
    Assert-True ([int]$s.total -eq 254) 'FAST synthetic /24 covers 254 targets'
    Assert-True (-not [bool]$s.metrics.RetryEnabled) 'FAST synthetic /24 retry remains disabled'
    Assert-True ($elapsed -le $ScanBudgetMs) "FAST synthetic /24 <= ${ScanBudgetMs}ms"
    $report.scan=[ordered]@{targets=[int]$s.total;elapsedMs=$elapsed;budgetMs=$ScanBudgetMs;online=[int]$s.online;seen=[int]$s.seen;effectivePingConcurrency=[int]$s.metrics.EffectivePingConcurrency;effectiveArpConcurrency=[int]$s.metrics.EffectiveArpConcurrency}
  }
  $ipc=Join-Path $tmp 'ping';New-Item -ItemType Directory -Path $ipc -Force|Out-Null
  $session='perf-'+[guid]::NewGuid().ToString('N');$parentTicks=[long](Get-Process -Id $PID).StartTime.Ticks
  $pw=Start-HiddenPs $pingWorker @('-IpcDir',('"'+$ipc+'"'),'-SessionId',$session,'-ParentPid',[string]$PID,'-ParentStartTicks',[string]$parentTicks,'-DefaultConcurrency','64')
  try{
    Assert-True (Wait-Path (Join-Path $ipc 'worker-state.json') 5000) 'Performance PingWorker heartbeat'
    $pt=@();1..128|ForEach-Object{$pt += [ordered]@{Target="127.0.0.$_";Alias="Loop $_"}}
    $id='perf-ping';$req=[ordered]@{schemaVersion=1;sessionId=$session;requestId=$id;kind='PING_ALL';timeoutMs=500;concurrency=64;targets=$pt}
    $pingSw=[Diagnostics.Stopwatch]::StartNew();Write-JsonFile (Join-Path $ipc ("request-$id.json")) $req
    $rp=Join-Path $ipc ("result-$id.json");$have=Wait-Path $rp $PingBudgetMs;$pingSw.Stop()
    Assert-True $have 'PingWorker 128-target result exists'
    if($have){$r=[IO.File]::ReadAllText($rp)|ConvertFrom-Json;$rows=@($r.results);Assert-True ($rows.Count -eq 128) 'PingWorker returns 128 results';Assert-True (@($rows|Where-Object {-not [bool]$_.Success}).Count -eq 0) 'PingWorker 128 loopback targets all succeed';Assert-True ($pingSw.ElapsedMilliseconds -le $PingBudgetMs) "PingWorker 128 targets <= ${PingBudgetMs}ms";$report.ping=[ordered]@{targets=128;elapsedMs=[int64]$pingSw.ElapsedMilliseconds;budgetMs=$PingBudgetMs;success=@($rows|Where-Object {[bool]$_.Success}).Count}}
  } finally {[IO.File]::WriteAllText((Join-Path $ipc 'stop.flag'),'stop',[Text.Encoding]::ASCII);try{if(-not $pw.WaitForExit(3000)){$pw.Kill()}}catch{};try{$pw.Dispose()}catch{}}
  [IO.File]::WriteAllText((Join-Path $artifactDir 'performance-v1.4.2.json'),($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
} finally {Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
if($fail.Count){Write-Host ("FAILED: "+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL WINDOWS PERFORMANCE QUALIFICATION TESTS PASSED' -ForegroundColor Green
exit 0
