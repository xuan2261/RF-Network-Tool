param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$main=Join-Path $root 'RF-Network-Tool-Portable.ps1'
$launcher=Join-Path $root 'RF-Network-Tool-Launcher.ps1'
$nameWorker=Join-Path $root 'RF-Network-Tool-DiscoveryWorker.ps1'
$scanWorker=Join-Path $root 'RF-Network-Tool-ScanWorker.ps1'
$pingWorker=Join-Path $root 'RF-Network-Tool-PingWorker.ps1'
$taskWorker=Join-Path $root 'RF-Network-Tool-TaskWorker.ps1'
$qualification=Join-Path $root 'RF-Network-Tool-RealMachineQualification.ps1'
$routePlanner=Join-Path $root 'RF-Network-Tool-RoutePlanner.ps1'
$deepUiE2e=Join-Path $root 'tests\WINDOWS_DEEP_UI_E2E_v1_5_2.ps1'
$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$condition,[string]$name){if($condition){Write-Host "PASS $name" -ForegroundColor Green}else{Write-Host "FAIL $name" -ForegroundColor Red;[void]$fail.Add($name)}}
function Wait-Path([string]$path,[int]$timeoutMs=7000){$sw=[Diagnostics.Stopwatch]::StartNew();while($sw.ElapsedMilliseconds -lt $timeoutMs){if(Test-Path -LiteralPath $path){return $true};Start-Sleep -Milliseconds 80};return $false}
function Start-HiddenPs([string]$scriptPath,[string[]]$argumentList){
  $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $parts=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'))+$argumentList
  $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$psExe;$psi.Arguments=($parts -join ' ');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  $proc=New-Object Diagnostics.Process;$proc.StartInfo=$psi;if(-not $proc.Start()){throw "Cannot start $scriptPath"};return $proc
}
function Invoke-BoundedPs([string]$scriptPath,[string[]]$argumentList,[int]$timeoutMs,[string]$label){
  $proc=Start-HiddenPs $scriptPath $argumentList
  $exited=$false
  try{
    $exited=$proc.WaitForExit($timeoutMs)
    Assert-True $exited ($label+" exits within "+$timeoutMs+"ms")
    if(-not $exited){try{$proc.Kill()}catch{};try{$proc.WaitForExit(2000)}catch{};return 124}
    return [int]$proc.ExitCode
  } finally {
    try{$proc.Dispose()}catch{}
  }
}
Assert-True ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) 'Windows PowerShell 5.1 runtime'
foreach($spec in @(@('Main',$main),@('Launcher',$launcher),@('DiscoveryWorker',$nameWorker),@('ScanWorker',$scanWorker),@('PingWorker',$pingWorker),@('TaskWorker',$taskWorker),@('RoutePlanner',$routePlanner),@('RealMachineQualification',$qualification),@('DeepUiE2E',$deepUiE2e))){
  $tokens=$null;$parseErrors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($spec[1],[ref]$tokens,[ref]$parseErrors)
  Assert-True (-not $parseErrors -or $parseErrors.Count -eq 0) ("Parser "+$spec[0])
  if($parseErrors){foreach($pe in $parseErrors){Write-Host ("  line {0}: {1}" -f $pe.Extent.StartLineNumber,$pe.Message)}}
}

$mainText=[IO.File]::ReadAllText($main)
Assert-True ($mainText.Contains('function Repair-ScanGridIndex') -and $mainText.Contains('function Finalize-PingRequest')) 'Runtime integrity helpers present'
Assert-True ($mainText.Contains("'PENDING'") -and $mainText.Contains("'WAITING'") -and $mainText.Contains("'ENGINE ERROR'")) 'Monitoring engine-state UI markers present'
Assert-True ($mainText.Contains("History (MAC match)") -and $mainText.Contains('LastNameSource') -and -not $mainText.Contains("if($h.LastIP -eq $ip -and $h.LastName)")) 'History naming is MAC-bound and provenance-gated'
Assert-True ($mainText.Contains('$deepState=[pscustomobject]@') -and $mainText.Contains('StartupTimeoutSec=12') -and $mainText.Contains('Deep worker không phát heartbeat')) 'Deep UI worker uses shared state and startup watchdog'
Assert-True ($mainText.Contains('RFT_DEEP_UI_E2E') -and $mainText.Contains("Write-DeepUiE2eResult 'PASS' 'completed'") -and (Test-Path -LiteralPath $deepUiE2e)) 'Deep UI regression hook and bounded E2E harness present'
Assert-True ($mainText.Contains("@('MonSamples','OK/TOTAL',8)") -and $mainText.Contains("@('MonLastSample','LAST SAMPLE',10)") -and $mainText.Contains('MonitoringSessionStartedAt')) 'Monitoring exposes sample auditability and session horizon'
Assert-True ($mainText.Contains('$script:MonitoringEvents|Sort-Object At -Descending') -and -not $mainText.Contains('$script:MonitoringEvents|Select-Object -Last 200')) 'Monitoring grid renders the full retained timeline'

# Launcher diagnostic: exercises the real launcher, STA, WinForms load, parser sweep and data-dir bootstrap.
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$diag=& $psExe -STA -NoProfile -ExecutionPolicy Bypass -File $launcher -Diagnostic 2>&1
Assert-True ($LASTEXITCODE -eq 0) 'Launcher diagnostic exit 0'
Assert-True (([string]($diag -join "`n")) -match 'PASS: PowerShell/STA/WinForms') 'Launcher diagnostic reports PASS'
$tmp=Join-Path $env:TEMP ('RFT-v142-test-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tmp -Force|Out-Null
try{
  # Scan worker: all adaptive profiles on loopback.
  foreach($scanMode in @('FAST','BALANCED','DEEP')){
    $runId='scan-'+$scanMode.ToLowerInvariant()+'-'+[guid]::NewGuid().ToString('N')
    $config=Join-Path $tmp ("scan-$scanMode.json");$state=Join-Path $tmp ("state-$scanMode.json");$cancel=Join-Path $tmp ("cancel-$scanMode.flag");$log=Join-Path $tmp ("scan-$scanMode.log")
    $retry=($scanMode -ne 'FAST');$duration=if($scanMode -eq 'FAST'){8}elseif($scanMode -eq 'DEEP'){45}else{20}
    $cfg=[ordered]@{schemaVersion=3;RunId=$runId;Targets=@('127.0.0.1');Profile=$scanMode;LocalIP='127.0.0.1';LocalMAC='02-00-00-00-00-01';InterfaceIndex=1;FastPingTimeoutMs=250;RetryEnabled=$retry;RetryPingTimeoutMs=700;PingConcurrency=8;ArpConcurrency=4;DiscoveryDurationSec=$duration;DiscoveryMode=$scanMode}
    [IO.File]::WriteAllText($config,($cfg|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($true)))
    $scanRc=Invoke-BoundedPs $scanWorker @('-ConfigFile',('"'+$config+'"'),'-StateFile',('"'+$state+'"'),'-CancelFile',('"'+$cancel+'"'),'-LogFile',('"'+$log+'"')) 20000 ("Scan worker "+$scanMode)
    Assert-True ($scanRc -eq 0) "Scan worker exit 0 $scanMode"
    Assert-True (Test-Path $state) "Scan state $scanMode"
    if(Test-Path $state){$s=[IO.File]::ReadAllText($state)|ConvertFrom-Json;Assert-True ([int]$s.schemaVersion -eq 3) "State schema v3 $scanMode";Assert-True ([string]$s.runId -eq $runId) "State runId $scanMode";Assert-True ([string]$s.profile -eq $scanMode) "State profile $scanMode";Assert-True ([bool]$s.complete) "Complete $scanMode";Assert-True (-not [string]$s.error) "No error $scanMode";Assert-True (@($s.results|Where-Object {$_.IP -eq '127.0.0.1'}).Count -eq 1) "Loopback discovered $scanMode";Assert-True ($s.metrics.PSObject.Properties['PhaseElapsedMs'] -and $s.metrics.PhaseElapsedMs.PSObject.Properties['icmp-fast'] -and $s.metrics.PhaseElapsedMs.PSObject.Properties['arp-active']) "Phase timings present $scanMode"}
  }

  # Discovery worker: profile/run identity and cache schema.
  $targets=Join-Path $tmp 'targets.json';$cache=Join-Path $tmp 'discovery-cache.json';$dlog=Join-Path $tmp 'discovery.log';$discRun='disc-'+[guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($targets,(@([pscustomobject]@{IP='127.0.0.1';CurrentName='';CurrentSource='Unknown';Status='Online'})|ConvertTo-Json -Depth 3),(New-Object Text.UTF8Encoding($true)))
  $discRc=Invoke-BoundedPs $nameWorker @('-TargetsFile',('"'+$targets+'"'),'-CacheFile',('"'+$cache+'"'),'-RunId',$discRun,'-DurationSec','5','-DiscoveryProfile','FAST','-Gateway','""','-LocalIP','127.0.0.1','-LogFile',('"'+$dlog+'"')) 20000 'Discovery worker'
  Assert-True ($discRc -eq 0) 'Discovery worker exit 0'
  Assert-True (Test-Path $cache) 'FAST discovery cache exists'
  if(Test-Path $cache){$dc=[IO.File]::ReadAllText($cache)|ConvertFrom-Json;Assert-True ([int]$dc.schemaVersion -eq 4) 'Discovery schema v4';Assert-True ([string]$dc.runId -eq $discRun) 'Discovery runId';Assert-True ([string]$dc.profile -eq 'FAST') 'Discovery profile FAST'}

  # Persistent Ping Worker: real async loopback request through IPC.
  $ipc=Join-Path $tmp 'ping-ipc';New-Item -ItemType Directory -Path $ipc -Force|Out-Null
  $session='sess-'+[guid]::NewGuid().ToString('N');$parentTicks=[long](Get-Process -Id $PID).StartTime.Ticks
  $pingProc=Start-HiddenPs $pingWorker @('-IpcDir',('"'+$ipc+'"'),'-SessionId',$session,'-ParentPid',[string]$PID,'-ParentStartTicks',[string]$parentTicks,'-DefaultConcurrency','4')
  try{
    Assert-True (Wait-Path (Join-Path $ipc 'worker-state.json') 5000) 'Ping worker heartbeat created'
    $requestId='req-'+[guid]::NewGuid().ToString('N');$request=[ordered]@{schemaVersion=1;sessionId=$session;requestId=$requestId;kind='PING_SINGLE';timeoutMs=1000;concurrency=2;targets=@([ordered]@{Target='127.0.0.1';Alias='Loopback'})}
    [IO.File]::WriteAllText((Join-Path $ipc ("request-$requestId.json")),($request|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
    $resultPath=Join-Path $ipc ("result-$requestId.json");Assert-True (Wait-Path $resultPath 7000) 'Ping worker result created'
    if(Test-Path $resultPath){$pr=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json;Assert-True ([string]$pr.sessionId -eq $session) 'Ping result session';Assert-True ([string]$pr.requestId -eq $requestId) 'Ping result requestId';$row=@($pr.results|Select-Object -First 1);Assert-True ($row.Count -eq 1 -and [bool]$row[0].Success) 'Async loopback ping success'}
    $monitorRequestId='mon-'+[guid]::NewGuid().ToString('N');$monitorRequest=[ordered]@{schemaVersion=1;sessionId=$session;requestId=$monitorRequestId;kind='MONITOR';timeoutMs=1000;concurrency=2;targets=@([ordered]@{Target='127.0.0.1';Alias='Loopback Monitor'})}
    [IO.File]::WriteAllText((Join-Path $ipc ("request-$monitorRequestId.json")),($monitorRequest|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
    $monitorResultPath=Join-Path $ipc ("result-$monitorRequestId.json");Assert-True (Wait-Path $monitorResultPath 7000) 'Monitoring ping result created'
    if(Test-Path $monitorResultPath){$mpr=[IO.File]::ReadAllText($monitorResultPath)|ConvertFrom-Json;Assert-True ([string]$mpr.kind -eq 'MONITOR') 'Monitoring ping kind preserved';$mrow=@($mpr.results|Select-Object -First 1);Assert-True ($mrow.Count -eq 1 -and [bool]$mrow[0].Success) 'Monitoring loopback ping success'}

    # Request-level worker failure must emit an ERROR payload with empty results, then the persistent worker must continue serving requests.
    $badId='bad-'+[guid]::NewGuid().ToString('N');$badReq=[ordered]@{schemaVersion=1;sessionId=$session;requestId=$badId;kind='PING_SINGLE';timeoutMs='not-an-integer';concurrency=2;targets=@([ordered]@{Target='127.0.0.1';Alias='Bad fixture'})}
    [IO.File]::WriteAllText((Join-Path $ipc ("request-$badId.json")),($badReq|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
    $badPath=Join-Path $ipc ("result-$badId.json");Assert-True (Wait-Path $badPath 7000) 'Ping worker request-level error result created'
    if(Test-Path $badPath){$br=[IO.File]::ReadAllText($badPath)|ConvertFrom-Json;Assert-True ([string]$br.kind -eq 'ERROR') 'Ping worker request-level error kind';Assert-True (@($br.results).Count -eq 0) 'Ping worker request-level error empty result contract'}
    $afterId='after-'+[guid]::NewGuid().ToString('N');$afterReq=[ordered]@{schemaVersion=1;sessionId=$session;requestId=$afterId;kind='PING_SINGLE';timeoutMs=1000;concurrency=2;targets=@([ordered]@{Target='127.0.0.1';Alias='After error'})}
    [IO.File]::WriteAllText((Join-Path $ipc ("request-$afterId.json")),($afterReq|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
    $afterPath=Join-Path $ipc ("result-$afterId.json");Assert-True (Wait-Path $afterPath 7000) 'Ping worker continues after request-level error'
    if(Test-Path $afterPath){$ar=[IO.File]::ReadAllText($afterPath)|ConvertFrom-Json;$arow=@($ar.results|Select-Object -First 1);Assert-True ($arow.Count -eq 1 -and [bool]$arow[0].Success) 'Ping worker post-error loopback success'}
  } finally {[IO.File]::WriteAllText((Join-Path $ipc 'stop.flag'),'stop',[Text.Encoding]::ASCII);try{if(-not $pingProc.WaitForExit(3000)){$pingProc.Kill()}}catch{};try{$pingProc.Dispose()}catch{}}

  # OUI Task Worker: deterministic local CSV fixture -> compact cache.
  $ouiDir=Join-Path $tmp 'oui';New-Item -ItemType Directory -Path $ouiDir -Force|Out-Null
  $csv='Registry,Assignment,Organization Name,Organization Address'+"`r`n"+'MA-L,001122,Vendor A,Test'+"`r`n"
  [IO.File]::WriteAllText((Join-Path $ouiDir 'oui.csv'),$csv,[Text.Encoding]::UTF8);[IO.File]::WriteAllText((Join-Path $ouiDir 'mam.csv'),('Registry,Assignment,Organization Name,Organization Address'+"`r`n"+'MA-M,0011223,Vendor B,Test'+"`r`n"),[Text.Encoding]::UTF8);[IO.File]::WriteAllText((Join-Path $ouiDir 'oui36.csv'),('Registry,Assignment,Organization Name,Organization Address'+"`r`n"+'MA-S,001122334,Vendor C,Test'+"`r`n"),[Text.Encoding]::UTF8)
  $taskSession='task-'+[guid]::NewGuid().ToString('N');$taskRun='oui-'+[guid]::NewGuid().ToString('N');$taskCfg=Join-Path $tmp 'task-oui.json';$taskRes=Join-Path $tmp 'task-oui-result.json';$taskHb=Join-Path $tmp 'task-oui-hb.json';$ouiCache=Join-Path $tmp 'oui-cache.tsv'
  [IO.File]::WriteAllText($taskCfg,([ordered]@{schemaVersion=1;sessionId=$taskSession;runId=$taskRun;ouiDir=$ouiDir;cacheFile=$ouiCache}|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($true)))
  $ouiRc=Invoke-BoundedPs $taskWorker @('-Mode','OUI_BUILD_CACHE','-ConfigFile',('"'+$taskCfg+'"'),'-ResultFile',('"'+$taskRes+'"'),'-SessionId',$taskSession,'-RunId',$taskRun,'-ParentPid',[string]$PID,'-ParentStartTicks',[string]$parentTicks,'-HeartbeatFile',('"'+$taskHb+'"')) 20000 'OUI task worker'
  Assert-True ($ouiRc -eq 0) 'OUI task worker exit 0'
  Assert-True (Test-Path $taskRes) 'OUI task result exists';Assert-True (Test-Path $ouiCache) 'OUI compact cache exists'
  if(Test-Path $taskRes){$or=[IO.File]::ReadAllText($taskRes)|ConvertFrom-Json;Assert-True ([bool]$or.success) 'OUI task success';Assert-True ([int]$or.count -eq 3) 'OUI task parsed three fixture assignments'}
  if(Test-Path $ouiCache){$cacheText=[IO.File]::ReadAllText($ouiCache);Assert-True ($cacheText -match '6\t001122\tVendor A') 'OUI MA-L cache record';Assert-True ($cacheText -match '7\t0011223\tVendor B') 'OUI MA-M cache record';Assert-True ($cacheText -match '9\t001122334\tVendor C') 'OUI MA-S cache record'}

  # DEEP Task Worker: loopback completes with bounded result schema.
  $deepRun='deep-'+[guid]::NewGuid().ToString('N');$deepCfg=Join-Path $tmp 'deep.json';$deepRes=Join-Path $tmp 'deep-result.json';$deepHb=Join-Path $tmp 'deep-hb.json'
  [IO.File]::WriteAllText($deepCfg,([ordered]@{schemaVersion=1;sessionId=$taskSession;runId=$deepRun;interfaceIndex=0;device=[ordered]@{IP='127.0.0.1';MAC='';Brand='';Model='';Type='This PC';Name='Loopback';OS='Windows'}}|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
  $deepRc=Invoke-BoundedPs $taskWorker @('-Mode','DEEP','-ConfigFile',('"'+$deepCfg+'"'),'-ResultFile',('"'+$deepRes+'"'),'-SessionId',$taskSession,'-RunId',$deepRun,'-ParentPid',[string]$PID,'-ParentStartTicks',[string]$parentTicks,'-HeartbeatFile',('"'+$deepHb+'"')) 60000 'DEEP task worker'
  Assert-True ($deepRc -eq 0) 'DEEP task worker exit 0'
  Assert-True (Test-Path $deepRes) 'DEEP task result exists'
  if(Test-Path $deepRes){$dr=[IO.File]::ReadAllText($deepRes)|ConvertFrom-Json;Assert-True ([bool]$dr.success) 'DEEP task success';Assert-True ($dr.deep -ne $null) 'DEEP payload present';Assert-True (@($dr.deep.PortChecks).Count -ge 10) 'DEEP common port checks returned'}

  # Monitoring persistence contracts.
  $monEntries=@();1..50|ForEach-Object{$monEntries += [pscustomobject]@{Target="192.168.77.$_";Name="Monitor $_";Enabled=($_ % 2 -eq 0);IntervalSec=5;Alert=$false}}
  $monRound=([ordered]@{schemaVersion=1;entries=$monEntries}|ConvertTo-Json -Depth 5)|ConvertFrom-Json
  Assert-True (@($monRound.entries).Count -eq 50) 'Monitoring config round-trip 50 rows'
  $events=@();1..520|ForEach-Object{$events += [pscustomobject]@{At=(Get-Date).AddSeconds($_).ToString('o');Target='127.0.0.1';Name='Loopback';From='ONLINE';To='OFFLINE';LatencyMs=$null;Detail='test'}}
  while($events.Count -gt 500){$events=@($events|Select-Object -Skip 1)}
  Assert-True ($events.Count -eq 500) 'Monitoring timeline retention 500 events'

  # Persistence and lock primitives.
  $entries=@();1..50|ForEach-Object{$entries += [pscustomobject]@{Target="192.168.55.$_";Name="Device $_"}};$round=([ordered]@{schemaVersion=2;targets=$entries}|ConvertTo-Json -Depth 5)|ConvertFrom-Json;Assert-True (@($round.targets).Count -eq 50) 'Target schema v2 round-trip 50 rows'
  $lock=Join-Path $tmp 'instance.lock';$a=[IO.File]::Open($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$blocked=$false;try{$b=[IO.File]::Open($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$b.Dispose()}catch [IO.IOException]{$blocked=$true}finally{$a.Dispose()};Assert-True $blocked 'Exclusive instance-file lock primitive'
} finally {Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue}
$vbs=Join-Path $root 'START-RF-NETWORK-TOOL.vbs';$bytes=[IO.File]::ReadAllBytes($vbs);$noBom=-not($bytes.Length-ge 3 -and $bytes[0]-eq 0xEF -and $bytes[1]-eq 0xBB -and $bytes[2]-eq 0xBF);Assert-True $noBom 'VBS no UTF-8 BOM'
if($fail.Count){Write-Host "`nFAILED: $($fail -join ', ')" -ForegroundColor Red;exit 1};Write-Host "`nALL WINDOWS INTEGRATION TESTS PASSED" -ForegroundColor Green;exit 0