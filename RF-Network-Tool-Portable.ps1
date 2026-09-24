Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$BaseDir = if ($env:RFT_BASEDIR -and (Test-Path -LiteralPath $env:RFT_BASEDIR)) { $env:RFT_BASEDIR } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$VersionFile = Join-Path $BaseDir 'VERSION'
if (-not (Test-Path -LiteralPath $VersionFile)) { throw "Không tìm thấy VERSION: $VersionFile" }
$AppVersion = ([IO.File]::ReadAllText($VersionFile)).Trim()
if ($AppVersion -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION không hợp lệ: $AppVersion" }
$DataDir = if ($env:RFT_DATADIR -and (Test-Path -LiteralPath $env:RFT_DATADIR)) { $env:RFT_DATADIR } else { $BaseDir }
# Self-heal when the main script is launched directly from a read-only folder (normally the launcher already handles this).
try {
    if (-not (Test-Path -LiteralPath $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir -Force -ErrorAction Stop) }
    $probe=Join-Path $DataDir ('.rft-main-write-test-'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($probe,'ok',[Text.Encoding]::ASCII);Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
} catch {
    $fallback=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if(-not [string]::IsNullOrWhiteSpace($fallback)){$DataDir=Join-Path $fallback 'RF-Network-Tool';try{if(-not(Test-Path -LiteralPath $DataDir)){[void](New-Item -ItemType Directory -Path $DataDir -Force -ErrorAction Stop)}}catch{}}
}

$TargetsFile = Join-Path $DataDir 'RF-Network-Tool.targets.txt'
$TargetsJsonFile = Join-Path $DataDir 'RF-Network-Tool.targets.json'
$OuiDir = Join-Path $DataDir 'oui-data'
$DeviceHistoryFile = Join-Path $DataDir 'RF-Network-Tool.device-history.json'
$ScanHistoryFile = Join-Path $DataDir 'RF-Network-Tool.scan-history.json'
$MonitoringConfigFile = Join-Path $DataDir 'RF-Network-Tool.monitoring.json'
$MonitoringHistoryFile = Join-Path $DataDir 'RF-Network-Tool.monitoring-history.json'
$DiscoveryWorkerScript = Join-Path $BaseDir 'RF-Network-Tool-DiscoveryWorker.ps1'
$ScanWorkerScript = Join-Path $BaseDir 'RF-Network-Tool-ScanWorker.ps1'
$PingWorkerScript = Join-Path $BaseDir 'RF-Network-Tool-PingWorker.ps1'
$TaskWorkerScript = Join-Path $BaseDir 'RF-Network-Tool-TaskWorker.ps1'
$RoutePlannerScript = Join-Path $BaseDir 'RF-Network-Tool-RoutePlanner.ps1'
if(-not (Test-Path -LiteralPath $RoutePlannerScript)){throw "Không tìm thấy Route Planner: $RoutePlannerScript"}
. $RoutePlannerScript
$OuiCacheFile = Join-Path $DataDir 'RF-Network-Tool.oui-prefix-cache.v1.tsv'
# Transient worker IPC files are session-scoped so an orphan worker from a crashed
# previous GUI cannot overwrite the current scan/name-discovery state.
$RuntimeSessionId = [guid]::NewGuid().ToString('N')
$DiscoveryCacheFile = Join-Path $DataDir ("RF-Network-Tool.discovery-cache.$RuntimeSessionId.idle.json")
$DiscoveryTargetsFile = Join-Path $DataDir ("RF-Network-Tool.discovery-targets.$RuntimeSessionId.idle.json")
$ScanConfigFile = Join-Path $DataDir ("RF-Network-Tool.scan-config.$RuntimeSessionId.idle.json")
$ScanStateFile = Join-Path $DataDir ("RF-Network-Tool.scan-state.$RuntimeSessionId.idle.json")
$ScanCancelFile = Join-Path $DataDir ("RF-Network-Tool.scan-cancel.$RuntimeSessionId.idle.flag")
$PingIpcDir = Join-Path $DataDir ("RF-Network-Tool.ping.$RuntimeSessionId")
$PingStopFile = Join-Path $PingIpcDir 'stop.flag'
$PingHeartbeatFile = Join-Path $PingIpcDir 'worker-state.json'
$RuntimeLogDir = Join-Path $DataDir 'logs'
try { if (-not (Test-Path -LiteralPath $RuntimeLogDir)) { [void](New-Item -ItemType Directory -Path $RuntimeLogDir -Force) } } catch { }
$RuntimeLogFile = Join-Path $RuntimeLogDir ("runtime-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
$script:DeepUiE2eMode = ([string]$env:RFT_DEEP_UI_E2E -eq '1')
$script:DeepUiE2eResultFile = ([string]$env:RFT_DEEP_UI_E2E_RESULT).Trim()
$script:DeepUiE2eLaunchState = [pscustomobject]@{Timer=$null;Row=$null}

$script:TargetRows = @{}
$script:TargetSchemaVersion = 2
$script:Adapters = @()
$script:UdpClient = $null
$script:UdpFilterIPs = @()
$script:LastUdpPacket = ''
$script:ScanCancel = $false
$script:ScanActive = $false
$script:OuiUpdateActive = $false
$script:PingAllBusy = $false
$script:RfPingBusy = $false
$script:PingWorkerProcess = $null
$script:PingRequests = @{}
$script:PingTargetBusy = @{}
$script:PingLatestRequest = @{}
$script:PingWorkerStartedAt = $null
$script:PingWorkerLastHeartbeat = $null
$script:OuiTaskProcess = $null
$script:OuiTaskRunId = ''
$script:OuiTaskResultFile = ''
$script:OuiTaskHeartbeatFile = ''
$script:OuiTaskConfigFile = ''
$script:OuiCacheReader = $null
$script:OuiCacheLoadCount = 0
$script:OuiCacheLoadActive = $false
$script:ScanResults = @()
$script:ScanRecordByIp = @{}
$script:ScanProcess = $null
$script:ScanRowByIp = @{}
$script:ScanStateSignature = ''
$script:ScanRunId = ''
$script:ScanLogFile = ''
$script:ScanContext = $null
$script:OuiDb6 = @{}
$script:OuiDb7 = @{}
$script:OuiDb9 = @{}
$script:DeviceHistory = @{}
$script:ScanHistory = @()
$script:CurrentScanProfile = 'BALANCED'
$script:CurrentScanStartedAt = $null
$script:CurrentScanCoreElapsedMs = 0
$script:MainForm = $null
$script:DiscoverySnapshotReady = $false
$script:MdnsNameCache = @{}
$script:SsdpNameCache = @{}
$script:DiscoveryProcess = $null
$script:DiscoveryStartedAt = $null
$script:DiscoveryDurationSec = 45
$script:DiscoveryAppliedCount = 0
$script:DiscoveryRunId = ''
$script:HandlingUiException = $false
$script:ThreadExceptionHandler = $null
$script:DomainExceptionHandler = $null
$script:MonitoringConfig = @{}
$script:MonitoringStats = @{}
$script:MonitoringEvents = New-Object System.Collections.Generic.List[object]
$script:MonitoringMaxEvents = 500
$script:MonitoringLoaded = $false
$script:MonitoringLastUiRefresh = $null
$script:MonitoringSchedulerBusy = $false
$script:MonitoringGridUpdating = $false
$script:MonitoringSessionStartedAt = Get-Date

function Write-RuntimeLog([string]$area, [string]$message) {
    try {
        $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))] [$area] $message"
        [System.IO.File]::AppendAllText($RuntimeLogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Write-TextAtomic([string]$path, [string]$text, [System.Text.Encoding]$encoding = $null) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'Đường dẫn ghi dữ liệu bị trống.' }
    if ($null -eq $encoding) { $encoding = New-Object System.Text.UTF8Encoding($true) }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, [string]$text, $encoding)
        if (Test-Path -LiteralPath $path) {
            try { [System.IO.File]::Replace($tmp, $path, $null); return } catch { }
        }
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-DeepUiE2eResult([string]$status,[string]$stage,[string]$detail,[object]$deepState=$null) {
    if(-not $script:DeepUiE2eMode -or [string]::IsNullOrWhiteSpace($script:DeepUiE2eResultFile)){return}
    try {
        $payload=[ordered]@{
            schemaVersion=1
            status=$status
            stage=$stage
            detail=$detail
            recordedAt=(Get-Date).ToString('o')
            workerCompleted=if($deepState){[bool]$deepState.Completed}else{$false}
            workerSucceeded=if($deepState){[bool]$deepState.Succeeded}else{$false}
            lastPhase=if($deepState){[string]$deepState.LastPhase}else{''}
            lastError=if($deepState){[string]$deepState.LastError}else{''}
        }
        Write-TextAtomic $script:DeepUiE2eResultFile (ConvertTo-Json -InputObject $payload -Depth 4)
    } catch { Write-RuntimeLog 'DEEP-UI-E2E' ($_ | Out-String) }
}

function Remove-TransientRuntimeFiles {
    foreach($path in @($DiscoveryCacheFile,$DiscoveryTargetsFile,$ScanConfigFile,$ScanStateFile,$ScanCancelFile)) {
        if([string]::IsNullOrWhiteSpace([string]$path)){continue}
        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
        try { Get-ChildItem -LiteralPath $DataDir -Filter ((Split-Path -Leaf $path)+'.*.tmp') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    }
    try { Get-ChildItem -LiteralPath $DataDir -Filter ("RF-Network-Tool.*.$RuntimeSessionId.*") -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    try { if(Test-Path -LiteralPath $PingIpcDir){Remove-Item -LiteralPath $PingIpcDir -Recurse -Force -ErrorAction SilentlyContinue} } catch { }
}

function Backup-CorruptDataFile([string]$path, [string]$area) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return '' }
        $backup = "$path.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        Copy-Item -LiteralPath $path -Destination $backup -Force -ErrorAction Stop
        Write-RuntimeLog $area "Backed up unreadable data file to: $backup"
        return $backup
    } catch { Write-RuntimeLog $area ("Backup failed: " + $_.Exception.Message); return '' }
}

function Read-JsonFileSafe([string]$path, [string]$area='DATA', [switch]$BackupOnError) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-RuntimeLog $area ("JSON read/parse failed for '$path': " + $_.Exception.Message)
        if ($BackupOnError) { [void](Backup-CorruptDataFile $path $area) }
        return @()
    }
}

function Set-ClipboardTextSafe([string]$text, [string]$context='Clipboard') {
    if ($null -eq $text) { $text = '' }
    for ($i=0; $i -lt 3; $i++) {
        try { [System.Windows.Forms.Clipboard]::SetText([string]$text); return $true }
        catch { if ($i -lt 2) { Start-Sleep -Milliseconds 80 } else { Write-RuntimeLog $context ($_ | Out-String) } }
    }
    try { [System.Windows.Forms.MessageBox]::Show('Không thể truy cập Clipboard. Hãy thử lại sau vài giây.',$context,'OK','Warning') | Out-Null } catch { }
    return $false
}

# Route otherwise-unhandled WinForms exceptions to a controlled handler instead of the .NET JIT dialog.
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    $script:ThreadExceptionHandler = [System.Threading.ThreadExceptionEventHandler]{
        param($source,$evt)
        if ($script:HandlingUiException) { return }
        $script:HandlingUiException = $true
        try {
            $ex = if ($evt -and $evt.Exception) { $evt.Exception } else { New-Object System.Exception('Unknown WinForms exception') }
            Write-RuntimeLog 'UI-UNHANDLED' ($ex.ToString())
            [System.Windows.Forms.MessageBox]::Show("Ứng dụng vừa chặn một lỗi giao diện ngoài dự kiến.`r`n`r`n$($ex.Message)`r`n`r`nChi tiết: $RuntimeLogFile`r`n`r`nNếu lỗi lặp lại, hãy đóng và mở lại tool.",'RF Network Tool - Runtime Error','OK','Error') | Out-Null
        } catch { } finally { $script:HandlingUiException = $false }
    }
    [System.Windows.Forms.Application]::add_ThreadException($script:ThreadExceptionHandler)
} catch { Write-RuntimeLog 'EXCEPTION-HANDLER' ("ThreadException setup failed: " + $_.Exception.Message) }

try {
    $script:DomainExceptionHandler = [System.UnhandledExceptionEventHandler]{
        param($source,$evt)
        try {
            $obj = $evt.ExceptionObject
            $msg = if ($obj -is [System.Exception]) { $obj.ToString() } else { [string]$obj }
            Write-RuntimeLog 'APPDOMAIN-UNHANDLED' ("Terminating=$($evt.IsTerminating) `r`n$msg")
        } catch { }
    }
    [System.AppDomain]::CurrentDomain.add_UnhandledException($script:DomainExceptionHandler)
} catch { Write-RuntimeLog 'EXCEPTION-HANDLER' ("AppDomain handler setup failed: " + $_.Exception.Message) }

[System.Windows.Forms.Application]::EnableVisualStyles()

function New-Font([float]$size = 9, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
    New-Object System.Drawing.Font('Segoe UI', $size, $style)
}

function Add-Log([System.Windows.Forms.TextBox]$box, [string]$text) {
    if(-not $box -or $box.IsDisposed){return}
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $box.AppendText("[$stamp] $text`r`n")
    # Bound GUI log memory; high-rate UDP traffic must not grow the TextBox forever.
    if($box.TextLength -gt 600000){
        $keep=[Math]::Min(450000,$box.TextLength)
        $box.Text=$box.Text.Substring($box.TextLength-$keep)
    }
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Get-SystemPowerShellPath {
    $p=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if(-not(Test-Path -LiteralPath $p)){throw "Không tìm thấy Windows PowerShell hệ thống: $p"}
    return $p
}

function Get-CurrentProcessStartTicks {
    try { return [long](Get-Process -Id $PID -ErrorAction Stop).StartTime.Ticks }
    catch { return [long]0 }
}

function Start-PingWorker {
    if($script:PingWorkerProcess -and -not $script:PingWorkerProcess.HasExited){return $true}
    if(-not(Test-Path -LiteralPath $PingWorkerScript)){Write-RuntimeLog 'PING-WORKER' "Missing worker: $PingWorkerScript";return $false}
    try {
        if(Test-Path -LiteralPath $PingIpcDir){Remove-Item -LiteralPath $PingIpcDir -Recurse -Force -ErrorAction SilentlyContinue}
        [void](New-Item -ItemType Directory -Path $PingIpcDir -Force -ErrorAction Stop)
        $ps=Get-SystemPowerShellPath
        $parentTicks=Get-CurrentProcessStartTicks
        $processArgs=@(
            '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
            '-File',"`"$PingWorkerScript`"",
            '-IpcDir',"`"$PingIpcDir`"",
            '-SessionId',$RuntimeSessionId,
            '-ParentPid',[string]$PID,
            '-ParentStartTicks',[string]$parentTicks,
            '-DefaultConcurrency','24'
        ) -join ' '
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$ps;$psi.Arguments=$processArgs;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
        $proc=New-Object Diagnostics.Process;$proc.StartInfo=$psi
        if(-not $proc.Start()){throw 'Không khởi động được Ping Worker.'}
        $script:PingWorkerProcess=$proc
        $script:PingWorkerStartedAt=Get-Date
        $script:PingWorkerLastHeartbeat=Get-Date
        Write-RuntimeLog 'PING-WORKER' "Started PID=$($proc.Id) IPC=$PingIpcDir"
        return $true
    } catch {
        Write-RuntimeLog 'PING-WORKER' ($_ | Out-String)
        $script:PingWorkerProcess=$null
        return $false
    }
}

function Stop-PingWorker {
    try { if(Test-Path -LiteralPath $PingIpcDir){[IO.File]::WriteAllText($PingStopFile,'stop',[Text.Encoding]::ASCII)} } catch { }
    if($script:PingWorkerProcess){
        try { if(-not $script:PingWorkerProcess.HasExited){if(-not $script:PingWorkerProcess.WaitForExit(1200)){try{$script:PingWorkerProcess.Kill()}catch{}}} } catch { }
        try{$script:PingWorkerProcess.Dispose()}catch{}
        $script:PingWorkerProcess=$null
    }
    $script:PingRequests=@{};$script:PingTargetBusy=@{};$script:PingLatestRequest=@{};$script:PingAllBusy=$false;$script:RfPingBusy=$false
}

function Fail-PendingPingRequests([string]$message='Ping worker stopped') {
    foreach($meta in @($script:PingRequests.Values)){
        foreach($t in @($meta.Targets)){
            $target=[string]$t.Target
            if([string]$meta.Kind -eq 'MONITOR'){
                try{
                    if($script:MonitoringStats.ContainsKey($target)){
                        $stat=$script:MonitoringStats[$target]
                        if($stat.LastResultAt){
                            $elapsed=((Get-Date)-[datetime]$stat.LastResultAt).TotalSeconds
                            if($elapsed -gt 0){if($stat.State -eq 'ONLINE'){$stat.UptimeSec+=$elapsed}elseif($stat.State -eq 'OFFLINE'){$stat.DowntimeSec+=$elapsed}}
                            # Freeze accounting while the monitoring engine itself is unavailable. A worker failure is not a network outage.
                            $stat.LastResultAt=$null
                        }
                        $stat.LastDetail="Worker error: $message"
                        Update-MonitorGridRow $target
                    }
                }catch{}
            } elseif($script:TargetRows.ContainsKey($target)){
                $row=Get-TargetGridRow $target
                if($row){$row.Cells['PingStatus'].Value="ERROR | $message";$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::Firebrick}
            }
        }
    }
    if($script:RfPingBusy -and $lblConn){$lblConn.Text="PING : ERROR | $message";$lblConn.ForeColor=[Drawing.Color]::Firebrick}
    $script:PingRequests=@{};$script:PingTargetBusy=@{};$script:PingLatestRequest=@{};$script:PingAllBusy=$false;$script:RfPingBusy=$false
    if($btnPingAll -and -not $btnPingAll.IsDisposed){$btnPingAll.Enabled=$true}
    if($btnRfPing -and -not $btnRfPing.IsDisposed){$btnRfPing.Enabled=$true}
}

function Enqueue-PingRequest([string]$kind,$targets,[int]$timeoutMs=1500,[int]$concurrency=24) {
    if(-not(Start-PingWorker)){throw 'Ping Worker không khởi động được.'}
    $list=@($targets | Where-Object {$_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Target)})
    if($list.Count -eq 0){return ''}
    $id=[guid]::NewGuid().ToString('N')
    $request=[ordered]@{
        schemaVersion=1;sessionId=$RuntimeSessionId;requestId=$id;kind=$kind;createdAt=(Get-Date).ToString('o');
        timeoutMs=[Math]::Max(50,[Math]::Min(10000,$timeoutMs));concurrency=[Math]::Max(1,[Math]::Min(64,$concurrency));
        targets=@($list | ForEach-Object {[ordered]@{Target=[string]$_.Target;Alias=[string]$_.Alias}})
    }
    $path=Join-Path $PingIpcDir ("request-$id.json")
    Write-TextAtomic $path (ConvertTo-Json -InputObject $request -Depth 6)
    $script:PingRequests[$id]=[pscustomobject]@{Kind=$kind;StartedAt=Get-Date;Targets=@($list)}
    foreach($t in $list){$targetKey=[string]$t.Target;$script:PingTargetBusy[$targetKey]=$id;if($kind -ne 'RF'){$script:PingLatestRequest[$targetKey]=$id}}
    return $id
}

function Set-TargetPingPending([string]$target) {
    $row=Get-TargetGridRow $target
    if($row){$row.Cells['PingStatus'].Value='Đang ping nền...';$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::DarkOrange}
}

function Set-PingTargetEngineError([string]$target,[string]$kind,[string]$message) {
    if([string]::IsNullOrWhiteSpace($target)){return}
    if([string]::IsNullOrWhiteSpace($message)){$message='Ping worker returned no result.'}
    if($kind -eq 'MONITOR'){
        try{
            if($script:MonitoringStats.ContainsKey($target)){
                $stat=$script:MonitoringStats[$target]
                $now=Get-Date
                if($stat.LastResultAt){
                    $elapsed=($now-[datetime]$stat.LastResultAt).TotalSeconds
                    if($elapsed -gt 0){if($stat.State -eq 'ONLINE'){$stat.UptimeSec+=$elapsed}elseif($stat.State -eq 'OFFLINE'){$stat.DowntimeSec+=$elapsed}}
                    # An engine failure is not evidence that the monitored device went offline.
                    $stat.LastResultAt=$null
                }
                $stat.LastScheduledAt=$null
                $stat.LastDetail="Engine error: $message"
                Update-MonitorGridRow $target
            }
        } catch {Write-RuntimeLog 'MONITOR-ENGINE-ERROR' ($_ | Out-String)}
        return
    }
    if($kind -eq 'RF'){
        $script:RfPingBusy=$false
        if($btnRfPing -and -not $btnRfPing.IsDisposed){$btnRfPing.Enabled=$true}
        if($lblConn){$lblConn.Text="PING : ERROR | $message";$lblConn.ForeColor=[Drawing.Color]::Firebrick}
        return
    }
    if($script:TargetRows.ContainsKey($target)){
        $entry=$script:TargetRows[$target]
        $statusText="ERROR | $message"
        $entry.Status=$statusText
        $row=Get-TargetGridRow $target
        if($null -ne $row){$row.Cells['PingStatus'].Value=$statusText;$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::Firebrick}
        Add-Log $pingLog "[$($entry.Alias)] $target -> $statusText"
    }
}

function Finalize-PingRequest([string]$requestId,$meta,[string]$kind,$completedTargets,[string]$workerError='') {
    if([string]::IsNullOrWhiteSpace($requestId)){return 0}
    if($null -eq $completedTargets){$completedTargets=@{}}
    $missing=0
    if($null -ne $meta){
        foreach($t in @($meta.Targets)){
            $target=([string]$t.Target).Trim()
            if([string]::IsNullOrWhiteSpace($target)){continue}
            $key=$target.ToLowerInvariant()
            $hasResult=$completedTargets.ContainsKey($key)
            $ownedByRequest=$false
            if($script:PingTargetBusy.ContainsKey($target) -and [string]$script:PingTargetBusy[$target] -eq $requestId){
                $script:PingTargetBusy.Remove($target);$ownedByRequest=$true
            }
            if($script:PingLatestRequest.ContainsKey($target) -and [string]$script:PingLatestRequest[$target] -eq $requestId){
                $script:PingLatestRequest.Remove($target);$ownedByRequest=$true
            }
            if(-not $hasResult -and $ownedByRequest){
                $detail=if(-not [string]::IsNullOrWhiteSpace($workerError)){$workerError}else{'Ping worker returned an incomplete result.'}
                Set-PingTargetEngineError $target $kind $detail
                $missing++
            }
        }
    }
    if($kind -eq 'PING_ALL'){$script:PingAllBusy=$false;if($btnPingAll -and -not $btnPingAll.IsDisposed){$btnPingAll.Enabled=$true}}
    if($kind -eq 'RF'){$script:RfPingBusy=$false;if($btnRfPing -and -not $btnRfPing.IsDisposed){$btnRfPing.Enabled=$true}}
    if($script:PingRequests.ContainsKey($requestId)){$script:PingRequests.Remove($requestId)}
    if(-not [string]::IsNullOrWhiteSpace($workerError)){Write-RuntimeLog 'PING-RESULT-ENGINE' "request=$requestId kind=$kind error=$workerError missing=$missing"}
    elseif($missing -gt 0){Write-RuntimeLog 'PING-RESULT-INCOMPLETE' "request=$requestId kind=$kind missing=$missing"}
    return $missing
}

function Apply-PingWorkerResults {
    if(-not(Test-Path -LiteralPath $PingIpcDir)){return 0}
    $applied=0
    foreach($file in @(Get-ChildItem -LiteralPath $PingIpcDir -Filter 'result-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)){
        try {
            $obj=[IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop
            if([string]$obj.sessionId -ne $RuntimeSessionId){continue}
            $requestId=[string]$obj.requestId
            $meta=if($script:PingRequests.ContainsKey($requestId)){$script:PingRequests[$requestId]}else{$null}
            $kind=if($null -ne $meta){[string]$meta.Kind}else{[string]$obj.kind}
            $completedTargets=@{}
            foreach($r in @($obj.results)){
                $target=([string]$r.Target).Trim()
                if([string]::IsNullOrWhiteSpace($target)){continue}
                $completedTargets[$target.ToLowerInvariant()]=$true
                if($kind -ne 'RF' -and $script:PingLatestRequest.ContainsKey($target) -and [string]$script:PingLatestRequest[$target] -ne $requestId){
                    Write-RuntimeLog 'PING-RESULT-STALE' "Ignored stale result target=$target request=$requestId latest=$($script:PingLatestRequest[$target])"
                    continue
                }
                if($script:PingTargetBusy.ContainsKey($target) -and [string]$script:PingTargetBusy[$target] -eq $requestId){$script:PingTargetBusy.Remove($target)}
                if($kind -eq 'RF'){
                    $script:RfPingBusy=$false
                    if($btnRfPing -and -not $btnRfPing.IsDisposed){$btnRfPing.Enabled=$true}
                    if([bool]$r.Success){
                        $lblConn.Text="PING : ONLINE | $($r.Time) ms";$lblConn.ForeColor=[Drawing.Color]::ForestGreen
                        Add-Log $rfLog "$target -> ONLINE, $($r.Time) ms, TTL=$($r.TTL), IP=$($r.Address)"
                    } else {
                        $lblConn.Text="PING : OFFLINE | $($r.Detail)";$lblConn.ForeColor=[Drawing.Color]::Firebrick
                        Add-Log $rfLog "$target -> OFFLINE, $($r.Detail)"
                    }
                } elseif($kind -eq 'MONITOR'){
                    Apply-MonitorPingResult $r
                } else {
                    if($script:TargetRows.ContainsKey($target)){
                        $entry=$script:TargetRows[$target];$row=Get-TargetGridRow $target
                        if($null -ne $row){
                            if([bool]$r.Success){
                                $statusText="ONLINE | $($r.Time) ms | TTL=$($r.TTL)";$row.Cells['PingStatus'].Value=$statusText;$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::ForestGreen;$entry.Status=$statusText
                                Add-Log $pingLog "[$($entry.Alias)] $target -> Reply from $($r.Address): time=$($r.Time)ms TTL=$($r.TTL)"
                            } else {
                                $statusText="OFFLINE | $($r.Detail)";$row.Cells['PingStatus'].Value=$statusText;$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::Firebrick;$entry.Status=$statusText
                                Add-Log $pingLog "[$($entry.Alias)] $target -> $($r.Detail)"
                            }
                        }
                    }
                }
                $applied++
            }
            $workerError=''
            if($obj.PSObject.Properties['error']){$workerError=([string]$obj.error).Trim()}
            [void](Finalize-PingRequest $requestId $meta $kind $completedTargets $workerError)
        } catch {Write-RuntimeLog 'PING-RESULT' ($_ | Out-String)}
        finally {Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue}
    }
    try {
        if(Test-Path -LiteralPath $PingHeartbeatFile){
            $hb=[IO.File]::ReadAllText($PingHeartbeatFile)|ConvertFrom-Json -ErrorAction Stop
            if([string]$hb.sessionId -eq $RuntimeSessionId){$script:PingWorkerLastHeartbeat=[datetime]$hb.heartbeatAt}
        }
    } catch { }
    return $applied
}

function Bytes-ToHex([byte[]]$bytes, [int]$maxBytes = 256) {
    if (-not $bytes) { return '' }
    $count = [Math]::Min($bytes.Length, $maxBytes)
    $parts = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $count; $i++) { [void]$parts.Add($bytes[$i].ToString('X2')) }
    $text = [string]::Join(' ', $parts.ToArray())
    if ($bytes.Length -gt $maxBytes) { $text += " ... (+$($bytes.Length-$maxBytes) bytes)" }
    return $text
}

function Bytes-ToText([byte[]]$bytes, [int]$maxBytes = 512) {
    if (-not $bytes) { return '' }
    $count = [Math]::Min($bytes.Length, $maxBytes)
    $slice = New-Object byte[] $count
    [Array]::Copy($bytes, 0, $slice, 0, $count)
    $text = [System.Text.Encoding]::UTF8.GetString($slice)
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, '[^\x09\x0A\x0D\x20-\x7E]', '.')
    if ($bytes.Length -gt $maxBytes) { $text += " ... (+$($bytes.Length-$maxBytes) bytes)" }
    return $text
}

function Try-ParseRfMetrics([string]$text) {
    $rssi = $null
    $snr = $null
    if ($text) {
        $m = [regex]::Match($text, '(?i)["'']?RSSI["'']?\s*[:=]\s*["'']?(-?\d+(?:\.\d+)?)')
        if ($m.Success) { $rssi = $m.Groups[1].Value }
        $m = [regex]::Match($text, '(?i)["'']?SNR["'']?\s*[:=]\s*["'']?(-?\d+(?:\.\d+)?)')
        if ($m.Success) { $snr = $m.Groups[1].Value }
    }
    return [pscustomobject]@{ RSSI=$rssi; SNR=$snr }
}

function Stop-UdpListener {
    if ($script:UdpClient) {
        try { $script:UdpClient.Close() } catch { }
        $script:UdpClient = $null
        $script:UdpFilterIPs = @()
    }
    if ($lblUdpState) {
        $lblUdpState.Text = 'UDP : STOPPED'
        $lblUdpState.ForeColor = [System.Drawing.Color]::DimGray
    }
}

function Start-UdpListener {
    Stop-UdpListener
    try {
        $port = [int]$numUdpPort.Value
        $client = [System.Net.Sockets.UdpClient]::new($port)
        $client.Client.ReceiveBufferSize = 1048576
        $script:UdpFilterIPs=@()
        $wanted=$txtRfIp.Text.Trim()
        if($chkUdpFilter.Checked -and $wanted){
            $addr=$null
            if([Net.IPAddress]::TryParse($wanted,[ref]$addr) -and $addr.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){$script:UdpFilterIPs=@($addr.ToString())}
            else {
                try{$task=[Net.Dns]::GetHostAddressesAsync($wanted);if($task.Wait(700)){$script:UdpFilterIPs=@($task.Result|Where-Object{$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork}|ForEach-Object{$_.ToString()}|Select-Object -Unique)}}catch{}
                if($script:UdpFilterIPs.Count -eq 0){throw "Không phân giải được IP/Host RF '$wanted' trong 700 ms."}
            }
        }
        $script:UdpClient = $client
        $lblUdpState.Text = "UDP : LISTENING 0.0.0.0:$port"
        $lblUdpState.ForeColor = [System.Drawing.Color]::ForestGreen
        Add-Log $rfLog "UDP listener đã mở tại 0.0.0.0:$port"
    } catch {
        $script:UdpClient = $null
        $lblUdpState.Text = 'UDP : ERROR'
        $lblUdpState.ForeColor = [System.Drawing.Color]::Firebrick
        Add-Log $rfLog "Không mở được UDP port: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Không mở được UDP port.`r`n`r`n$($_.Exception.Message)", 'UDP Error', 'OK', 'Error') | Out-Null
    }
}

function Process-UdpPackets {
    if (-not $script:UdpClient) { return }
    $processed = 0
    try {
        while ($script:UdpClient -and $script:UdpClient.Available -gt 0 -and $processed -lt 40) {
            $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $bytes = $script:UdpClient.Receive([ref]$remote)
            $processed++

            $sourceIp = $remote.Address.ToString()
            if ($chkUdpFilter.Checked -and $script:UdpFilterIPs.Count -gt 0 -and ($script:UdpFilterIPs -notcontains $sourceIp)) { continue }

            $ascii = Bytes-ToText $bytes
            $hex = Bytes-ToHex $bytes
            $script:LastUdpPacket = "FROM  : $sourceIp`:$($remote.Port)`r`nLEN   : $($bytes.Length) bytes`r`nTEXT  : $ascii`r`nHEX   : $hex"
            $txtUdpRaw.Text = $script:LastUdpPacket

            Add-Log $rfLog "UDP <- $sourceIp`:$($remote.Port) | $($bytes.Length) bytes | $ascii"
            $metrics = Try-ParseRfMetrics $ascii
            if ($null -ne $metrics.RSSI -or $null -ne $metrics.SNR) {
                $rssiText = if ($null -ne $metrics.RSSI) { "$($metrics.RSSI) dBm" } else { '---' }
                $snrText  = if ($null -ne $metrics.SNR) { "$($metrics.SNR) dB" } else { '---' }
                $lblRssi.Text = "RSSI : $rssiText    |    SNR : $snrText"
                $lblRssi.ForeColor = [System.Drawing.Color]::ForestGreen
            } else {
                $lblRssi.Text = 'RSSI / SNR : chưa nhận dạng được trong payload'
                $lblRssi.ForeColor = [System.Drawing.Color]::DarkOrange
            }
        }
    } catch {
        Add-Log $rfLog "UDP receive error: $($_.Exception.Message)"
        Stop-UdpListener
    }
}


function Convert-IPv4ToUInt32([string]$ip) {
    $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-UInt32ToIPv4([uint32]$value) {
    $bytes = [BitConverter]::GetBytes($value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-PrefixLengthFromMask([System.Net.IPAddress]$mask) {
    if (-not $mask) { return 24 }
    $bits = 0
    foreach ($b in $mask.GetAddressBytes()) {
        for ($i=7; $i -ge 0; $i--) {
            if (($b -band (1 -shl $i)) -ne 0) { $bits++ }
        }
    }
    return $bits
}

function Get-AdapterIPv4Info($adapter) {
    if (-not $adapter) { return $null }
    try {
        $props = $adapter.GetIPProperties()
        $u = $props.UnicastAddresses | Where-Object {
            $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
            -not $_.Address.ToString().StartsWith('169.254.')
        } | Select-Object -First 1
        if (-not $u) { return $null }
        $prefix = 24
        try {
            if ($u.PrefixLength -ge 0) { $prefix = [int]$u.PrefixLength }
            elseif ($u.IPv4Mask) { $prefix = Get-PrefixLengthFromMask $u.IPv4Mask }
        } catch {
            try { $prefix = Get-PrefixLengthFromMask $u.IPv4Mask } catch { $prefix = 24 }
        }
        $gateway = @($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.Address.ToString() } | Select-Object -First 1)
        $gwValue = if($gateway.Count){$gateway[0]}else{''}
        return [pscustomobject]@{ IP=$u.Address.ToString(); Prefix=$prefix; Gateway=$gwValue; InterfaceIndex=$props.GetIPv4Properties().Index }
    } catch { return $null }
}

function Get-NetworkCidr([string]$ip, [int]$prefix) {
    if ($prefix -lt 0 -or $prefix -gt 32) { throw 'Prefix CIDR không hợp lệ.' }
    $ipValue = Convert-IPv4ToUInt32 $ip
    # Windows PowerShell 5.1 can interpret hex literal 0xFFFFFFFF as signed Int32 -1.
    # Casting that -1 to UInt64 throws. Use UInt32.MaxValue instead of the hex literal.
    $fullMask = [uint64][uint32]::MaxValue
    $hostMask = if ($prefix -eq 0) { $fullMask } else { [uint64]([math]::Pow(2, 32-$prefix)-1) }
    $mask = [uint32]($fullMask - $hostMask)
    $network = [uint32]($ipValue -band $mask)
    return "$(Convert-UInt32ToIPv4 $network)/$prefix"
}

function Get-IPv4HostsFromCidr([string]$cidr, [int]$maxHosts=1024) {
    if ($cidr -notmatch '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*/\s*(\d{1,2})\s*$') { throw 'CIDR phải có dạng 192.168.1.0/24.' }
    $baseIp = $matches[1]
    $prefix = [int]$matches[2]
    if ($prefix -lt 16 -or $prefix -gt 30) { throw 'Bản portable giới hạn CIDR từ /16 đến /30. Khuyến nghị /24.' }
    [void][System.Net.IPAddress]::Parse($baseIp)
    $baseVal = Convert-IPv4ToUInt32 $baseIp
    $fullMask = [uint64][uint32]::MaxValue
    $hostMask = [uint64]([math]::Pow(2, 32-$prefix)-1)
    $mask = [uint32]($fullMask - $hostMask)
    $network = [uint32]($baseVal -band $mask)
    $hostCount = ([math]::Pow(2, 32-$prefix) - 2)
    if ($hostCount -gt $maxHosts) { throw "Mạng $cidr có $([int]$hostCount) host; giới hạn hiện tại $maxHosts. Hãy quét /22 hoặc nhỏ hơn (khuyến nghị /24)." }
    $list = New-Object System.Collections.Generic.List[string]
    for ($i=1; $i -le [int]$hostCount; $i++) { [void]$list.Add((Convert-UInt32ToIPv4 ([uint32]($network+$i)))) }
    return $list.ToArray()
}

$script:KnownOui = @{
    '001A2B'='Dahua Technology'; '3CEF8C'='Dahua Technology'; '4C11BF'='Dahua Technology'; 'A0BD1D'='Dahua Technology';
    '001E10'='Shenzhen Kaifa / China Mobile ecosystem';
    '286C07'='Xiaomi Communications'; '34CE00'='Xiaomi Communications'; '50EC50'='Xiaomi Communications'; '64CC2E'='Xiaomi Communications'; '7C1DD9'='Xiaomi Communications'; '8CBE24'='Xiaomi Communications'; '9C99A0'='Xiaomi Communications'; 'ACF7F3'='Xiaomi Communications'; 'D4970B'='Xiaomi Communications';
    '001422'='Dell'; '001C23'='Dell'; '0024E8'='Dell'; '141877'='Dell'; '18A99B'='Dell'; '246E96'='Dell'; '34E6D7'='Dell'; '3C2C30'='Dell'; '44A842'='Dell'; '4C76B0'='Dell'; '5C260A'='Dell'; '64006A'='Dell'; '6C2B59'='Dell'; '74867A'='Dell'; '84C5A6'='Dell'; 'B083FE'='Dell'; 'D067E5'='Dell'; 'F8B156'='Dell';
    '0016EA'='Intel'; '3C970E'='Intel'; '5C80B6'='Intel'; 'A4C3F0'='Intel';
    '001B63'='Apple'; '3C0754'='Apple'; 'F0D1A9'='Apple';
    '001A11'='Google'; 'F4F5D8'='Google';
    '001D7E'='Cisco'; '001E13'='Cisco'; '0023EB'='Cisco';
    '000C29'='VMware'; '005056'='VMware';
    '080027'='Oracle VirtualBox';
    'B827EB'='Raspberry Pi'; 'DCA632'='Raspberry Pi'; 'E45F01'='Raspberry Pi';
    # Project-oriented offline fallbacks. IEEE CSV remains the primary vendor source when available.
    # NVIDIA / Jetson OUIs observed across Jetson generations (NVIDIA forum guidance; new OUIs may appear).
    '00044B'='NVIDIA Corporation'; '3C6D66'='NVIDIA Corporation'; '48B02D'='NVIDIA Corporation'; '4CBB47'='NVIDIA Corporation'; '742554'='NVIDIA Corporation'; 'AC3AE2'='NVIDIA Corporation';
    # u-blox network-interface OUIs (module vendor; does NOT prove the host device is a GPS receiver).
    '6009C3'='u-blox AG'; '6C1DEB'='u-blox AG'; '54F82A'='u-blox AG'; 'CCF957'='u-blox AG'; 'D4CA6E'='u-blox AG';
    # Network / RF gateway vendors useful in field networks.
    '209727'='Teltonika Networks'; '001E42'='Teltonika Networks';
    'D4CA6D'='MikroTik'; '000C42'='MikroTik';
    'F09FC2'='Ubiquiti Inc'; 'FCECDA'='Ubiquiti Inc'; 'B4FBE4'='Ubiquiti Inc';
    # Current test-network gateway observed in this project.
    '30A023'='ROCK PATH S.R.L'
}

function Get-VendorFromMac([string]$mac) {
    if ([string]::IsNullOrWhiteSpace($mac)) { return 'Unknown' }
    $clean = ($mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
    if ($clean.Length -lt 6) { return 'Unknown' }
    # Locally administered/randomized MAC: vendor cannot be reliably inferred from IEEE assignment.
    try {
        $first = [Convert]::ToInt32($clean.Substring(0,2),16)
        if (($first -band 2) -ne 0) { return 'Randomized / Local MAC' }
    } catch { }
    if($clean.Length -ge 9 -and $script:OuiDb9.ContainsKey($clean.Substring(0,9))){return $script:OuiDb9[$clean.Substring(0,9)]}
    if($clean.Length -ge 7 -and $script:OuiDb7.ContainsKey($clean.Substring(0,7))){return $script:OuiDb7[$clean.Substring(0,7)]}
    $oui = $clean.Substring(0,6)
    if($script:OuiDb6.ContainsKey($oui)){return $script:OuiDb6[$oui]}
    if ($script:KnownOui.ContainsKey($oui)) { return $script:KnownOui[$oui] }
    return 'Unknown'
}


function Stop-OuiTaskWorker {
    if($script:OuiTaskProcess){
        try{if(-not $script:OuiTaskProcess.HasExited){try{$script:OuiTaskProcess.Kill()}catch{}}}catch{}
        try{$script:OuiTaskProcess.Dispose()}catch{}
        $script:OuiTaskProcess=$null
    }
}

function Start-OuiTaskWorker([ValidateSet('OUI_BUILD_CACHE','OUI_UPDATE')][string]$mode) {
    if($script:OuiUpdateActive){return $false}
    if(-not(Test-Path -LiteralPath $TaskWorkerScript)){throw "Không tìm thấy Task Worker: $TaskWorkerScript"}
    $runId=[guid]::NewGuid().ToString('N')
    $cfg=Join-Path $DataDir ("RF-Network-Tool.task-config.$RuntimeSessionId.$runId.json")
    $res=Join-Path $DataDir ("RF-Network-Tool.task-result.$RuntimeSessionId.$runId.json")
    $hb=Join-Path $DataDir ("RF-Network-Tool.task-heartbeat.$RuntimeSessionId.$runId.json")
    $payload=[ordered]@{schemaVersion=1;sessionId=$RuntimeSessionId;runId=$runId;ouiDir=$OuiDir;cacheFile=$OuiCacheFile}
    Write-TextAtomic $cfg (ConvertTo-Json -InputObject $payload -Depth 5)
    $ps=Get-SystemPowerShellPath
    $ticks=Get-CurrentProcessStartTicks
    $processArgs=@(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File',"`"$TaskWorkerScript`"",
        '-Mode',$mode,
        '-ConfigFile',"`"$cfg`"",
        '-ResultFile',"`"$res`"",
        '-SessionId',$RuntimeSessionId,
        '-RunId',$runId,
        '-ParentPid',[string]$PID,
        '-ParentStartTicks',[string]$ticks,
        '-HeartbeatFile',"`"$hb`""
    ) -join ' '
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$ps;$psi.Arguments=$processArgs;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $proc=New-Object Diagnostics.Process;$proc.StartInfo=$psi
    if(-not $proc.Start()){throw 'Không khởi động được OUI Task Worker.'}
    $script:OuiTaskProcess=$proc;$script:OuiTaskRunId=$runId;$script:OuiTaskResultFile=$res;$script:OuiTaskHeartbeatFile=$hb;$script:OuiTaskConfigFile=$cfg
    $script:OuiUpdateActive=$true
    Write-RuntimeLog 'OUI-TASK' "Started mode=$mode PID=$($proc.Id) runId=$runId"
    return $true
}

function Cleanup-OuiTaskFiles {
    foreach($f in @($script:OuiTaskResultFile,$script:OuiTaskHeartbeatFile,$script:OuiTaskConfigFile)){
        if($f){try{Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue}catch{}}
    }
    $script:OuiTaskRunId='';$script:OuiTaskResultFile='';$script:OuiTaskHeartbeatFile='';$script:OuiTaskConfigFile=''
}

function Start-OuiCacheLoad {
    try {
        if($script:OuiCacheReader){try{$script:OuiCacheReader.Dispose()}catch{};$script:OuiCacheReader=$null}
        $script:OuiDb6=@{};$script:OuiDb7=@{};$script:OuiDb9=@{};$script:OuiCacheLoadCount=0;$script:OuiCacheLoadActive=$false
        if(-not(Test-Path -LiteralPath $OuiCacheFile)){return $false}
        $script:OuiCacheReader=New-Object IO.StreamReader($OuiCacheFile,[Text.Encoding]::UTF8,$true)
        $script:OuiCacheLoadActive=$true
        if($ouiCacheTimer){$ouiCacheTimer.Start()}
        return $true
    } catch {
        Write-RuntimeLog 'OUI-CACHE-LOAD' ($_ | Out-String)
        return $false
    }
}

function Refresh-ScanVendorFields {
    try {
        if(-not $script:ScanContext){return}
        foreach($rec in @($script:ScanResults)){
            if(-not $rec -or -not $rec.IP){continue}
            $vendor=Get-VendorFromMac ([string]$rec.MAC)
            $fp=Get-DeviceFingerprint ([string]$rec.IP) ([string]$rec.MAC) ([string]$rec.Name) $vendor ([string]$script:ScanContext.Gateway) ([string]$script:ScanContext.LocalIP)
            $rec.Brand=$fp.Brand;$rec.Type=$fp.Type;$rec.Model=$fp.Model;$rec.OS=$fp.OS;$rec.Confidence=$fp.Confidence
            $key=Get-ScanIpKey ([string]$rec.IP)
            $row=if($key -and $script:ScanRowByIp.ContainsKey($key)){$script:ScanRowByIp[$key]}else{Find-ScanGridRowByIp ([string]$rec.IP)}
            if($null -ne $row){$script:ScanRowByIp[$key]=$row;$row.Cells['Brand'].Value=$rec.Brand;$row.Cells['Type'].Value=$rec.Type;$row.Cells['Model'].Value=$rec.Model}
        }
    } catch {Write-RuntimeLog 'OUI-REFRESH-GRID' ($_ | Out-String)}
}

function Read-OuiCacheChunk([int]$maxLines=1800) {
    if(-not $script:OuiCacheLoadActive -or -not $script:OuiCacheReader){return $false}
    try {
        $n=0
        while($n -lt $maxLines -and -not $script:OuiCacheReader.EndOfStream){
            $line=$script:OuiCacheReader.ReadLine();$n++
            if([string]::IsNullOrWhiteSpace($line)){continue}
            $parts=$line -split "`t",3
            if($parts.Count -lt 3){continue}
            $len=[string]$parts[0];$key=[string]$parts[1];$org=[string]$parts[2]
            if(-not $key -or -not $org){continue}
            if($len -eq '6'){$script:OuiDb6[$key]=$org}
            elseif($len -eq '7'){$script:OuiDb7[$key]=$org}
            elseif($len -eq '9'){$script:OuiDb9[$key]=$org}
            else{continue}
            $script:OuiCacheLoadCount++
        }
        if($script:OuiCacheReader.EndOfStream){
            try{$script:OuiCacheReader.Dispose()}catch{};$script:OuiCacheReader=$null;$script:OuiCacheLoadActive=$false
            if($ouiCacheTimer){$ouiCacheTimer.Stop()}
            Refresh-ScanVendorFields
            if($lblScanStatus -and -not $lblScanStatus.IsDisposed){$lblScanStatus.Text="Đã nạp $($script:OuiCacheLoadCount) IEEE OUI từ cache. Sẵn sàng quét.";$lblScanStatus.ForeColor=[Drawing.Color]::ForestGreen}
            return $false
        }
        if($lblScanStatus -and -not $lblScanStatus.IsDisposed){$lblScanStatus.Text="Đang nạp IEEE OUI cache nền: $($script:OuiCacheLoadCount) entries...";$lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange}
        return $true
    } catch {
        Write-RuntimeLog 'OUI-CACHE-LOAD' ($_ | Out-String)
        try{if($script:OuiCacheReader){$script:OuiCacheReader.Dispose()}}catch{};$script:OuiCacheReader=$null;$script:OuiCacheLoadActive=$false
        if($ouiCacheTimer){$ouiCacheTimer.Stop()}
        return $false
    }
}

function Poll-OuiTaskWorker {
    if(-not $script:OuiUpdateActive){return}
    try {
        if($script:OuiTaskResultFile -and (Test-Path -LiteralPath $script:OuiTaskResultFile)){
            $r=[IO.File]::ReadAllText($script:OuiTaskResultFile)|ConvertFrom-Json -ErrorAction Stop
            if([string]$r.sessionId -ne $RuntimeSessionId -or [string]$r.runId -ne $script:OuiTaskRunId){return}
            Stop-OuiTaskWorker
            $script:OuiUpdateActive=$false
            if($btnUpdateOui -and -not $btnUpdateOui.IsDisposed){$btnUpdateOui.Enabled=$true}
            if([bool]$r.success){
                $count=[int]$r.count
                $lblScanStatus.Text="Đã tạo IEEE OUI cache ($count assignments). Đang nạp vào bộ nhớ..."
                $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
                [void](Start-OuiCacheLoad)
            } else {
                $msg=if($r.PSObject.Properties['error']){[string]$r.error}else{'OUI worker thất bại.'}
                $lblScanStatus.Text=$msg;$lblScanStatus.ForeColor=[Drawing.Color]::Firebrick
                [Windows.Forms.MessageBox]::Show($msg,'IEEE OUI update','OK','Warning')|Out-Null
            }
            Cleanup-OuiTaskFiles
            return
        }
        if($script:OuiTaskProcess -and $script:OuiTaskProcess.HasExited){
            $code=$script:OuiTaskProcess.ExitCode;Stop-OuiTaskWorker;$script:OuiUpdateActive=$false
            if($btnUpdateOui -and -not $btnUpdateOui.IsDisposed){$btnUpdateOui.Enabled=$true}
            $lblScanStatus.Text="OUI worker kết thúc mà không có result (exit=$code).";$lblScanStatus.ForeColor=[Drawing.Color]::Firebrick
            Cleanup-OuiTaskFiles
            return
        }
        if($script:OuiTaskHeartbeatFile -and (Test-Path -LiteralPath $script:OuiTaskHeartbeatFile)){
            try{
                $hb=[IO.File]::ReadAllText($script:OuiTaskHeartbeatFile)|ConvertFrom-Json -ErrorAction Stop
                if([string]$hb.runId -eq $script:OuiTaskRunId){
                    $age=((Get-Date)-([datetime]$hb.heartbeatAt)).TotalSeconds
                    if($age -gt 45){throw "OUI worker heartbeat stale $([int]$age)s"}
                    $lblScanStatus.Text="IEEE OUI worker: $([string]$hb.phase)...";$lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
                }
            } catch {
                Write-RuntimeLog 'OUI-WATCHDOG' ($_ | Out-String)
                Stop-OuiTaskWorker;$script:OuiUpdateActive=$false
                if($btnUpdateOui -and -not $btnUpdateOui.IsDisposed){$btnUpdateOui.Enabled=$true}
                $lblScanStatus.Text='OUI worker bị treo hoặc heartbeat lỗi; đã dừng an toàn.';$lblScanStatus.ForeColor=[Drawing.Color]::Firebrick
                Cleanup-OuiTaskFiles
            }
        }
    } catch {Write-RuntimeLog 'OUI-TASK-POLL' ($_ | Out-String)}
}

function Get-DeviceFingerprint([string]$ip, [string]$mac, [string]$hostName, [string]$vendor, [string]$gateway, [string]$localIp) {
    $type='Unknown'; $model='-'; $os='Unknown'; $confidence='Low'
    $h = if($hostName){$hostName.ToLowerInvariant()}else{''}
    $v = if($vendor){$vendor.ToLowerInvariant()}else{''}
    if ($ip -eq $gateway) { $type='Router / Gateway'; $model='Gateway'; $confidence='High' }
    elseif ($ip -eq $localIp) {
        $type='This PC'; $os='Windows'; $confidence='High'
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($cs.Manufacturer) { $vendor=$cs.Manufacturer }
            if ($cs.Model) { $model=$cs.Model }
            if ($osInfo.Caption) { $os=$osInfo.Caption }
        } catch { }
    }
    elseif ($h -match '^xiaomi(?:[-_ ]?)(?<m>[^.]+)') {
        $type='Mobile'; $vendor='Xiaomi'; $model=($matches['m'] -replace '[-_]',' '); if([string]::IsNullOrWhiteSpace($model)){$model='Xiaomi device'}; $os='Android (heuristic)'; $confidence='Medium'
    }
    elseif ($h -match 'redmi|poco') { $type='Mobile'; if($vendor -eq 'Unknown'){$vendor='Xiaomi'}; $model=($hostName -replace '\.lan$',''); $os='Android (heuristic)'; $confidence='Medium' }
    elseif ($h -match 'jetson|nvidia') {
        $type='Edge AI / Single-board computer'; if($vendor -eq 'Unknown'){$vendor='NVIDIA'}
        $model=($hostName -replace '\.lan$',''); if([string]::IsNullOrWhiteSpace($model)){$model='Jetson family'}
        $os='Linux / Jetson Linux (heuristic)'; $confidence='Medium'
    }
    elseif ($v -match 'nvidia') { $type='Edge AI / Single-board computer'; $model='Jetson / NVIDIA embedded platform'; $os='Linux / Jetson Linux (heuristic)'; $confidence='Medium' }
    elseif ($h -match 'gps|gnss|ublox|u-blox|nmea') {
        $type='GPS / GNSS receiver'; if($vendor -eq 'Unknown' -and $h -match 'ublox|u-blox'){$vendor='u-blox AG'}
        $model=($hostName -replace '\.lan$',''); if([string]::IsNullOrWhiteSpace($model)){$model='GNSS device'}
        $os='Embedded (heuristic)'; $confidence='Medium'
    }
    elseif ($v -match 'u-blox') { $type='Embedded / GNSS / IoT module'; $model='u-blox network module'; $os='Embedded (heuristic)'; $confidence='Low' }
    elseif ($h -match '(^|[-_])(rf|radio|telemetry|modem|lora)([-_]|$)') { $type='RF / Radio / Telemetry device'; $model=($hostName -replace '\.lan$',''); $os='Embedded (heuristic)'; $confidence='Medium' }
    elseif ($v -match 'teltonika') { $type='Router / RF / IoT gateway'; $model='Teltonika device'; $os='Embedded / Linux (heuristic)'; $confidence='Medium' }
    elseif ($v -match 'ubiquiti') { $type='Network infrastructure / RF bridge / AP'; $model='Ubiquiti device'; $os='Embedded / Linux (heuristic)'; $confidence='Medium' }
    elseif ($v -match 'mikrotik') { $type='Network infrastructure / Router / AP / Switch'; $model='MikroTik device'; $os='RouterOS / embedded (heuristic)'; $confidence='Medium' }
    elseif ($v -match 'rock path') { $type='Router / Network device'; $model='Rock Space / Rock Path device'; $os='Embedded (heuristic)'; $confidence='Medium' }
    elseif ($h -match 'switch|router|gateway|access[-_ ]?point|(^|[-_])ap([-_]|$)|bridge') { $type='Network infrastructure'; $model=($hostName -replace '\.lan$',''); $confidence='Medium' }
    elseif ($v -match 'dahua') { $type='IP Camera / NVR'; $model='Dahua device'; $confidence='Medium' }
    elseif ($v -match 'xiaomi') { $type='Mobile / IoT'; $model='Xiaomi device'; $os='Android / IoT (heuristic)'; $confidence='Medium' }
    elseif ($v -match 'dell') { $type='PC / Laptop'; $model='Dell device'; $confidence='Medium' }
    elseif ($v -match 'raspberry') { $type='Single-board computer'; $model='Raspberry Pi'; $os='Linux (heuristic)'; $confidence='Medium' }
    elseif ($h -match 'iphone|ipad') { $type='Mobile'; $vendor='Apple'; $model=($hostName -replace '\.lan$',''); $os='iOS / iPadOS (heuristic)'; $confidence='Medium' }
    elseif ($h -match 'android|pixel') { $type='Mobile'; $os='Android (heuristic)'; $confidence='Medium' }
    elseif ($h -match 'printer|epson|canon|brother') { $type='Printer'; $confidence='Medium' }
    elseif ($h -match 'camera|cam|nvr|dvr|ipc') { $type='IP Camera / NVR'; $confidence='Medium' }
    elseif ($h -match 'router|gateway|ap-|accesspoint') { $type='Router / AP'; $confidence='Medium' }
    elseif ($h -match 'desktop|laptop|pc-|win') { $type='PC / Laptop'; $os='Windows (heuristic)'; $confidence='Medium' }
    return [pscustomobject]@{ Type=$type; Brand=$vendor; Model=$model; OS=$os; Confidence=$confidence }
}


function Get-DeviceKey([string]$ip, [string]$mac) {
    $clean = if($mac){($mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()}else{''}
    if($clean.Length -ge 12 -and $clean -ne '000000000000'){ return "MAC:$clean" }
    return "IP:$ip"
}

function Load-DeviceHistory {
    $script:DeviceHistory=@{}
    foreach($d in @(Read-JsonFileSafe $DeviceHistoryFile 'DEVICE-HISTORY' -BackupOnError)) {
        try { if($d.Key){$script:DeviceHistory[[string]$d.Key]=$d} } catch { Write-RuntimeLog 'DEVICE-HISTORY' ('Invalid entry: '+$_.Exception.Message) }
    }
}

function Save-DeviceHistory {
    try {
        $arr=@($script:DeviceHistory.Values | Sort-Object LastSeen -Descending)
        $json=ConvertTo-Json -InputObject $arr -Depth 5
        Write-TextAtomic $DeviceHistoryFile $json
    } catch { Write-RuntimeLog 'DEVICE-HISTORY' ($_ | Out-String) }
}

function Update-DeviceHistory($device,[bool]$incrementSeen=$false) {
    if(-not $device){return $null}
    $now=(Get-Date).ToString('s')
    $device.MAC=Format-Mac ([string]$device.MAC)
    $key=Get-DeviceKey $device.IP $device.MAC
    $ipKey="IP:$($device.IP)"

    # If an ICMP-only row was first stored by IP and ARP later supplies a MAC,
    # migrate/merge that provisional history entry into the stable MAC identity.
    if($key -like 'MAC:*' -and $ipKey -ne $key -and $script:DeviceHistory.ContainsKey($ipKey)){
        $old=$script:DeviceHistory[$ipKey]
        if(-not $script:DeviceHistory.ContainsKey($key)){
            try{$old.Key=$key}catch{}
            $script:DeviceHistory[$key]=$old
        } else {
            $dst=$script:DeviceHistory[$key]
            if($old.FirstSeen -and ((-not $dst.FirstSeen) -or ([string]$old.FirstSeen -lt [string]$dst.FirstSeen))){$dst.FirstSeen=$old.FirstSeen}
            if($old.LastSeen -and ((-not $dst.LastSeen) -or ([string]$old.LastSeen -gt [string]$dst.LastSeen))){$dst.LastSeen=$old.LastSeen}
            $dst.SeenCount=[Math]::Max([int]$dst.SeenCount,[int]$old.SeenCount)
            if(-not $dst.LastName -and $old.LastName){$dst.LastName=$old.LastName}
            if(-not $dst.LastBrand -and $old.LastBrand){$dst.LastBrand=$old.LastBrand}
            if(-not $dst.LastModel -and $old.LastModel){$dst.LastModel=$old.LastModel}
            if(-not $dst.LastType -and $old.LastType){$dst.LastType=$old.LastType}
        }
        [void]$script:DeviceHistory.Remove($ipKey)
    }

    if(-not $script:DeviceHistory.ContainsKey($key)){
        $script:DeviceHistory[$key]=[pscustomobject]@{Key=$key;FirstSeen=$now;LastSeen=$now;SeenCount=0;LastIP=$device.IP;LastMAC=$device.MAC;LastName='';LastNameSource='';LastBrand=$device.Brand;LastModel=$device.Model;LastType=$device.Type}
    }
    $h=$script:DeviceHistory[$key]
    if(-not $h.PSObject.Properties['LastNameSource']){$h|Add-Member -NotePropertyName LastNameSource -NotePropertyValue '' -Force}
    $h.LastSeen=$now
    if($incrementSeen){$h.SeenCount=[int]$h.SeenCount+1}
    $h.LastIP=$device.IP;$h.LastMAC=$device.MAC
    $nameSource=''
    if($device.PSObject.Properties['NameSource']){$nameSource=([string]$device.NameSource).Trim()}
    # Never let a historical fallback re-poison the identity record. Only current/user evidence may refresh the remembered name.
    if($device.Name -and $nameSource -and $nameSource -notlike 'History*'){$h.LastName=$device.Name;$h.LastNameSource=$nameSource}
    if($device.Brand){$h.LastBrand=$device.Brand}; if($device.Model){$h.LastModel=$device.Model}; if($device.Type){$h.LastType=$device.Type}
    return $h
}

function Load-ScanHistory {
    $script:ScanHistory=@()
    foreach($r in @(Read-JsonFileSafe $ScanHistoryFile 'SCAN-HISTORY' -BackupOnError)){
        if($r){$script:ScanHistory += $r}
    }
    $script:ScanHistory=@($script:ScanHistory | Sort-Object CompletedAt -Descending | Select-Object -First 50)
}

function Save-ScanHistory {
    try {
        $json=ConvertTo-Json -InputObject @($script:ScanHistory | Select-Object -First 50) -Depth 6
        Write-TextAtomic $ScanHistoryFile $json
    } catch { Write-RuntimeLog 'SCAN-HISTORY' ($_ | Out-String) }
}

function Add-ScanHistoryRecord($state) {
    if(-not $state){return}
    try {
        $metrics=$state.metrics
        $ctx=$script:ScanContext
        $record=[pscustomobject]@{
            RunId=$(if($state.PSObject.Properties['runId']){[string]$state.runId}else{[guid]::NewGuid().ToString('N')})
            Profile=$(if($state.PSObject.Properties['profile']){[string]$state.profile}else{$script:CurrentScanProfile})
            CIDR=$(if($ctx){[string]$ctx.CIDR}else{'-'})
            StartedAt=$(if($state.PSObject.Properties['startedAt']){[string]$state.startedAt}elseif($script:CurrentScanStartedAt){$script:CurrentScanStartedAt.ToString('o')}else{''})
            CompletedAt=(Get-Date).ToString('o')
            Outcome=$(if([string]$state.error){'ERROR'}elseif([bool]$state.cancelled){'CANCELLED'}else{'COMPLETE'})
            Targets=[int]$state.total
            Online=[int]$state.online
            L2Seen=[int]$state.seen
            Discovered=@($state.results | Where-Object {$_.Status -ne 'Unknown'}).Count
            ElapsedMs=$(if($state.PSObject.Properties['elapsedMs']){[int]$state.elapsedMs}else{0})
            FastResponseRate=$(if($metrics -and $metrics.PSObject.Properties['FastResponseRate']){[double]$metrics.FastResponseRate}else{0})
            FastAverageMs=$(if($metrics -and $metrics.PSObject.Properties['FastAverageMs']){[double]$metrics.FastAverageMs}else{0})
            PingConcurrency=$(if($metrics -and $metrics.PSObject.Properties['EffectivePingConcurrency']){[int]$metrics.EffectivePingConcurrency}else{0})
            RetryConcurrency=$(if($metrics -and $metrics.PSObject.Properties['EffectiveRetryConcurrency']){[int]$metrics.EffectiveRetryConcurrency}else{0})
            ArpConcurrency=$(if($metrics -and $metrics.PSObject.Properties['EffectiveArpConcurrency']){[int]$metrics.EffectiveArpConcurrency}else{0})
            IPv6Neighbors=$(if($state.PSObject.Properties['ipv6Neighbors']){@($state.ipv6Neighbors).Count}else{0})
        }
        $script:ScanHistory=@($record)+@($script:ScanHistory | Where-Object {[string]$_.RunId -ne [string]$record.RunId} | Select-Object -First 49)
        Save-ScanHistory
    } catch { Write-RuntimeLog 'SCAN-HISTORY' ($_ | Out-String) }
}

function Get-MacCharacteristics([string]$mac) {
    $clean=if($mac){($mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()}else{''}
    if($clean.Length -lt 12){return [pscustomobject]@{Scope='Unknown';Traffic='Unknown';Normalized=$clean}}
    try {
        $first=[Convert]::ToInt32($clean.Substring(0,2),16)
        $scope=if(($first -band 2)-ne 0){'Locally administered / randomized'}else{'Universally administered'}
        $traffic=if(($first -band 1)-ne 0){'Multicast'}else{'Unicast'}
        return [pscustomobject]@{Scope=$scope;Traffic=$traffic;Normalized=$clean}
    } catch { return [pscustomobject]@{Scope='Unknown';Traffic='Unknown';Normalized=$clean} }
}

function Get-OsHintFromTtl($ttl) {
    if(-not $ttl -or $ttl -eq '-'){return 'Unknown'}
    $t=[int]$ttl
    if($t -le 64){return 'Unix/Linux/Android/macOS-like (TTL heuristic only)'}
    if($t -le 128){return 'Windows-like (TTL heuristic only)'}
    return 'Network appliance / embedded-like (TTL heuristic only)'
}

function Set-PropertyGrid($grid,[System.Collections.IDictionary]$pairs) {
    $grid.Rows.Clear()
    foreach($k in $pairs.Keys){[void]$grid.Rows.Add([string]$k,[string]$pairs[$k])}
}

function New-PropertyGrid {
    $g=New-Object System.Windows.Forms.DataGridView
    $g.Dock='Fill';$g.ReadOnly=$true;$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.AllowUserToResizeRows=$false;$g.RowHeadersVisible=$false;$g.SelectionMode='FullRowSelect';$g.AutoSizeColumnsMode='Fill';$g.BackgroundColor=[Drawing.Color]::White
    $c1=New-Object System.Windows.Forms.DataGridViewTextBoxColumn;$c1.HeaderText='THÔNG TIN';$c1.FillWeight=35
    $c2=New-Object System.Windows.Forms.DataGridViewTextBoxColumn;$c2.HeaderText='GIÁ TRỊ';$c2.FillWeight=65
    [void]$g.Columns.Add($c1);[void]$g.Columns.Add($c2)
    return $g
}

function Get-ObjectPropertyValue($obj,[string]$name,$defaultValue='') {
    try { if($obj -and $obj.PSObject.Properties[$name]){return $obj.$name} } catch { }
    return $defaultValue
}

function New-EvidenceRecord([string]$source,[string]$state,[string]$value='',[string]$detail='',[string]$observedAt='') {
    return [pscustomobject]@{Source=$source;State=$state;Value=$value;Detail=$detail;ObservedAt=$observedAt}
}

function Get-ScanEvidenceRecords($scanItem,[string]$observedAt='') {
    $out=New-Object System.Collections.Generic.List[object]
    if(-not $scanItem){return $out.ToArray()}
    $now=$observedAt;if(-not $now){$now=[string](Get-ObjectPropertyValue $scanItem 'UpdatedAt' '')};if(-not $now){$now=(Get-Date).ToString('s')}

    $fast=[bool](Get-ObjectPropertyValue $scanItem 'IcmpFast' $false)
    $fastStatus=[string](Get-ObjectPropertyValue $scanItem 'IcmpFastStatus' 'Unknown')
    $fastMs=[string](Get-ObjectPropertyValue $scanItem 'IcmpFastMs' '')
    $fastTtl=[string](Get-ObjectPropertyValue $scanItem 'IcmpFastTTL' '')
    $fastValue=if($fast){"${fastMs} ms | TTL $fastTtl"}else{''}
    [void]$out.Add((New-EvidenceRecord 'ICMP fast' $(if($fast){'PASS'}else{'NO RESPONSE'}) $fastValue $fastStatus $now))

    $retry=[bool](Get-ObjectPropertyValue $scanItem 'IcmpRetry' $false)
    $retryStatus=[string](Get-ObjectPropertyValue $scanItem 'IcmpRetryStatus' 'Not attempted')
    $retryMs=[string](Get-ObjectPropertyValue $scanItem 'IcmpRetryMs' '')
    $retryTtl=[string](Get-ObjectPropertyValue $scanItem 'IcmpRetryTTL' '')
    $retryState=if($retry){'PASS'}elseif($retryStatus -like 'Skipped*'){'SKIPPED'}else{'NO RESPONSE'}
    $retryValue=if($retry){"${retryMs} ms | TTL $retryTtl"}else{''}
    [void]$out.Add((New-EvidenceRecord 'ICMP retry' $retryState $retryValue $retryStatus $now))

    $arp=[bool](Get-ObjectPropertyValue $scanItem 'Arp' $false)
    $arpStatus=[string](Get-ObjectPropertyValue $scanItem 'ArpStatus' 'Not attempted')
    $arpMac=[string](Get-ObjectPropertyValue $scanItem 'ArpMAC' '')
    $arpError=[string](Get-ObjectPropertyValue $scanItem 'ArpError' '')
    [void]$out.Add((New-EvidenceRecord 'Active ARP' $(if($arp){'PASS'}else{'NO RESPONSE'}) $arpMac $(if($arp){$arpStatus}else{"$arpStatus; code=$arpError"}) $now))

    $neighbor=[bool](Get-ObjectPropertyValue $scanItem 'Neighbor' $false)
    $neighborState=[string](Get-ObjectPropertyValue $scanItem 'NeighborState' 'Not observed')
    $neighborMac=[string](Get-ObjectPropertyValue $scanItem 'NeighborMAC' '')
    [void]$out.Add((New-EvidenceRecord 'Neighbor cache' $(if($neighbor){'PASS'}else{'NOT OBSERVED'}) $neighborMac $neighborState $now))
    return $out.ToArray()
}

function Read-DiscoveryCacheRecords {
    if(-not (Test-Path -LiteralPath $DiscoveryCacheFile)){return @()}
    try {
        $raw=Get-Content -LiteralPath $DiscoveryCacheFile -Raw -ErrorAction Stop
        if([string]::IsNullOrWhiteSpace($raw)){return @()}
        $parsed=$raw | ConvertFrom-Json -ErrorAction Stop
        if($parsed -and $parsed.PSObject.Properties['records']){return @($parsed.records)}
        return @($parsed)
    } catch { return @() }
}

function Get-DiscoveryEvidenceForIp([string]$ip) {
    foreach($it in @(Read-DiscoveryCacheRecords)){
        if([string]$it.IP -eq $ip){return @($it.Evidence)}
    }
    return @()
}

function Merge-EvidenceRecords([object[]]$sets) {
    $map=[ordered]@{}
    foreach($set in @($sets)){
        foreach($e in @($set)){
            if(-not $e){continue}
            $source=[string](Get-ObjectPropertyValue $e 'Source' '')
            if([string]::IsNullOrWhiteSpace($source)){continue}
            $map[$source]=[pscustomobject]@{
                Source=$source
                State=[string](Get-ObjectPropertyValue $e 'State' 'INFO')
                Value=[string](Get-ObjectPropertyValue $e 'Value' '')
                Detail=[string](Get-ObjectPropertyValue $e 'Detail' '')
                ObservedAt=[string](Get-ObjectPropertyValue $e 'ObservedAt' '')
            }
        }
    }
    return @($map.Values)
}

function Get-StaticEvidenceRecords($device) {
    $out=New-Object System.Collections.Generic.List[object]
    if(-not $device){return $out.ToArray()}
    $mac=Format-Mac ([string]$device.MAC)
    $mi=Get-MacCharacteristics $mac
    $vendor=Get-VendorFromMac $mac
    if($mi.Scope -match 'Local|Random'){
        [void]$out.Add((New-EvidenceRecord 'IEEE OUI / MAC' 'INFO' $mac 'Locally administered/randomized MAC; vendor cannot be inferred reliably from OUI.' ''))
    } elseif($vendor -and $vendor -notin @('Unknown','Randomized / Local MAC')) {
        [void]$out.Add((New-EvidenceRecord 'IEEE OUI / MAC' 'PASS' $vendor $mac ''))
    } else {
        [void]$out.Add((New-EvidenceRecord 'IEEE OUI / MAC' 'NOT OBSERVED' $mac 'No vendor mapping available.' ''))
    }
    if([string]$device.NameSource -eq 'PING alias' -and $device.Name){[void]$out.Add((New-EvidenceRecord 'PING alias' 'PASS' ([string]$device.Name) 'User-defined alias; not a network-advertised hostname.' ''))}
    return $out.ToArray()
}

function Get-DeepEvidenceRecords($deep) {
    $out=New-Object System.Collections.Generic.List[object]
    if(-not $deep){return $out.ToArray()}
    $pingState=if([int]$deep.Ping.Received -gt 0){'PASS'}else{'NO RESPONSE'}
    [void]$out.Add((New-EvidenceRecord 'Deep ICMP statistics' $pingState "$($deep.Ping.Received)/$($deep.Ping.Sent) replies" "loss=$($deep.Ping.LossPercent)% min/avg/max=$($deep.Ping.Min)/$($deep.Ping.Avg)/$($deep.Ping.Max) ms TTL=$($deep.Ping.TTL)" ''))
    $neighborState=if($deep.NeighborState -and $deep.NeighborState -notmatch 'Unknown|Not'){ 'PASS' } else { 'NOT OBSERVED' }
    [void]$out.Add((New-EvidenceRecord 'Deep neighbor state' $neighborState ([string]$deep.NeighborState) 'Queried from Windows neighbor cache.' ''))
    $open=@($deep.PortChecks | Where-Object {$_.State -eq 'Open'})
    [void]$out.Add((New-EvidenceRecord 'Common TCP services' $(if($open.Count -gt 0){'PASS'}else{'NOT OBSERVED'}) $(if($open.Count -gt 0){(($open | ForEach-Object{"$($_.Port)/$($_.Service)"}) -join ', ')}else{'No open common TCP ports'}) 'Fixed common-service probe set; not a full 1-65535 scan.' ''))
    if($deep.HTTP){[void]$out.Add((New-EvidenceRecord 'HTTP fingerprint' 'PASS' ([string]$deep.HTTP.Title) "Server=$($deep.HTTP.Server); Status=$($deep.HTTP.Status); URL=$($deep.HTTP.URL)" ''))}else{[void]$out.Add((New-EvidenceRecord 'HTTP fingerprint' 'NOT OBSERVED' '' 'No HTTP fingerprint obtained from probed HTTP ports.' ''))}
    if($deep.SSDP -and ($deep.SSDP.Location -or $deep.SSDP.Server)){[void]$out.Add((New-EvidenceRecord 'SSDP direct probe' 'PASS' ([string]$deep.SSDP.Server) "ST=$($deep.SSDP.ST); LOCATION=$($deep.SSDP.Location)" ''))}else{[void]$out.Add((New-EvidenceRecord 'SSDP direct probe' 'NOT OBSERVED' '' 'No target-specific SSDP response during deep probe.' ''))}
    if($deep.UPnP){[void]$out.Add((New-EvidenceRecord 'UPnP description' 'PASS' ([string]$deep.UPnP.FriendlyName) "Manufacturer=$($deep.UPnP.Manufacturer); Model=$($deep.UPnP.ModelName) $($deep.UPnP.ModelNumber)" ''))}else{[void]$out.Add((New-EvidenceRecord 'UPnP description' 'NOT OBSERVED' '' 'No UPnP device description retrieved.' ''))}
    if($deep.NetBIOS){[void]$out.Add((New-EvidenceRecord 'NetBIOS deep probe' 'PASS' ([string]$deep.NetBIOS) 'NetBIOS data returned by nbtstat.' ''))}else{[void]$out.Add((New-EvidenceRecord 'NetBIOS deep probe' 'NOT OBSERVED' '' 'No NetBIOS detail collected (or SMB was not open).' ''))}
    return $out.ToArray()
}

function New-EvidenceGrid {
    $g=New-Object System.Windows.Forms.DataGridView
    $g.Dock='Fill';$g.ReadOnly=$true;$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.AllowUserToResizeRows=$false;$g.RowHeadersVisible=$false
    $g.SelectionMode='FullRowSelect';$g.MultiSelect=$false;$g.AutoSizeColumnsMode='Fill';$g.BackgroundColor=[Drawing.Color]::White;$g.AutoGenerateColumns=$false
    [void]$g.Columns.Add('Source','SOURCE');[void]$g.Columns.Add('State','STATE');[void]$g.Columns.Add('Value','VALUE');[void]$g.Columns.Add('Detail','DETAIL');[void]$g.Columns.Add('ObservedAt','OBSERVED')
    $g.Columns['Source'].FillWeight=23;$g.Columns['State'].FillWeight=14;$g.Columns['Value'].FillWeight=23;$g.Columns['Detail'].FillWeight=32;$g.Columns['ObservedAt'].FillWeight=16
    return $g
}

function Set-EvidenceGrid($grid,[object[]]$records) {
    if(-not $grid){return}
    $grid.Rows.Clear()
    foreach($e in @($records)){
        $ri=$grid.Rows.Add([string]$e.Source,[string]$e.State,[string]$e.Value,[string]$e.Detail,[string]$e.ObservedAt)
        $state=[string]$e.State
        if($state -eq 'PASS'){$grid.Rows[$ri].Cells['State'].Style.ForeColor=[Drawing.Color]::ForestGreen;$grid.Rows[$ri].Cells['State'].Style.Font=New-Font 9 ([Drawing.FontStyle]::Bold)}
        elseif($state -in @('NO RESPONSE','NOT OBSERVED')){$grid.Rows[$ri].Cells['State'].Style.ForeColor=[Drawing.Color]::DimGray}
        elseif($state -eq 'ERROR'){$grid.Rows[$ri].Cells['State'].Style.ForeColor=[Drawing.Color]::Firebrick}
        else{$grid.Rows[$ri].Cells['State'].Style.ForeColor=[Drawing.Color]::DarkOrange}
    }
}

function Get-DeviceEvidenceRecords($device,$deep=$null) {
    $scan=@();try{if($device.PSObject.Properties['ScanEvidence']){$scan=@($device.ScanEvidence)}}catch{}
    $discovery=@();try{if($device.PSObject.Properties['DiscoveryEvidence']){$discovery=@($device.DiscoveryEvidence)}}catch{}
    if($discovery.Count -eq 0 -and $device.IP){$discovery=@(Get-DiscoveryEvidenceForIp ([string]$device.IP))}
    $static=@(Get-StaticEvidenceRecords $device)
    $deepSet=if($deep){@(Get-DeepEvidenceRecords $deep)}else{@()}
    return @(Merge-EvidenceRecords @($scan,$discovery,$static,$deepSet))
}

function Get-EvidenceSummaryText($device,[object[]]$records) {
    $pass=@($records | Where-Object {$_.State -eq 'PASS'}).Count
    $missing=@($records | Where-Object {$_.State -in @('NO RESPONSE','NOT OBSERVED')}).Count
    $label=if($device.Status -eq 'Online'){'ICMP reachable'}elseif($device.Status -eq 'L2 Seen'){'Layer-2 seen; ICMP unavailable'}else{[string]$device.Status}
    return "$label   |   Evidence PASS: $pass   |   No response/not observed: $missing   |   Best name source: $($device.NameSource)"
}

function Show-DeviceDetails($row,$adapterInfoObj) {
    if(-not $row){return}
    $d=$row.Tag
    if(-not $d){$d=[pscustomobject]@{Status=[string]$row.Cells['Status'].Value;Type=[string]$row.Cells['Type'].Value;Brand=[string]$row.Cells['Brand'].Value;Model=[string]$row.Cells['Model'].Value;Name=[string]$row.Cells['Name'].Value;IP=[string]$row.Cells['IP'].Value;MAC=[string]$row.Cells['MAC'].Value;Latency=[string]$row.Cells['Latency'].Value;OS='Unknown';Confidence='Low';NameSource=$(if($row.Cells['Source']){[string]$row.Cells['Source'].Value}else{''});ScanEvidence=@();DiscoveryEvidence=@()}}
    $d.MAC=Format-Mac ([string]$d.MAC)
    try{$row.Cells['MAC'].Value=$d.MAC}catch{}
    $hist=$script:DeviceHistory[(Get-DeviceKey $d.IP $d.MAC)]
    $f=New-Object System.Windows.Forms.Form
    $f.Text="Device details - $($d.IP)";$f.Size=New-Object System.Drawing.Size(1080,760);$f.MinimumSize=New-Object System.Drawing.Size(900,640);$f.StartPosition='CenterParent';$f.Font=New-Font 9;$f.AutoScaleMode=[System.Windows.Forms.AutoScaleMode]::Font
    $top=New-Object System.Windows.Forms.Panel;$top.Dock='Top';$top.Height=92;$top.Padding=New-Object System.Windows.Forms.Padding(16,10,16,8);$f.Controls.Add($top)
    $lblTitle=New-Object System.Windows.Forms.Label;$lblTitle.Text=if($d.Name){$d.Name}else{$d.IP};$lblTitle.Font=New-Font 18 ([Drawing.FontStyle]::Bold);$lblTitle.Location=New-Object System.Drawing.Point(16,10);$lblTitle.AutoSize=$true;$top.Controls.Add($lblTitle)
    $lblSub=New-Object System.Windows.Forms.Label;$lblSub.Text="$($d.Type)   |   $($d.Brand)   |   $($d.Model)";$lblSub.Location=New-Object System.Drawing.Point(18,48);$lblSub.Anchor='Top,Left,Right';$lblSub.AutoEllipsis=$true;$lblSub.Size=New-Object System.Drawing.Size(830,24);$lblSub.ForeColor=[Drawing.Color]::DimGray;$top.Controls.Add($lblSub)
    $lblState=New-Object System.Windows.Forms.Label;$lblState.Text=$d.Status;$lblState.Font=New-Font 10 ([Drawing.FontStyle]::Bold);$lblState.Anchor='Top,Right';$lblState.Location=New-Object System.Drawing.Point(920,22);$lblState.AutoSize=$true;$lblState.ForeColor=if($d.Status -eq 'Online'){[Drawing.Color]::ForestGreen}else{[Drawing.Color]::DarkOrange};$top.Controls.Add($lblState)
    $tabsD=New-Object System.Windows.Forms.TabControl;$tabsD.Dock='Fill';$f.Controls.Add($tabsD);$tabsD.BringToFront()
    $tOverview=New-Object System.Windows.Forms.TabPage;$tOverview.Text='TỔNG QUAN';$tabsD.TabPages.Add($tOverview)|Out-Null
    $tNetwork=New-Object System.Windows.Forms.TabPage;$tNetwork.Text='NETWORK & HISTORY';$tabsD.TabPages.Add($tNetwork)|Out-Null
    $tProto=New-Object System.Windows.Forms.TabPage;$tProto.Text='PROTOCOLS & SERVICES';$tabsD.TabPages.Add($tProto)|Out-Null
    $tPorts=New-Object System.Windows.Forms.TabPage;$tPorts.Text='OPEN PORTS';$tabsD.TabPages.Add($tPorts)|Out-Null
    $tEvidence=New-Object System.Windows.Forms.TabPage;$tEvidence.Text='DISCOVERY EVIDENCE';$tabsD.TabPages.Add($tEvidence)|Out-Null
    $gOverview=New-PropertyGrid;$tOverview.Controls.Add($gOverview)
    $gNetwork=New-PropertyGrid;$tNetwork.Controls.Add($gNetwork)
    $txtProto=New-Object System.Windows.Forms.TextBox;$txtProto.Multiline=$true;$txtProto.ReadOnly=$true;$txtProto.ScrollBars='Both';$txtProto.WordWrap=$false;$txtProto.Dock='Fill';$txtProto.Font=New-Object System.Drawing.Font('Consolas',9);$tProto.Controls.Add($txtProto)
    $gridPorts=New-Object System.Windows.Forms.DataGridView;$gridPorts.Dock='Fill';$gridPorts.ReadOnly=$true;$gridPorts.AllowUserToAddRows=$false;$gridPorts.AllowUserToDeleteRows=$false;$gridPorts.RowHeadersVisible=$false;$gridPorts.SelectionMode='FullRowSelect';$gridPorts.AutoSizeColumnsMode='Fill';$gridPorts.BackgroundColor=[Drawing.Color]::White
    [void]$gridPorts.Columns.Add('Port','PORT');[void]$gridPorts.Columns.Add('Service','SERVICE');[void]$gridPorts.Columns.Add('State','STATE');[void]$gridPorts.Columns.Add('Detail','NOTE')
    $gridPorts.Columns['Port'].FillWeight=12;$gridPorts.Columns['Service'].FillWeight=22;$gridPorts.Columns['State'].FillWeight=22;$gridPorts.Columns['Detail'].FillWeight=44
    [void]$gridPorts.Rows.Add('-','Common TCP probe set','Not checked','Bấm Phân tích sâu / Refresh. Đây không phải full 1-65535 port scan.')
    $tPorts.Controls.Add($gridPorts)

    $evidencePanel=New-Object System.Windows.Forms.Panel;$evidencePanel.Dock='Fill';$tEvidence.Controls.Add($evidencePanel)
    $lblEvidenceSummary=New-Object System.Windows.Forms.Label;$lblEvidenceSummary.Dock='Top';$lblEvidenceSummary.Height=44;$lblEvidenceSummary.Padding=New-Object System.Windows.Forms.Padding(8,8,8,4);$lblEvidenceSummary.AutoEllipsis=$true;$lblEvidenceSummary.ForeColor=[Drawing.Color]::DimGray;$evidencePanel.Controls.Add($lblEvidenceSummary)
    $gridEvidence=New-EvidenceGrid;$evidencePanel.Controls.Add($gridEvidence);$lblEvidenceSummary.BringToFront()

    $bottom=New-Object System.Windows.Forms.Panel;$bottom.Dock='Bottom';$bottom.Height=54;$f.Controls.Add($bottom);$bottom.BringToFront()
    $btnDeep=New-Object System.Windows.Forms.Button;$btnDeep.Text='Phân tích sâu / Refresh';$btnDeep.Location=New-Object System.Drawing.Point(14,11);$btnDeep.Size=New-Object System.Drawing.Size(165,32);$bottom.Controls.Add($btnDeep)
    $btnCopy=New-Object System.Windows.Forms.Button;$btnCopy.Text='Copy all';$btnCopy.Location=New-Object System.Drawing.Point(190,11);$btnCopy.Size=New-Object System.Drawing.Size(90,32);$bottom.Controls.Add($btnCopy)
    $btnClose=New-Object System.Windows.Forms.Button;$btnClose.Text='Đóng';$btnClose.Anchor='Top,Right';$btnClose.Location=New-Object System.Drawing.Point(955,11);$btnClose.Size=New-Object System.Drawing.Size(90,32);$bottom.Controls.Add($btnClose);$btnClose.Add_Click({$f.Close()})

    $macInfo=Get-MacCharacteristics $d.MAC
    Set-PropertyGrid $gOverview ([ordered]@{'Status'=$d.Status;'Device type'=$d.Type;'Brand'=$d.Brand;'Model'=$d.Model;'Operating system'=$d.OS;'Recognition confidence'=$d.Confidence;'Device name'=$d.Name;'Name source'=$d.NameSource;'IP address'=$d.IP;'MAC address'=$d.MAC;'Open TCP ports (common set)'='Chưa kiểm tra'})
    Set-PropertyGrid $gNetwork ([ordered]@{'IP address'=$d.IP;'MAC address'=$d.MAC;'Device name'=$d.Name;'Name source'=$d.NameSource;'MAC administration'=$macInfo.Scope;'MAC traffic type'=$macInfo.Traffic;'Adapter'=$(if($adapterInfoObj){$adapterInfoObj.AdapterName}else{''});'Local IPv4 / CIDR'=$(if($adapterInfoObj){"$($adapterInfoObj.IP)/$($adapterInfoObj.Prefix)"}else{''});'Gateway'=$(if($adapterInfoObj){$adapterInfoObj.Gateway}else{''});'Last ping'=$d.Latency;'First seen'=$(if($hist){$hist.FirstSeen}else{'This scan'});'Last seen'=$(if($hist){$hist.LastSeen}else{(Get-Date).ToString('s')});'Seen count'=$(if($hist){$hist.SeenCount}else{1})})
    $txtProto.Text="Bấm 'Phân tích sâu / Refresh' để kiểm tra ping statistics, neighbor state, common TCP services, HTTP fingerprint, SSDP/UPnP và NetBIOS (khi phù hợp).`r`n`r`nCác trường không được thiết bị công bố sẽ để trống/Unknown; chương trình không giả lập thông tin."
    $initialEvidence=@(Get-DeviceEvidenceRecords $d $null);Set-EvidenceGrid $gridEvidence $initialEvidence;$lblEvidenceSummary.Text=Get-EvidenceSummaryText $d $initialEvidence

    $lastDeep=$null
    # Mutable state object is shared by all WinForms event scriptblocks; bare local assignments are child-scoped in PowerShell.
    $deepState=[pscustomobject]@{Busy=$false;Process=$null;RunId='';ResultFile='';HeartbeatFile='';ConfigFile='';StartedAt=$null;SeenHeartbeat=$false;StartupTimeoutSec=12;Completed=$false;Succeeded=$false;LastPhase='';LastError=''}
    $deepTimer=New-Object System.Windows.Forms.Timer;$deepTimer.Interval=250

    $cleanupDeep={
        try{if($deepTimer){$deepTimer.Stop()}}catch{}
        if($deepState.Process){try{if(-not $deepState.Process.HasExited){try{$deepState.Process.Kill()}catch{}}}catch{};try{$deepState.Process.Dispose()}catch{};$deepState.Process=$null}
        foreach($fp in @($deepState.ResultFile,$deepState.HeartbeatFile,$deepState.ConfigFile)){if($fp){try{Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue}catch{}}}
        $deepState.RunId='';$deepState.ResultFile='';$deepState.HeartbeatFile='';$deepState.ConfigFile='';$deepState.StartedAt=$null;$deepState.SeenHeartbeat=$false
        $deepState.Busy=$false
        if(-not $f.IsDisposed){$btnDeep.Enabled=$true;$btnClose.Enabled=$true;$btnDeep.Text='Phân tích sâu / Refresh'}
    }

    $applyDeep={
        param($deep)
        $lastDeep=$deep
        if($deep.Brand){$d.Brand=[string]$deep.Brand};if($deep.Model){$d.Model=[string]$deep.Model};if($deep.Type){$d.Type=[string]$deep.Type};if($deep.Name){$d.Name=Normalize-DiscoveredName ([string]$deep.Name)};if($deep.PSObject.Properties['NameSource'] -and $deep.NameSource){$d.NameSource=[string]$deep.NameSource};if($deep.OS){$d.OS=[string]$deep.OS}
        $row.Cells['Brand'].Value=$d.Brand;$row.Cells['Model'].Value=$d.Model;$row.Cells['Type'].Value=$d.Type;if($d.Name){$row.Cells['Name'].Value=$d.Name};if($row.Cells['Source']){$row.Cells['Source'].Value=$d.NameSource}
        $lblTitle.Text=if($d.Name){$d.Name}else{$d.IP};$lblSub.Text="$($d.Type)   |   $($d.Brand)   |   $($d.Model)"
        $hist=Update-DeviceHistory $d;Save-DeviceHistory
        Set-PropertyGrid $gOverview ([ordered]@{'Status'=$d.Status;'Device type'=$d.Type;'Brand'=$d.Brand;'Model'=$d.Model;'Operating system'=$d.OS;'Recognition confidence'=$d.Confidence;'Device name'=$d.Name;'Name source'=$d.NameSource;'IP address'=$d.IP;'MAC address'=$d.MAC;'Open TCP ports (common set)'=[string]$deep.PortText})
        Set-PropertyGrid $gNetwork ([ordered]@{'IP address'=$d.IP;'MAC address'=$d.MAC;'Device name'=$d.Name;'Name source'=$d.NameSource;'MAC administration'=[string]$deep.MacInfo.Scope;'MAC traffic type'=[string]$deep.MacInfo.Traffic;'Neighbor / ARP state'=[string]$deep.NeighborState;'Ping sent / received'="$($deep.Ping.Sent) / $($deep.Ping.Received)";'Packet loss'="$($deep.Ping.LossPercent)%";'Latency min / avg / max'="$($deep.Ping.Min) / $($deep.Ping.Avg) / $($deep.Ping.Max) ms";'ICMP TTL'=$deep.Ping.TTL;'TTL OS hint'=(Get-OsHintFromTtl $deep.Ping.TTL);'Adapter'=$(if($adapterInfoObj){$adapterInfoObj.AdapterName}else{''});'Local IPv4 / CIDR'=$(if($adapterInfoObj){"$($adapterInfoObj.IP)/$($adapterInfoObj.Prefix)"}else{''});'Gateway'=$(if($adapterInfoObj){$adapterInfoObj.Gateway}else{''});'First seen'=$hist.FirstSeen;'Last seen'=$hist.LastSeen;'Seen count'=$hist.SeenCount})
        $gridPorts.Rows.Clear()
        foreach($pc in @($deep.PortChecks)){
            $ri=$gridPorts.Rows.Add([string]$pc.Port,[string]$pc.Service,[string]$pc.State,[string]$pc.Detail)
            if($pc.State -eq 'Open'){$gridPorts.Rows[$ri].Cells['State'].Style.ForeColor=[Drawing.Color]::ForestGreen}
            elseif($pc.State -like 'Filtered*'){$gridPorts.Rows[$ri].Cells['State'].Style.ForeColor=[Drawing.Color]::DarkOrange}
            else{$gridPorts.Rows[$ri].Cells['State'].Style.ForeColor=[Drawing.Color]::DimGray}
        }
        $lines=New-Object System.Collections.Generic.List[string]
        [void]$lines.Add("OPEN TCP PORTS (common probe set): $($deep.PortText)")
        if($deep.HTTP){[void]$lines.Add("`r`nHTTP`r`n  URL: $($deep.HTTP.URL)`r`n  Status: $($deep.HTTP.Status)`r`n  Server: $($deep.HTTP.Server)`r`n  X-Powered-By: $($deep.HTTP.PoweredBy)`r`n  Title: $($deep.HTTP.Title)")}
        if($deep.SSDP -and ($deep.SSDP.Location -or $deep.SSDP.Server)){[void]$lines.Add("`r`nSSDP / UPnP`r`n  Server: $($deep.SSDP.Server)`r`n  ST: $($deep.SSDP.ST)`r`n  USN: $($deep.SSDP.USN)`r`n  Location: $($deep.SSDP.Location)")}
        if($deep.UPnP){[void]$lines.Add("  Friendly name: $($deep.UPnP.FriendlyName)`r`n  Manufacturer: $($deep.UPnP.Manufacturer)`r`n  Model: $($deep.UPnP.ModelName) $($deep.UPnP.ModelNumber)`r`n  Serial: $($deep.UPnP.SerialNumber)`r`n  Device type: $($deep.UPnP.DeviceType)`r`n  Manufacturer URL: $($deep.UPnP.ManufacturerURL)`r`n  Model URL: $($deep.UPnP.ModelURL)")}
        if($deep.NetBIOS){[void]$lines.Add("`r`nNETBIOS`r`n$($deep.NetBIOS)")}
        $txtProto.Text=$lines -join "`r`n"
        $records=@(Get-DeviceEvidenceRecords $d $deep);Set-EvidenceGrid $gridEvidence $records;$lblEvidenceSummary.Text=Get-EvidenceSummaryText $d $records
    }

    $showDeepError={
        param([string]$message)
        $err=(New-EvidenceRecord 'Deep analysis' 'ERROR' '' $message (Get-Date).ToString('s'))
        $records=@(Get-DeviceEvidenceRecords $d $lastDeep);$records=@(Merge-EvidenceRecords @($records,@($err)));Set-EvidenceGrid $gridEvidence $records;$lblEvidenceSummary.Text=Get-EvidenceSummaryText $d $records
        $deepState.Completed=$true;$deepState.Succeeded=$false;$deepState.LastError=$message
        Write-RuntimeLog 'DEVICE-DETAILS-DEEP' $message
    }

    $deepTimer.Add_Tick({
        try {
            if($deepState.ResultFile -and (Test-Path -LiteralPath $deepState.ResultFile)){
                $res=[IO.File]::ReadAllText($deepState.ResultFile)|ConvertFrom-Json -ErrorAction Stop
                if([string]$res.sessionId -ne $RuntimeSessionId -or [string]$res.runId -ne $deepState.RunId){return}
                if([bool]$res.success){$deepState.Completed=$true;$deepState.Succeeded=$true;$deepState.LastPhase='Completed';& $applyDeep $res.deep}else{& $showDeepError $(if($res.PSObject.Properties['error']){[string]$res.error}else{'Deep analysis worker failed.'})}
                & $cleanupDeep
                return
            }
            if($deepState.HeartbeatFile -and (Test-Path -LiteralPath $deepState.HeartbeatFile)){
                $hb=[IO.File]::ReadAllText($deepState.HeartbeatFile)|ConvertFrom-Json -ErrorAction Stop
                if([string]$hb.runId -eq $deepState.RunId){
                    $deepState.SeenHeartbeat=$true;$deepState.LastPhase=[string]$hb.phase
                    $age=((Get-Date)-([datetime]$hb.heartbeatAt)).TotalSeconds
                    if($age -gt 35){& $showDeepError "Deep worker heartbeat stale $([int]$age)s";& $cleanupDeep;return}
                    $btnDeep.Text="Đang phân tích: $([string]$hb.phase)"
                }
            }
            if(-not $deepState.SeenHeartbeat -and $deepState.StartedAt -and (((Get-Date)-[datetime]$deepState.StartedAt).TotalSeconds -gt [int]$deepState.StartupTimeoutSec)){
                & $showDeepError "Deep worker không phát heartbeat trong $($deepState.StartupTimeoutSec)s; đã dừng fail-closed.";& $cleanupDeep;return
            }
            if($deepState.Process -and $deepState.Process.HasExited -and -not(Test-Path -LiteralPath $deepState.ResultFile)){
                & $showDeepError "Deep worker kết thúc không có result (exit=$($deepState.Process.ExitCode)).";& $cleanupDeep
            }
        } catch {& $showDeepError $_.Exception.Message;& $cleanupDeep}
    })

    $f.Add_FormClosing({param($source,$evt);if($deepState.Busy){& $cleanupDeep}})
    $btnDeep.Add_Click({
        if($deepState.Busy){return}
        $deepState.Busy=$true;$deepState.Completed=$false;$deepState.Succeeded=$false;$deepState.LastPhase='Starting';$deepState.LastError='';$btnDeep.Enabled=$false;$btnClose.Enabled=$false;$btnDeep.Text='Đang khởi động worker...'
        try {
            if(-not(Test-Path -LiteralPath $TaskWorkerScript)){throw "Không tìm thấy Task Worker: $TaskWorkerScript"}
            $deepState.RunId=[guid]::NewGuid().ToString('N')
            $deepState.ConfigFile=Join-Path $DataDir ("RF-Network-Tool.deep-config.$RuntimeSessionId.$($deepState.RunId).json")
            $deepState.ResultFile=Join-Path $DataDir ("RF-Network-Tool.deep-result.$RuntimeSessionId.$($deepState.RunId).json")
            $deepState.HeartbeatFile=Join-Path $DataDir ("RF-Network-Tool.deep-heartbeat.$RuntimeSessionId.$($deepState.RunId).json")
            $idx=if($adapterInfoObj){[int]$adapterInfoObj.InterfaceIndex}else{0}
            $cfg=[ordered]@{schemaVersion=1;sessionId=$RuntimeSessionId;runId=$deepState.RunId;interfaceIndex=$idx;device=[ordered]@{IP=[string]$d.IP;MAC=[string]$d.MAC;Brand=[string]$d.Brand;Model=[string]$d.Model;Type=[string]$d.Type;Name=[string]$d.Name;NameSource=[string]$d.NameSource;OS=[string]$d.OS}}
            Write-TextAtomic $deepState.ConfigFile (ConvertTo-Json -InputObject $cfg -Depth 8)
            $ps=Get-SystemPowerShellPath;$ticks=Get-CurrentProcessStartTicks
            $processArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"`"$TaskWorkerScript`"",'-Mode','DEEP','-ConfigFile',"`"$($deepState.ConfigFile)`"",'-ResultFile',"`"$($deepState.ResultFile)`"",'-SessionId',$RuntimeSessionId,'-RunId',$deepState.RunId,'-ParentPid',[string]$PID,'-ParentStartTicks',[string]$ticks,'-HeartbeatFile',"`"$($deepState.HeartbeatFile)`"") -join ' '
            $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$ps;$psi.Arguments=$processArgs;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
            $deepState.Process=New-Object Diagnostics.Process;$deepState.Process.StartInfo=$psi;if(-not $deepState.Process.Start()){throw 'Không khởi động được Deep Analysis Worker.'}
            $deepState.StartedAt=Get-Date;$deepState.SeenHeartbeat=$false;$deepTimer.Start()
        } catch {& $showDeepError $_.Exception.Message;& $cleanupDeep}
    })
    $deepE2eTimer=$null
    $deepE2eState=[pscustomobject]@{Clicked=$false;StartedAt=$null;ObservedProgress=$false;Done=$false}
    if($script:DeepUiE2eMode){
        $deepE2eTimer=New-Object System.Windows.Forms.Timer;$deepE2eTimer.Interval=200
        $deepE2eTimer.Add_Tick({
            try {
                if(-not $deepE2eState.Clicked){
                    $deepE2eState.Clicked=$true;$deepE2eState.StartedAt=Get-Date
                    Write-DeepUiE2eResult 'RUNNING' 'button-click' 'Invoking the real Phân tích sâu / Refresh button callback.' $deepState
                    $btnDeep.PerformClick();return
                }
                if($deepState.LastPhase -and $deepState.LastPhase -notin @('Starting','')){$deepE2eState.ObservedProgress=$true}
                if($deepState.Completed -and -not $deepState.Busy){
                    $restored=($btnDeep.Enabled -and $btnDeep.Text -eq 'Phân tích sâu / Refresh')
                    $passed=($deepState.Succeeded -and $deepE2eState.ObservedProgress -and $restored)
                    if($passed){Write-DeepUiE2eResult 'PASS' 'completed' 'Deep UI callback observed worker progress, successful result, and restored controls.' $deepState}
                    else{Write-DeepUiE2eResult 'FAIL' 'completed' ("Succeeded={0}; ObservedProgress={1}; Restored={2}" -f $deepState.Succeeded,$deepE2eState.ObservedProgress,$restored) $deepState}
                    $deepE2eState.Done=$true;$deepE2eTimer.Stop();$f.Close();return
                }
                if($deepE2eState.StartedAt -and (((Get-Date)-[datetime]$deepE2eState.StartedAt).TotalSeconds -gt 45)){
                    Write-DeepUiE2eResult 'FAIL' 'timeout' ("Deep UI did not complete within 45s; button='{0}' busy={1}" -f $btnDeep.Text,$deepState.Busy) $deepState
                    if($deepState.Busy){& $cleanupDeep};$deepE2eState.Done=$true;$deepE2eTimer.Stop();$f.Close()
                }
            } catch {
                Write-DeepUiE2eResult 'FAIL' 'exception' $_.Exception.Message $deepState
                if($deepState.Busy){& $cleanupDeep};$deepE2eState.Done=$true;$deepE2eTimer.Stop();$f.Close()
            }
        })
        $f.Add_Shown({$deepE2eTimer.Start()})
        $f.Add_FormClosed({if($deepE2eTimer){try{$deepE2eTimer.Stop();$deepE2eTimer.Dispose()}catch{Write-RuntimeLog 'DEEP-UI-E2E-CLEANUP' $_.Exception.Message}}})
    }

    $btnCopy.Add_Click({
        $all="DEVICE DETAILS`r`n";foreach($r in $gOverview.Rows){if(-not $r.IsNewRow){$all+="$($r.Cells[0].Value): $($r.Cells[1].Value)`r`n"}};$all+="`r`nNETWORK`r`n";foreach($r in $gNetwork.Rows){if(-not $r.IsNewRow){$all+="$($r.Cells[0].Value): $($r.Cells[1].Value)`r`n"}};$all+="`r`nPROTOCOLS`r`n$($txtProto.Text)`r`n`r`nDISCOVERY EVIDENCE`r`n"
        foreach($er in $gridEvidence.Rows){if(-not $er.IsNewRow){$all+="$($er.Cells['Source'].Value) | $($er.Cells['State'].Value) | $($er.Cells['Value'].Value) | $($er.Cells['Detail'].Value) | $($er.Cells['ObservedAt'].Value)`r`n"}}
        [void](Set-ClipboardTextSafe $all 'Copy device details')
    })
    [void]$f.ShowDialog($script:MainForm)
}

function ConvertTo-SafeCsvField([string]$value) {
    if($null -eq $value){$value=''}
    # Prevent spreadsheet formula injection from network-advertised names/metadata.
    if($value -match '^[=+\-@]'){$value="'"+$value}
    return ('"'+($value -replace '"','""')+'"')
}

function Export-ScanCsv([System.Windows.Forms.DataGridView]$grid) {
    if ($grid.Rows.Count -eq 0) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = "network-scan-$((Get-Date).ToString('yyyyMMdd-HHmmss')).csv"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $headers = @()
        foreach($c in $grid.Columns){ $headers += (ConvertTo-SafeCsvField ([string]$c.HeaderText)) }
        [void]$lines.Add(($headers -join ','))
        foreach($r in $grid.Rows){
            if ($r.IsNewRow) { continue }
            $vals=@(); foreach($c in $grid.Columns){ $v=[string]$r.Cells[$c.Index].Value; $vals += (ConvertTo-SafeCsvField $v) }
            [void]$lines.Add(($vals -join ','))
        }
        [IO.File]::WriteAllLines($dlg.FileName,$lines.ToArray(),[Text.Encoding]::UTF8)
        [System.Windows.Forms.MessageBox]::Show("Đã xuất:`r`n$($dlg.FileName)",'Export CSV','OK','Information') | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Export error','OK','Error') | Out-Null }
}

function Get-NextDefaultTargetName {
    $used = @($script:TargetRows.Values | ForEach-Object { [string]$_.Alias })
    $i = 1
    while ($used -contains "Default $i") { $i++ }
    return "Default $i"
}

function Get-TargetEntriesSorted {
    return @($script:TargetRows.Values | Sort-Object Target)
}

function Save-Targets {
    try {
        $items = @()
        foreach ($entry in @(Get-TargetEntriesSorted)) {
            if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Target)) { continue }
            $items += [pscustomobject]@{
                Target = ([string]$entry.Target).Trim()
                Name = ([string]$entry.Alias).Trim()
            }
        }
        $payload = [ordered]@{
            schemaVersion = $script:TargetSchemaVersion
            targets = $items
        }
        $json = ConvertTo-Json -InputObject $payload -Depth 5
        Write-TextAtomic $TargetsJsonFile $json

        # Legacy text remains for backwards compatibility and easy recovery.
        $legacy = @($items | ForEach-Object { [string]$_.Target })
        $legacyText = if($legacy.Count){([string]::Join([Environment]::NewLine,$legacy)+[Environment]::NewLine)}else{''}
        Write-TextAtomic $TargetsFile $legacyText
    } catch {
        Write-RuntimeLog 'TARGETS-SAVE' ($_ | Out-String)
        try { Add-Log $pingLog "Không thể lưu danh sách IP/tên: $($_.Exception.Message)" } catch { }
    }
}

function Load-TargetEntries {
    $loaded = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    if (Test-Path -LiteralPath $TargetsJsonFile) {
        try {
            $raw = [IO.File]::ReadAllText($TargetsJsonFile)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                $sourceItems = @()

                # v2 schema: { schemaVersion: 2, targets: [...] }
                if ($parsed -and $parsed.PSObject.Properties['schemaVersion'] -and $parsed.PSObject.Properties['targets']) {
                    $sourceItems = @($parsed.targets)
                }
                # v1 legacy schema: top-level array [{Target,Name}, ...]
                else {
                    $sourceItems = @($parsed)
                }

                foreach ($item in $sourceItems) {
                    $target = ''
                    $name = ''
                    try { $target = ([string]$item.Target).Trim() } catch { }
                    try { $name = ([string]$item.Name).Trim() } catch { }
                    if ([string]::IsNullOrWhiteSpace($target)) { continue }
                    $key = $target.ToLowerInvariant()
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    [void]$loaded.Add([pscustomobject]@{ Target=$target; Name=$name })
                }
            }
        } catch {
            Write-RuntimeLog 'TARGETS-LOAD' ($_ | Out-String)
            [void](Backup-CorruptDataFile $TargetsJsonFile 'TARGETS-LOAD')
        }
    }

    if ($loaded.Count -eq 0 -and (Test-Path -LiteralPath $TargetsFile)) {
        try {
            foreach ($line in @(Get-Content -LiteralPath $TargetsFile -ErrorAction Stop)) {
                $target = ([string]$line).Trim()
                if ([string]::IsNullOrWhiteSpace($target)) { continue }
                $key = $target.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                [void]$loaded.Add([pscustomobject]@{ Target=$target; Name='' })
            }
        } catch {
            Write-RuntimeLog 'TARGETS-LEGACY-LOAD' ($_ | Out-String)
        }
    }

    return $loaded.ToArray()
}

function Get-MonitorInterval([object]$value) {
    $allowed=@(1,2,5,10,30)
    $n=5
    try{$n=[int]$value}catch{$n=5}
    if($allowed -contains $n){return $n}
    $best=5;$bestDelta=[int]::MaxValue
    foreach($candidate in $allowed){$delta=[Math]::Abs($candidate-$n);if($delta -lt $bestDelta){$best=$candidate;$bestDelta=$delta}}
    return $best
}

function New-MonitorStat([string]$target,[string]$name='') {
    return [pscustomobject]@{
        Target=$target;Name=$name;State='UNKNOWN';CurrentMs=$null;MinMs=$null;MaxMs=$null;SumMs=[double]0;
        SuccessCount=0;FailureCount=0;TotalCount=0;OutageCount=0;OnlineSince=$null;OfflineSince=$null;
        LastChange=$null;LastResultAt=$null;LastScheduledAt=$null;UptimeSec=[double]0;DowntimeSec=[double]0;LastDetail=''
    }
}

function Ensure-MonitorEntry([string]$target,[string]$name='') {
    if([string]::IsNullOrWhiteSpace($target)){return $null}
    $target=$target.Trim();$name=([string]$name).Trim()
    if(-not $script:MonitoringConfig.ContainsKey($target)){
        $script:MonitoringConfig[$target]=[pscustomobject]@{Target=$target;Name=$name;Enabled=$false;IntervalSec=5;Alert=$false}
    } elseif($name){$script:MonitoringConfig[$target].Name=$name}
    if(-not $script:MonitoringStats.ContainsKey($target)){$script:MonitoringStats[$target]=New-MonitorStat $target $name}
    elseif($name){$script:MonitoringStats[$target].Name=$name}
    return $script:MonitoringConfig[$target]
}

function Load-MonitoringConfig {
    $script:MonitoringConfig=@{}
    if(Test-Path -LiteralPath $MonitoringConfigFile){
        try {
            $raw=[IO.File]::ReadAllText($MonitoringConfigFile)
            if(-not [string]::IsNullOrWhiteSpace($raw)){
                $obj=$raw|ConvertFrom-Json -ErrorAction Stop
                foreach($e in @($obj.entries)){
                    $target=([string]$e.Target).Trim();if(-not $target){continue}
                    $name=([string]$e.Name).Trim();$enabled=$false;$alert=$false
                    try{$enabled=[bool]$e.Enabled}catch{};try{$alert=[bool]$e.Alert}catch{}
                    $script:MonitoringConfig[$target]=[pscustomobject]@{Target=$target;Name=$name;Enabled=$enabled;IntervalSec=(Get-MonitorInterval $e.IntervalSec);Alert=$alert}
                }
            }
        } catch {Write-RuntimeLog 'MONITOR-CONFIG-LOAD' ($_|Out-String);[void](Backup-CorruptDataFile $MonitoringConfigFile 'MONITOR-CONFIG-LOAD')}
    }
}

function Save-MonitoringConfig {
    try {
        $items=@($script:MonitoringConfig.Values|Sort-Object Target|ForEach-Object{[ordered]@{Target=[string]$_.Target;Name=[string]$_.Name;Enabled=[bool]$_.Enabled;IntervalSec=(Get-MonitorInterval $_.IntervalSec);Alert=[bool]$_.Alert}})
        $payload=[ordered]@{schemaVersion=1;entries=$items}
        Write-TextAtomic $MonitoringConfigFile (ConvertTo-Json -InputObject $payload -Depth 5)
    } catch {Write-RuntimeLog 'MONITOR-CONFIG-SAVE' ($_|Out-String)}
}

function Load-MonitoringHistory {
    $script:MonitoringEvents=New-Object System.Collections.Generic.List[object]
    if(Test-Path -LiteralPath $MonitoringHistoryFile){
        try {
            $raw=[IO.File]::ReadAllText($MonitoringHistoryFile)
            if(-not [string]::IsNullOrWhiteSpace($raw)){
                $obj=$raw|ConvertFrom-Json -ErrorAction Stop
                foreach($ev in @($obj.events)){
                    [void]$script:MonitoringEvents.Add([pscustomobject]@{At=[string]$ev.At;Target=[string]$ev.Target;Name=[string]$ev.Name;From=[string]$ev.From;To=[string]$ev.To;LatencyMs=$ev.LatencyMs;Detail=[string]$ev.Detail})
                }
            }
        } catch {Write-RuntimeLog 'MONITOR-HISTORY-LOAD' ($_|Out-String);[void](Backup-CorruptDataFile $MonitoringHistoryFile 'MONITOR-HISTORY-LOAD')}
    }
    while($script:MonitoringEvents.Count -gt $script:MonitoringMaxEvents){$script:MonitoringEvents.RemoveAt(0)}
}

function Save-MonitoringHistory {
    try {
        while($script:MonitoringEvents.Count -gt $script:MonitoringMaxEvents){$script:MonitoringEvents.RemoveAt(0)}
        $payload=[ordered]@{schemaVersion=1;maxEvents=$script:MonitoringMaxEvents;events=$script:MonitoringEvents.ToArray()}
        Write-TextAtomic $MonitoringHistoryFile (ConvertTo-Json -InputObject $payload -Depth 6)
    } catch {Write-RuntimeLog 'MONITOR-HISTORY-SAVE' ($_|Out-String)}
}

function Add-MonitoringEvent([string]$target,[string]$name,[string]$fromState,[string]$toState,$latencyMs,[string]$detail) {
    $ev=[pscustomobject]@{At=(Get-Date).ToString('o');Target=$target;Name=$name;From=$fromState;To=$toState;LatencyMs=$latencyMs;Detail=$detail}
    [void]$script:MonitoringEvents.Add($ev)
    while($script:MonitoringEvents.Count -gt $script:MonitoringMaxEvents){$script:MonitoringEvents.RemoveAt(0)}
    Save-MonitoringHistory
    try{Refresh-MonitorTimelineGrid}catch{}
}

function Format-MonitorDuration([double]$seconds) {
    if($seconds -lt 0){$seconds=0}
    $ts=[TimeSpan]::FromSeconds([Math]::Floor($seconds))
    if($ts.TotalDays -ge 1){return ('{0}d {1:00}:{2:00}:{3:00}' -f [int]$ts.TotalDays,$ts.Hours,$ts.Minutes,$ts.Seconds)}
    return ('{0:00}:{1:00}:{2:00}' -f $ts.Hours,$ts.Minutes,$ts.Seconds)
}

function Get-MonitorLossPercent($stat) {
    if(-not $stat -or [int]$stat.TotalCount -le 0){return 0.0}
    return [Math]::Round(([double]$stat.FailureCount*100.0/[double]$stat.TotalCount),1)
}

function Get-MonitorAverageMs($stat) {
    if(-not $stat -or [int]$stat.SuccessCount -le 0){return $null}
    return [Math]::Round(([double]$stat.SumMs/[double]$stat.SuccessCount),1)
}

function Get-MonitorDisplayedUptime($stat) {
    if(-not $stat){return 0.0}
    $v=[double]$stat.UptimeSec
    if($stat.State -eq 'ONLINE' -and $stat.LastResultAt){$v+=((Get-Date)-[datetime]$stat.LastResultAt).TotalSeconds}
    return [Math]::Max(0,$v)
}

function Get-MonitorDisplayedDowntime($stat) {
    if(-not $stat){return 0.0}
    $v=[double]$stat.DowntimeSec
    if($stat.State -eq 'OFFLINE' -and $stat.LastResultAt){$v+=((Get-Date)-[datetime]$stat.LastResultAt).TotalSeconds}
    return [Math]::Max(0,$v)
}

function Set-MonitorEnabledState([string]$target,[bool]$enabled) {
    if(-not $script:MonitoringConfig.ContainsKey($target)){return}
    $cfg=$script:MonitoringConfig[$target]
    $stat=if($script:MonitoringStats.ContainsKey($target)){$script:MonitoringStats[$target]}else{$null}
    $now=Get-Date
    if(-not $enabled -and [bool]$cfg.Enabled -and $stat -and $stat.LastResultAt){
        $elapsed=($now-[datetime]$stat.LastResultAt).TotalSeconds
        if($elapsed -gt 0){if($stat.State -eq 'ONLINE'){$stat.UptimeSec+=$elapsed}elseif($stat.State -eq 'OFFLINE'){$stat.DowntimeSec+=$elapsed}}
        $stat.LastResultAt=$null
    }
    if($enabled -and -not [bool]$cfg.Enabled -and $stat){$stat.LastScheduledAt=$null}
    $cfg.Enabled=$enabled
}

function Apply-MonitorPingResult($result) {
    if(-not $result){return}
    $target=[string]$result.Target;if(-not $target){return}
    if(-not $script:MonitoringConfig.ContainsKey($target)){return}
    $cfg=$script:MonitoringConfig[$target]
    if(-not [bool]$cfg.Enabled){return}
    if(-not $script:MonitoringStats.ContainsKey($target)){$script:MonitoringStats[$target]=New-MonitorStat $target ([string]$cfg.Name)}
    $stat=$script:MonitoringStats[$target]
    $now=Get-Date
    if($stat.LastResultAt){
        $elapsed=($now-[datetime]$stat.LastResultAt).TotalSeconds
        if($elapsed -gt 0){if($stat.State -eq 'ONLINE'){$stat.UptimeSec+=$elapsed}elseif($stat.State -eq 'OFFLINE'){$stat.DowntimeSec+=$elapsed}}
    }
    $oldState=[string]$stat.State
    $stat.TotalCount=[int]$stat.TotalCount+1
    if([bool]$result.Success){
        $ms=[double]$result.Time;$stat.SuccessCount=[int]$stat.SuccessCount+1;$stat.CurrentMs=$ms;$stat.SumMs=[double]$stat.SumMs+$ms
        if($null -eq $stat.MinMs -or $ms -lt [double]$stat.MinMs){$stat.MinMs=$ms};if($null -eq $stat.MaxMs -or $ms -gt [double]$stat.MaxMs){$stat.MaxMs=$ms}
        $stat.State='ONLINE';$stat.LastDetail='Success'
    } else {
        $stat.FailureCount=[int]$stat.FailureCount+1;$stat.CurrentMs=$null;$stat.State='OFFLINE';$stat.LastDetail=[string]$result.Detail
    }
    $stat.LastResultAt=$now
    $newState=[string]$stat.State
    if($oldState -ne $newState){
        $stat.LastChange=$now
        if($newState -eq 'ONLINE'){$stat.OnlineSince=$now;$stat.OfflineSince=$null}
        elseif($newState -eq 'OFFLINE'){$stat.OfflineSince=$now;$stat.OnlineSince=$null;if($oldState -eq 'ONLINE'){$stat.OutageCount=[int]$stat.OutageCount+1}}
        Add-MonitoringEvent $target ([string]$cfg.Name) $oldState $newState $stat.CurrentMs ([string]$stat.LastDetail)
        if([bool]$cfg.Alert -and $oldState -ne 'UNKNOWN'){
            try{
                $msg="[$($cfg.Name)] $target : $oldState -> $newState"
                [System.Media.SystemSounds]::Exclamation.Play()
                if($monitorAlertTip -and $form -and -not $form.IsDisposed){$monitorAlertTip.ToolTipIcon=if($newState -eq 'OFFLINE'){[System.Windows.Forms.ToolTipIcon]::Warning}else{[System.Windows.Forms.ToolTipIcon]::Info};$monitorAlertTip.Show($msg,$form,20,40,5000)}
            } catch {Write-RuntimeLog 'MONITOR-ALERT' ($_|Out-String)}
        }
    }
    try{Update-MonitorGridRow $target}catch{}
    try{
        if($script:TargetRows.ContainsKey($target)){
            $entry=$script:TargetRows[$target];$row=Get-TargetGridRow $target
            if($row){
                if($newState -eq 'ONLINE'){$statusText="ONLINE | $([int]$result.Time) ms | TTL=$($result.TTL)";$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::ForestGreen}
                else{$statusText="OFFLINE | $($result.Detail)";$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::Firebrick}
                $row.Cells['PingStatus'].Value=$statusText;$entry.Status=$statusText
            }
        }
    } catch {}
}

function Sync-MonitoringWithTargets([switch]$Save) {
    foreach($entry in @(Get-TargetEntriesSorted)){[void](Ensure-MonitorEntry ([string]$entry.Target) ([string]$entry.Alias))}
    # Remove config rows whose target was deliberately deleted from PING.
    $valid=@{};foreach($entry in @(Get-TargetEntriesSorted)){$valid[[string]$entry.Target]=$true}
    foreach($key in @($script:MonitoringConfig.Keys)){if(-not $valid.ContainsKey([string]$key)){$script:MonitoringConfig.Remove($key);$script:MonitoringStats.Remove($key)}}
    if($Save){Save-MonitoringConfig}
    try{Refresh-MonitorGrid}catch{}
}

function Update-MonitorAlias([string]$target,[string]$name) {
    if(-not $script:MonitoringConfig.ContainsKey($target)){[void](Ensure-MonitorEntry $target $name)}
    else{$script:MonitoringConfig[$target].Name=$name;if($script:MonitoringStats.ContainsKey($target)){$script:MonitoringStats[$target].Name=$name}}
    Save-MonitoringConfig
    try{Update-MonitorGridRow $target}catch{}
}

function Remove-MonitorTarget([string]$target) {
    if($script:MonitoringConfig.ContainsKey($target)){$script:MonitoringConfig.Remove($target)}
    if($script:MonitoringStats.ContainsKey($target)){$script:MonitoringStats.Remove($target)}
    Save-MonitoringConfig
    try{Refresh-MonitorGrid}catch{}
}

function Get-PingAliasForTarget([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) { return '' }
    try {
        if ($script:TargetRows.ContainsKey($target)) {
            $a=[string]$script:TargetRows[$target].Alias
            if ($a -and $a -notmatch '^Default\s+\d+$') { return $a }
        }
    } catch { }
    return ''
}

function Normalize-DiscoveredName([string]$name) {
    if([string]::IsNullOrWhiteSpace($name)){return ''}
    $n=($name -replace '[\x00-\x1F\x7F]',' ').Trim().TrimEnd('.')
    $n=[regex]::Replace($n,'\s+',' ')
    # Keep meaningful host label while removing common local suffixes from display.
    $n=$n -replace '(?i)\.(local|lan)$',''
    if($n.Length -gt 253){$n=$n.Substring(0,253)}
    return $n.Trim()
}

function Read-DnsName([byte[]]$bytes,[ref]$offset,[int]$depth=0) {
    if(-not $bytes -or $depth -gt 10){return ''}
    $pos=[int]$offset.Value
    $labels=New-Object System.Collections.Generic.List[string]
    $next=$pos
    $jumped=$false
    while($pos -lt $bytes.Length){
        $len=[int]$bytes[$pos]
        if($len -eq 0){
            $pos++
            if(-not $jumped){$next=$pos}
            break
        }
        if(($len -band 0xC0) -eq 0xC0){
            if(($pos+1) -ge $bytes.Length){break}
            $ptr=(($len -band 0x3F) -shl 8) -bor [int]$bytes[$pos+1]
            if(-not $jumped){$next=$pos+2}
            $tmp=$ptr
            $suffix=Read-DnsName $bytes ([ref]$tmp) ($depth+1)
            if($suffix){[void]$labels.Add($suffix)}
            $jumped=$true
            break
        }
        if($len -lt 1 -or $len -gt 63 -or ($pos+1+$len) -gt $bytes.Length){break}
        $label=[Text.Encoding]::UTF8.GetString($bytes,$pos+1,$len)
        [void]$labels.Add($label)
        $pos += (1+$len)
        if(-not $jumped){$next=$pos}
    }
    $offset.Value=$next
    return ([string]::Join('.', $labels.ToArray())).Trim('.')
}

function Get-InitialDeviceName([string]$ip,[string]$resolvedName,[string]$gateway='',[string]$mac='') {
    $n=Normalize-DiscoveredName $resolvedName
    if($n){return [pscustomobject]@{Name=$n;Source='System DNS'}}
    $alias=Get-PingAliasForTarget $ip
    if($alias){return [pscustomobject]@{Name=$alias;Source='PING alias'}}
    try {
        $cleanMac=Format-Mac $mac
        $key=Get-DeviceKey $ip $cleanMac
        if($key -like 'MAC:*' -and $script:DeviceHistory.ContainsKey($key)){
            $h=$script:DeviceHistory[$key]
            $source=''
            if($h.PSObject.Properties['LastNameSource']){$source=([string]$h.LastNameSource).Trim()}
            # Legacy v1.5.1 history has no provenance and is intentionally not auto-applied.
            if($h.LastName -and $source -and $source -notlike 'History*'){
                return [pscustomobject]@{Name=[string]$h.LastName;Source='History (MAC match)'}
            }
        }
    } catch { }
    return [pscustomobject]@{Name='';Source='Unknown'}
}

function Stop-DiscoveryWorker {
    try {
        if($script:DiscoveryProcess -and -not $script:DiscoveryProcess.HasExited){
            try{$script:DiscoveryProcess.Kill()}catch{}
            try{$script:DiscoveryProcess.WaitForExit(500)}catch{}
        }
    } catch { }
    if($script:DiscoveryProcess){try{$script:DiscoveryProcess.Dispose()}catch{}}
    $script:DiscoveryProcess=$null
    $script:DiscoveryRunId=''
}

function Start-DiscoveryWorker([array]$records,[string]$gateway='',[string]$localIp='',[string]$discoveryProfile='BALANCED',[int]$durationSec=20) {
    Stop-DiscoveryWorker
    if(-not (Test-Path -LiteralPath $DiscoveryWorkerScript)){Write-RuntimeLog 'NAME-DISCOVERY' "Missing worker: $DiscoveryWorkerScript";return $false}
    try {
        $p=if([string]::IsNullOrWhiteSpace($discoveryProfile)){'BALANCED'}else{$discoveryProfile.ToUpperInvariant()}
        if($p -notin @('FAST','BALANCED','DEEP')){$p='BALANCED'}
        $script:DiscoveryDurationSec=[Math]::Max(5,[Math]::Min(120,$durationSec))
        $script:DiscoveryRunId=[guid]::NewGuid().ToString('N')
        $script:DiscoveryTargetsFile=Join-Path $DataDir ("RF-Network-Tool.discovery-targets.$RuntimeSessionId.$($script:DiscoveryRunId).json")
        $script:DiscoveryCacheFile=Join-Path $DataDir ("RF-Network-Tool.discovery-cache.$RuntimeSessionId.$($script:DiscoveryRunId).json")
        $targets=@()
        foreach($r in @($records)){
            if($r -and $r.IP){
                $targets += [pscustomobject]@{
                    IP=[string]$r.IP
                    CurrentName=[string]$r.Name
                    CurrentSource=[string]$r.NameSource
                    Status=[string]$r.Status
                }
            }
        }
        if($targets.Count -eq 0){return $false}
        $targetJson=ConvertTo-Json -InputObject $targets -Depth 4; Write-TextAtomic $DiscoveryTargetsFile $targetJson
        Remove-Item -LiteralPath $DiscoveryCacheFile -Force -ErrorAction SilentlyContinue
        $workerLog=Join-Path $RuntimeLogDir ("discovery-worker-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        $argList=@(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$DiscoveryWorkerScript+'"'),
            '-TargetsFile',('"'+$DiscoveryTargetsFile+'"'),'-CacheFile',('"'+$DiscoveryCacheFile+'"'),'-RunId',$script:DiscoveryRunId,
            '-DurationSec',[string]$script:DiscoveryDurationSec,'-DiscoveryProfile',$p,'-Gateway',('"'+$gateway+'"'),'-LocalIP',('"'+$localIp+'"'),'-LogFile',('"'+$workerLog+'"'),
            '-ParentPid',[string]$PID,'-ParentStartTicks',[string](Get-CurrentProcessStartTicks)
        )
        $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script:DiscoveryProcess=Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden -PassThru
        $script:DiscoveryStartedAt=Get-Date
        $script:DiscoveryAppliedCount=0
        Write-RuntimeLog 'NAME-DISCOVERY' "Started PID=$($script:DiscoveryProcess.Id) Targets=$($targets.Count) Profile=$p Duration=$($script:DiscoveryDurationSec)s"
        return $true
    } catch {
        Write-RuntimeLog 'NAME-DISCOVERY' ($_ | Out-String)
        Stop-DiscoveryWorker
        return $false
    }
}

function Apply-DiscoveryCacheToGrid {
    $changed=0
    if(-not (Test-Path -LiteralPath $DiscoveryCacheFile)){return 0}
    try {
        $raw=Get-Content -LiteralPath $DiscoveryCacheFile -Raw -ErrorAction Stop
        if([string]::IsNullOrWhiteSpace($raw)){return 0}
        $parsed=$raw | ConvertFrom-Json
        if(-not $parsed){return 0}
        if($script:DiscoveryRunId){
            if((-not $parsed.PSObject.Properties['runId']) -or ([string]$parsed.runId -ne $script:DiscoveryRunId)){
                Write-RuntimeLog 'NAME-DISCOVERY-STALE' "Ignored cache runId=$([string]$parsed.runId); expected=$($script:DiscoveryRunId)"
                return 0
            }
        }
        $items=if($parsed -and $parsed.PSObject.Properties['records']){@($parsed.records)}else{@($parsed)}
        $lookup=@{}
        foreach($it in $items){if($it.IP){$lookup[[string]$it.IP]=$it}}
        $weak=@('Unknown','PING alias','History','History (MAC match)')
        $gateway='';$localIp=''
        try {
            $arr=@($cmbScanAdapter.Tag)
            if($cmbScanAdapter.SelectedIndex -ge 0 -and $cmbScanAdapter.SelectedIndex -lt $arr.Count){
                $aInfo=Get-AdapterIPv4Info $arr[$cmbScanAdapter.SelectedIndex]
                if($aInfo){$gateway=[string]$aInfo.Gateway;$localIp=[string]$aInfo.IP}
            }
        } catch { }
        foreach($row in $gridScan.Rows){
            $rec=$row.Tag;if(-not $rec){continue}
            $ip=[string]$rec.IP;if(-not $lookup.ContainsKey($ip)){continue}
            $it=$lookup[$ip]
            $ev=@($it.Evidence)
            if($rec.PSObject.Properties['DiscoveryEvidence']){$rec.DiscoveryEvidence=$ev}else{$rec | Add-Member -NotePropertyName DiscoveryEvidence -NotePropertyValue $ev -Force}
            if(($weak -notcontains [string]$rec.NameSource) -and $rec.Name){continue}
            $newName=Normalize-DiscoveredName ([string]$it.Name);if(-not $newName){continue}
            if($newName -eq [string]$rec.Name -and [string]$it.Source -eq [string]$rec.NameSource){continue}
            $oldName=[string]$rec.Name;$oldSource=[string]$rec.NameSource
            $vendor=Get-VendorFromMac ([string]$rec.MAC)
            $fp=Get-DeviceFingerprint $ip ([string]$rec.MAC) $newName $vendor $gateway $localIp
            $rec.Name=$newName;$rec.NameSource=[string]$it.Source;$rec.Brand=$fp.Brand;$rec.Type=$fp.Type;$rec.Model=$fp.Model;$rec.OS=$fp.OS;$rec.Confidence=$fp.Confidence
            $row.Cells['Name'].Value=$rec.Name;$row.Cells['Source'].Value=$rec.NameSource;$row.Cells['Brand'].Value=$rec.Brand;$row.Cells['Type'].Value=$rec.Type;$row.Cells['Model'].Value=$rec.Model
            [void](Update-DeviceHistory $rec);$changed++
            try{Write-RuntimeLog 'NAME-DISCOVERY' "APPLY IP=$ip OLD='$oldName'/$oldSource NEW='$($rec.Name)'/$($rec.NameSource)"}catch{}
        }
        if($changed -gt 0){Save-DeviceHistory;$script:DiscoveryAppliedCount += $changed}
    } catch { Write-RuntimeLog 'NAME-DISCOVERY-CACHE' ($_ | Out-String) }
    return $changed
}

function Format-Mac([string]$mac) {
    $c=($mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
    if($c.Length -ne 12){return $mac}
    return (($c -split '(.{2})' | Where-Object {$_}) -join '-')
}

function Write-ScanLog([string]$path,[string]$text) {
    try { [IO.File]::AppendAllText($path,("[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))] $text"+[Environment]::NewLine),[Text.Encoding]::UTF8) } catch { }
}

$form = New-Object System.Windows.Forms.Form
$script:MainForm=$form
$form.Text = "RF & Network Diagnostic Tool - Portable v$AppVersion Full QA / CI-E2E"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1120, 780)
$form.MinimumSize = New-Object System.Drawing.Size(980, 680)
$form.Font = New-Font 9
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point(18, 6)
$form.Controls.Add($tabs)

# ---------------- TAB 1: PING ----------------
$tabPing = New-Object System.Windows.Forms.TabPage
$tabPing.Text = 'PING'
$tabPing.Padding = New-Object System.Windows.Forms.Padding(12)
$tabs.TabPages.Add($tabPing) | Out-Null

$pingTop = New-Object System.Windows.Forms.Panel
$pingTop.Dock = 'Top'
$pingTop.Height = 58
$tabPing.Controls.Add($pingTop)

$lblIp = New-Object System.Windows.Forms.Label
$lblIp.Text = 'IP / Hostname:'
$lblIp.Location = New-Object System.Drawing.Point(4, 7)
$lblIp.AutoSize = $true
$pingTop.Controls.Add($lblIp)

$txtIp = New-Object System.Windows.Forms.TextBox
$txtIp.Location = New-Object System.Drawing.Point(105, 3)
$txtIp.Size = New-Object System.Drawing.Size(310, 27)
$pingTop.Controls.Add($txtIp)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = '+ Lưu IP'
$btnAdd.Location = New-Object System.Drawing.Point(425, 1)
$btnAdd.Size = New-Object System.Drawing.Size(95, 31)
$pingTop.Controls.Add($btnAdd)

$btnPingAll = New-Object System.Windows.Forms.Button
$btnPingAll.Text = 'Ping tất cả'
$btnPingAll.Location = New-Object System.Drawing.Point(530, 1)
$btnPingAll.Size = New-Object System.Drawing.Size(105, 31)
$pingTop.Controls.Add($btnPingAll)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = 'Ví dụ: 192.168.1.1 hoặc router.local'
$lblHint.Location = New-Object System.Drawing.Point(105, 33)
$lblHint.AutoSize = $true
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$pingTop.Controls.Add($lblHint)

$splitPing = New-Object System.Windows.Forms.SplitContainer
$splitPing.Dock = 'Fill'
$splitPing.Orientation = 'Horizontal'
$splitPing.SplitterDistance = 320
$splitPing.Panel1MinSize = 180
$splitPing.Panel2MinSize = 130
$tabPing.Controls.Add($splitPing)
$splitPing.BringToFront()

$gridPing = New-Object System.Windows.Forms.DataGridView
$gridPing.Dock = 'Fill'
$gridPing.AllowUserToAddRows = $false
$gridPing.AllowUserToDeleteRows = $false
$gridPing.AllowUserToResizeRows = $false
$gridPing.RowHeadersVisible = $false
$gridPing.MultiSelect = $false
$gridPing.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$gridPing.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$gridPing.BackgroundColor = [System.Drawing.Color]::White
$gridPing.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$gridPing.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnKeystrokeOrF2
$gridPing.AutoGenerateColumns = $false
$splitPing.Panel1.Controls.Add($gridPing)

$colTarget = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTarget.Name = 'Target'
$colTarget.HeaderText = 'IP / HOSTNAME'
$colTarget.ReadOnly = $true
$colTarget.FillWeight = 32
[void]$gridPing.Columns.Add($colTarget)

$colAlias = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colAlias.Name = 'Alias'
$colAlias.HeaderText = 'TÊN GỢI NHỚ (double-click/F2 để sửa)'
$colAlias.ReadOnly = $false
$colAlias.FillWeight = 28
[void]$gridPing.Columns.Add($colAlias)

$colPingStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPingStatus.Name = 'PingStatus'
$colPingStatus.HeaderText = 'TRẠNG THÁI'
$colPingStatus.ReadOnly = $true
$colPingStatus.FillWeight = 24
[void]$gridPing.Columns.Add($colPingStatus)

$colPingAction = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colPingAction.Name = 'PingAction'
$colPingAction.HeaderText = 'PING'
$colPingAction.Text = 'Ping'
$colPingAction.UseColumnTextForButtonValue = $true
$colPingAction.FillWeight = 8
[void]$gridPing.Columns.Add($colPingAction)

$colDeleteAction = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colDeleteAction.Name = 'DeleteAction'
$colDeleteAction.HeaderText = 'XÓA'
$colDeleteAction.Text = 'Xóa'
$colDeleteAction.UseColumnTextForButtonValue = $true
$colDeleteAction.FillWeight = 8
[void]$gridPing.Columns.Add($colDeleteAction)

$pingLog = New-Object System.Windows.Forms.TextBox
$pingLog.Dock = 'Fill'
$pingLog.Multiline = $true
$pingLog.ReadOnly = $true
$pingLog.ScrollBars = 'Vertical'
$pingLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$pingLog.BackColor = [System.Drawing.Color]::White
$splitPing.Panel2.Controls.Add($pingLog)

function Get-TargetGridRow([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) { return $null }
    foreach ($r in $gridPing.Rows) {
        if ($r.IsNewRow) { continue }
        if ([string]$r.Tag -eq $target) { return $r }
    }
    return $null
}

function Add-TargetRow([string]$target, [string]$alias = '') {
    $target = ([string]$target).Trim()
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }

    # Case-insensitive duplicate guard while preserving the user's original target text.
    foreach($existing in @($script:TargetRows.Keys)) {
        if ([string]::Equals([string]$existing,$target,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    $alias = ([string]$alias).Trim()
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = Get-NextDefaultTargetName }

    $script:TargetRows[$target] = [pscustomobject]@{
        Target = $target
        Alias = $alias
        Status = 'Chưa kiểm tra'
    }

    $idx = $gridPing.Rows.Add($target,$alias,'Chưa kiểm tra','Ping','Xóa')
    $row = $gridPing.Rows[$idx]
    $row.Tag = $target
    $row.Cells['PingStatus'].Style.ForeColor = [System.Drawing.Color]::DimGray
    return $true
}

function Invoke-TargetPing([string]$target) {
    if (-not $script:TargetRows.ContainsKey($target)) { return }
    if($script:PingTargetBusy.ContainsKey($target)){
        $busyId=[string]$script:PingTargetBusy[$target]
        if($script:PingRequests.ContainsKey($busyId) -and [string]$script:PingRequests[$busyId].Kind -eq 'MONITOR'){$script:PingTargetBusy.Remove($target)}else{return}
    }
    $entry=$script:TargetRows[$target]
    try {
        Set-TargetPingPending $target
        $id=Enqueue-PingRequest 'PING_SINGLE' @([pscustomobject]@{Target=$target;Alias=[string]$entry.Alias}) 1500 1
        if(-not $id){throw 'Không tạo được yêu cầu Ping.'}
    } catch {
        $row=Get-TargetGridRow $target
        if($row){$row.Cells['PingStatus'].Value="ERROR | $($_.Exception.Message)";$row.Cells['PingStatus'].Style.ForeColor=[Drawing.Color]::Firebrick}
        Write-RuntimeLog 'PING-SINGLE' ($_ | Out-String)
    }
}

$gridPing.Add_CellContentClick({
    param($source,$evt)
    if ($evt.RowIndex -lt 0 -or $evt.ColumnIndex -lt 0) { return }
    $row = $source.Rows[$evt.RowIndex]
    $target = [string]$row.Tag
    $columnName = [string]$source.Columns[$evt.ColumnIndex].Name

    if ($columnName -eq 'PingAction') {
        Invoke-TargetPing $target
        return
    }

    if ($columnName -eq 'DeleteAction') {
        if ($script:TargetRows.ContainsKey($target)) {
            $displayName = [string]$script:TargetRows[$target].Alias
            $script:TargetRows.Remove($target)
            $source.Rows.RemoveAt($evt.RowIndex)
            Save-Targets
            Remove-MonitorTarget $target
            Add-Log $pingLog "Đã xóa [$displayName] $target"
        }
    }
})

$gridPing.Add_CellDoubleClick({
    param($source,$evt)
    if ($evt.RowIndex -ge 0 -and $evt.ColumnIndex -ge 0 -and $source.Columns[$evt.ColumnIndex].Name -eq 'Alias') {
        $source.CurrentCell = $source.Rows[$evt.RowIndex].Cells['Alias']
        $source.BeginEdit($true)
    }
})

$gridPing.Add_CellEndEdit({
    param($source,$evt)
    if ($evt.RowIndex -lt 0 -or $source.Columns[$evt.ColumnIndex].Name -ne 'Alias') { return }
    $row = $source.Rows[$evt.RowIndex]
    $target = [string]$row.Tag
    if (-not $script:TargetRows.ContainsKey($target)) { return }

    $oldName = [string]$script:TargetRows[$target].Alias
    $newName = ([string]$row.Cells['Alias'].Value).Trim()
    if ([string]::IsNullOrWhiteSpace($newName)) { $newName = $oldName }
    if ([string]::IsNullOrWhiteSpace($newName)) { $newName = Get-NextDefaultTargetName }

    $row.Cells['Alias'].Value = $newName
    if ($newName -ne $oldName) {
        $script:TargetRows[$target].Alias = $newName
        Save-Targets
        Update-MonitorAlias $target $newName
        Add-Log $pingLog "Đổi tên ${target}: '$oldName' -> '$newName'"
    }
})

$btnAdd.Add_Click({
    $t = $txtIp.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) {
        [System.Windows.Forms.MessageBox]::Show('Hãy nhập IP hoặc hostname.', 'Thiếu địa chỉ', 'OK', 'Information') | Out-Null
        return
    }

    $added = Add-TargetRow $t
    if ($added) {
        Save-Targets
        [void](Ensure-MonitorEntry $t ([string]$script:TargetRows[$t].Alias));Save-MonitoringConfig;Refresh-MonitorGrid
        Add-Log $pingLog "Đã lưu [$($script:TargetRows[$t].Alias)] $t"
    } else {
        Add-Log $pingLog "Địa chỉ '$t' đã tồn tại trong danh sách."
    }
    $txtIp.Clear()
    $txtIp.Focus()
})
$txtIp.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnAdd.PerformClick(); $_.SuppressKeyPress=$true } })

$btnPingAll.Add_Click({
    if($script:PingAllBusy){return}
        foreach($entry in @(Get-TargetEntriesSorted)){
        $target=[string]$entry.Target
        if($script:PingTargetBusy.ContainsKey($target)){$busyId=[string]$script:PingTargetBusy[$target];if($script:PingRequests.ContainsKey($busyId) -and [string]$script:PingRequests[$busyId].Kind -eq 'MONITOR'){$script:PingTargetBusy.Remove($target)}}
    }
    $entries=@(Get-TargetEntriesSorted | Where-Object {-not $script:PingTargetBusy.ContainsKey([string]$_.Target)})
    if($entries.Count -eq 0){return}
    $script:PingAllBusy=$true;$btnPingAll.Enabled=$false
    try {
        foreach($entry in $entries){if(-not $script:PingTargetBusy.ContainsKey([string]$entry.Target)){Set-TargetPingPending ([string]$entry.Target)}}
        $id=Enqueue-PingRequest 'PING_ALL' $entries 1500 24
        if(-not $id){throw 'Không tạo được yêu cầu Ping tất cả.'}
    } catch {
        $script:PingAllBusy=$false;$btnPingAll.Enabled=$true
        Write-RuntimeLog 'PING-ALL' ($_ | Out-String)
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Ping tất cả','OK','Warning')|Out-Null
    }
})

# ---------------- TAB 2: RF / RJ45 ----------------
$tabRf = New-Object System.Windows.Forms.TabPage
$tabRf.Text = 'RF / RJ45'
$tabRf.Padding = New-Object System.Windows.Forms.Padding(12)
$tabs.TabPages.Add($tabRf) | Out-Null

$rfMain = New-Object System.Windows.Forms.TableLayoutPanel
$rfMain.Dock = 'Fill'
$rfMain.ColumnCount = 2
$rfMain.RowCount = 1
$rfMain.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 47)))
$rfMain.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 53)))
$tabRf.Controls.Add($rfMain)

$left = New-Object System.Windows.Forms.Panel
$left.Dock = 'Fill'
$left.AutoScroll = $true
$rfMain.Controls.Add($left,0,0)

$right = New-Object System.Windows.Forms.Panel
$right.Dock = 'Fill'
$rfMain.Controls.Add($right,1,0)

$grpAdapter = New-Object System.Windows.Forms.GroupBox
$grpAdapter.Text = 'Card mạng / cổng RJ45'
$grpAdapter.Location = New-Object System.Drawing.Point(5,5)
$grpAdapter.Size = New-Object System.Drawing.Size(390, 245)
$left.Controls.Add($grpAdapter)

$cmbAdapter = New-Object System.Windows.Forms.ComboBox
$cmbAdapter.DropDownStyle = 'DropDownList'
$cmbAdapter.Location = New-Object System.Drawing.Point(15, 28)
$cmbAdapter.Size = New-Object System.Drawing.Size(270, 27)
$grpAdapter.Controls.Add($cmbAdapter)

$btnRefreshAdapter = New-Object System.Windows.Forms.Button
$btnRefreshAdapter.Text = 'Làm mới'
$btnRefreshAdapter.Location = New-Object System.Drawing.Point(295, 26)
$btnRefreshAdapter.Size = New-Object System.Drawing.Size(78, 29)
$grpAdapter.Controls.Add($btnRefreshAdapter)

$adapterInfo = New-Object System.Windows.Forms.TextBox
$adapterInfo.Location = New-Object System.Drawing.Point(15, 67)
$adapterInfo.Size = New-Object System.Drawing.Size(358, 160)
$adapterInfo.Multiline = $true
$adapterInfo.ReadOnly = $true
$adapterInfo.Font = New-Object System.Drawing.Font('Consolas', 9)
$adapterInfo.BackColor = [System.Drawing.Color]::White
$grpAdapter.Controls.Add($adapterInfo)

$grpDevice = New-Object System.Windows.Forms.GroupBox
$grpDevice.Text = 'Thiết bị RF qua Ethernet / UDP'
$grpDevice.Location = New-Object System.Drawing.Point(5, 262)
$grpDevice.Size = New-Object System.Drawing.Size(390, 390)
$left.Controls.Add($grpDevice)

$lblRfIp = New-Object System.Windows.Forms.Label
$lblRfIp.Text = 'IP/Host RF:'
$lblRfIp.Location = New-Object System.Drawing.Point(15, 31)
$lblRfIp.AutoSize = $true
$grpDevice.Controls.Add($lblRfIp)

$txtRfIp = New-Object System.Windows.Forms.TextBox
$txtRfIp.Text = '192.168.1.20'
$txtRfIp.Location = New-Object System.Drawing.Point(100, 27)
$txtRfIp.Size = New-Object System.Drawing.Size(180, 27)
$grpDevice.Controls.Add($txtRfIp)

$btnRfPing = New-Object System.Windows.Forms.Button
$btnRfPing.Text = 'Ping RF'
$btnRfPing.Location = New-Object System.Drawing.Point(290, 25)
$btnRfPing.Size = New-Object System.Drawing.Size(82, 30)
$grpDevice.Controls.Add($btnRfPing)

$lblUdpPort = New-Object System.Windows.Forms.Label
$lblUdpPort.Text = 'UDP local port:'
$lblUdpPort.Location = New-Object System.Drawing.Point(15, 76)
$lblUdpPort.AutoSize = $true
$grpDevice.Controls.Add($lblUdpPort)

$numUdpPort = New-Object System.Windows.Forms.NumericUpDown
$numUdpPort.Minimum = 1
$numUdpPort.Maximum = 65535
$numUdpPort.Value = 5000
$numUdpPort.Location = New-Object System.Drawing.Point(120, 72)
$numUdpPort.Size = New-Object System.Drawing.Size(100, 27)
$grpDevice.Controls.Add($numUdpPort)

$btnUdpStart = New-Object System.Windows.Forms.Button
$btnUdpStart.Text = 'Start UDP'
$btnUdpStart.Location = New-Object System.Drawing.Point(230, 69)
$btnUdpStart.Size = New-Object System.Drawing.Size(70, 31)
$grpDevice.Controls.Add($btnUdpStart)

$btnUdpStop = New-Object System.Windows.Forms.Button
$btnUdpStop.Text = 'Stop'
$btnUdpStop.Location = New-Object System.Drawing.Point(307, 69)
$btnUdpStop.Size = New-Object System.Drawing.Size(65, 31)
$grpDevice.Controls.Add($btnUdpStop)

$chkUdpFilter = New-Object System.Windows.Forms.CheckBox
$chkUdpFilter.Text = 'Chỉ nhận packet từ IP/Host RF ở trên'
$chkUdpFilter.Location = New-Object System.Drawing.Point(15, 112)
$chkUdpFilter.AutoSize = $true
$chkUdpFilter.Checked = $true
$grpDevice.Controls.Add($chkUdpFilter)

$lblUdpState = New-Object System.Windows.Forms.Label
$lblUdpState.Text = 'UDP : STOPPED'
$lblUdpState.Location = New-Object System.Drawing.Point(15, 143)
$lblUdpState.Size = New-Object System.Drawing.Size(350, 22)
$lblUdpState.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$lblUdpState.ForeColor = [System.Drawing.Color]::DimGray
$grpDevice.Controls.Add($lblUdpState)

$lblConn = New-Object System.Windows.Forms.Label
$lblConn.Text = 'PING : Chưa kiểm tra'
$lblConn.Location = New-Object System.Drawing.Point(15, 174)
$lblConn.Size = New-Object System.Drawing.Size(350, 22)
$lblConn.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$grpDevice.Controls.Add($lblConn)

$lblRssi = New-Object System.Windows.Forms.Label
$lblRssi.Text = 'RSSI / SNR : chờ UDP payload'
$lblRssi.Location = New-Object System.Drawing.Point(15, 207)
$lblRssi.Size = New-Object System.Drawing.Size(350, 25)
$lblRssi.ForeColor = [System.Drawing.Color]::DimGray
$grpDevice.Controls.Add($lblRssi)

$lblProto = New-Object System.Windows.Forms.Label
$lblProto.Text = 'Tự nhận dạng RSSI/SNR nếu payload có dạng RSSI=-67, SNR=18 hoặc JSON tương tự. Payload nhị phân sẽ hiện HEX để phân tích tiếp.'
$lblProto.Location = New-Object System.Drawing.Point(15, 238)
$lblProto.Size = New-Object System.Drawing.Size(350, 58)
$lblProto.ForeColor = [System.Drawing.Color]::DimGray
$grpDevice.Controls.Add($lblProto)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Auto ping RF mỗi 3 giây'
$chkAuto.Location = New-Object System.Drawing.Point(15, 302)
$chkAuto.AutoSize = $true
$grpDevice.Controls.Add($chkAuto)

$btnCopyPacket = New-Object System.Windows.Forms.Button
$btnCopyPacket.Text = 'Copy packet gần nhất'
$btnCopyPacket.Location = New-Object System.Drawing.Point(15, 334)
$btnCopyPacket.Size = New-Object System.Drawing.Size(150, 31)
$grpDevice.Controls.Add($btnCopyPacket)

$btnClearRfLog = New-Object System.Windows.Forms.Button
$btnClearRfLog.Text = 'Xóa log'
$btnClearRfLog.Location = New-Object System.Drawing.Point(175, 334)
$btnClearRfLog.Size = New-Object System.Drawing.Size(90, 31)
$grpDevice.Controls.Add($btnClearRfLog)

$lblUdpRaw = New-Object System.Windows.Forms.Label
$lblUdpRaw.Text = 'Gói UDP gần nhất (TEXT + HEX)'
$lblUdpRaw.Location = New-Object System.Drawing.Point(5, 8)
$lblUdpRaw.AutoSize = $true
$lblUdpRaw.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$right.Controls.Add($lblUdpRaw)

$txtUdpRaw = New-Object System.Windows.Forms.TextBox
$txtUdpRaw.Location = New-Object System.Drawing.Point(5, 34)
$txtUdpRaw.Anchor = 'Top,Left,Right'
$txtUdpRaw.Size = New-Object System.Drawing.Size(430, 205)
$txtUdpRaw.Multiline = $true
$txtUdpRaw.ReadOnly = $true
$txtUdpRaw.ScrollBars = 'Both'
$txtUdpRaw.WordWrap = $false
$txtUdpRaw.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$txtUdpRaw.BackColor = [System.Drawing.Color]::White
$right.Controls.Add($txtUdpRaw)

$lblRfLog = New-Object System.Windows.Forms.Label
$lblRfLog.Text = 'Kết quả / UDP Log'
$lblRfLog.Location = New-Object System.Drawing.Point(5, 248)
$lblRfLog.AutoSize = $true
$lblRfLog.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$right.Controls.Add($lblRfLog)

$rfLog = New-Object System.Windows.Forms.TextBox
$rfLog.Location = New-Object System.Drawing.Point(5, 274)
$rfLog.Anchor = 'Top,Bottom,Left,Right'
$rfLog.Size = New-Object System.Drawing.Size(430, 290)
$rfLog.Multiline = $true
$rfLog.ReadOnly = $true
$rfLog.ScrollBars = 'Vertical'
$rfLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$rfLog.BackColor = [System.Drawing.Color]::White
$right.Controls.Add($rfLog)

function Format-Speed([long]$bits) {
    if ($bits -ge 1000000000) { return ('{0:N1} Gbps' -f ($bits/1GB)) }
    if ($bits -ge 1000000) { return ('{0:N0} Mbps' -f ($bits/1MB)) }
    if ($bits -ge 1000) { return ('{0:N0} Kbps' -f ($bits/1KB)) }
    return "$bits bps"
}

function Refresh-Adapters {
    $cmbAdapter.Items.Clear()
    $script:Adapters = @()
    try {
        $all = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
               Where-Object { $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback } |
               Sort-Object Name
        foreach ($a in $all) {
            $script:Adapters += $a
            [void]$cmbAdapter.Items.Add("$($a.Name) [$($a.OperationalStatus)]")
        }
        if ($cmbAdapter.Items.Count -gt 0) { $cmbAdapter.SelectedIndex = 0 }
    } catch {
        $adapterInfo.Text = "Không đọc được adapter:`r`n$($_.Exception.Message)"
    }
}

function Show-AdapterInfo {
    if ($cmbAdapter.SelectedIndex -lt 0 -or $cmbAdapter.SelectedIndex -ge $script:Adapters.Count) { return }
    try {
        $a = $script:Adapters[$cmbAdapter.SelectedIndex]
        $p = $a.GetIPProperties()
        $ipv4 = @($p.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.Address.ToString() }) -join ', '
        $gw = @($p.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.Address.ToString() }) -join ', '
        $dns = @($p.DnsAddresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() }) -join ', '
        $adapterInfo.Text = @"
Name     : $($a.Name)
Type     : $($a.NetworkInterfaceType)
Status   : $($a.OperationalStatus)
Speed    : $(Format-Speed $a.Speed)
MAC      : $(Format-Mac ($a.GetPhysicalAddress().ToString()))
IPv4     : $ipv4
Gateway  : $gw
DNS      : $dns
"@
    } catch {
        $adapterInfo.Text = "Lỗi đọc adapter:`r`n$($_.Exception.Message)"
    }
}

$btnRefreshAdapter.Add_Click({ Refresh-Adapters; Add-Log $rfLog 'Đã làm mới danh sách card mạng.' })
$cmbAdapter.Add_SelectedIndexChanged({ Show-AdapterInfo })

$btnRfPing.Add_Click({
    if($script:RfPingBusy){return}
    $hostName=$txtRfIp.Text.Trim()
    if(-not $hostName){return}
    $script:RfPingBusy=$true;$btnRfPing.Enabled=$false
    $lblConn.Text='PING : Đang kiểm tra nền...';$lblConn.ForeColor=[Drawing.Color]::DarkOrange
    try {
        $id=Enqueue-PingRequest 'RF' @([pscustomobject]@{Target=$hostName;Alias='RF'}) 1500 1
        if(-not $id){throw 'Không tạo được yêu cầu RF Ping.'}
    } catch {
        $script:RfPingBusy=$false;$btnRfPing.Enabled=$true;$lblConn.Text="PING : ERROR | $($_.Exception.Message)";$lblConn.ForeColor=[Drawing.Color]::Firebrick
        Write-RuntimeLog 'RF-PING' ($_ | Out-String)
    }
})

$btnUdpStart.Add_Click({ Start-UdpListener })
$btnUdpStop.Add_Click({ Stop-UdpListener; Add-Log $rfLog 'UDP listener đã dừng.' })
$btnCopyPacket.Add_Click({
    if ($script:LastUdpPacket) {
        [void](Set-ClipboardTextSafe $script:LastUdpPacket 'Copy UDP packet')
        Add-Log $rfLog 'Đã copy packet gần nhất vào Clipboard.'
    }
})
$btnClearRfLog.Add_Click({ $rfLog.Clear() })

$udpTimer = New-Object System.Windows.Forms.Timer
$udpTimer.Interval = 100
$udpTimer.Add_Tick({
    try {
        Process-UdpPackets
    } catch {
        $msg = $_.Exception.Message
        try { Write-RuntimeLog 'UDP-TIMER' $msg } catch { }
        try { Add-Log $rfLog "UDP timer error: $msg" } catch { }
        try { Stop-UdpListener } catch { }
        try { $udpTimer.Stop() } catch { }
    }
})
$udpTimer.Start()

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ if ($chkAuto.Checked) { $btnRfPing.PerformClick() } })
$timer.Start()


# ---------------- TAB 3: NETWORK SCAN ----------------
$tabScan = New-Object System.Windows.Forms.TabPage
$tabScan.Text = 'NETWORK SCAN'
$tabScan.Padding = New-Object System.Windows.Forms.Padding(10)
$tabs.TabPages.Add($tabScan) | Out-Null

$scanTop = New-Object System.Windows.Forms.Panel
$scanTop.Dock = 'Top'
$scanTop.Height = 176
$tabScan.Controls.Add($scanTop)

$lblScanAdapter = New-Object System.Windows.Forms.Label
$lblScanAdapter.Text = 'Card mạng:'
$lblScanAdapter.Location = New-Object System.Drawing.Point(4, 10)
$lblScanAdapter.AutoSize = $true
$scanTop.Controls.Add($lblScanAdapter)

$cmbScanAdapter = New-Object System.Windows.Forms.ComboBox
$cmbScanAdapter.DropDownStyle = 'DropDownList'
$cmbScanAdapter.Location = New-Object System.Drawing.Point(76, 6)
$cmbScanAdapter.Size = New-Object System.Drawing.Size(270, 27)
$scanTop.Controls.Add($cmbScanAdapter)

$lblCidr = New-Object System.Windows.Forms.Label
$lblCidr.Text = 'CIDR:'
$lblCidr.Location = New-Object System.Drawing.Point(360, 10)
$lblCidr.AutoSize = $true
$scanTop.Controls.Add($lblCidr)

$txtCidr = New-Object System.Windows.Forms.TextBox
$txtCidr.Location = New-Object System.Drawing.Point(405, 6)
$txtCidr.Size = New-Object System.Drawing.Size(145, 27)
$scanTop.Controls.Add($txtCidr)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = 'Scan / Rescan'
$btnScan.Location = New-Object System.Drawing.Point(562, 4)
$btnScan.Size = New-Object System.Drawing.Size(110, 31)
$scanTop.Controls.Add($btnScan)

$btnStopScan = New-Object System.Windows.Forms.Button
$btnStopScan.Text = 'Stop'
$btnStopScan.Location = New-Object System.Drawing.Point(680, 4)
$btnStopScan.Size = New-Object System.Drawing.Size(65, 31)
$btnStopScan.Enabled = $false
$scanTop.Controls.Add($btnStopScan)

$btnExportScan = New-Object System.Windows.Forms.Button
$btnExportScan.Text = 'Export CSV'
$btnExportScan.Location = New-Object System.Drawing.Point(753, 4)
$btnExportScan.Size = New-Object System.Drawing.Size(92, 31)
$scanTop.Controls.Add($btnExportScan)

$btnUpdateOui = New-Object System.Windows.Forms.Button
$btnUpdateOui.Text = 'Update IEEE OUI'
$btnUpdateOui.Location = New-Object System.Drawing.Point(853, 4)
$btnUpdateOui.Size = New-Object System.Drawing.Size(105, 31)
$scanTop.Controls.Add($btnUpdateOui)

$chkRouteAware = New-Object System.Windows.Forms.CheckBox
$chkRouteAware.Text='Route-aware'
$chkRouteAware.Location=New-Object System.Drawing.Point(965,8)
$chkRouteAware.Size=New-Object System.Drawing.Size(100,24)
$chkRouteAware.Checked=$false
$scanTop.Controls.Add($chkRouteAware)

$txtScanSearch = New-Object System.Windows.Forms.TextBox
$txtScanSearch.Location = New-Object System.Drawing.Point(76, 48)
$txtScanSearch.Size = New-Object System.Drawing.Size(270, 27)
$scanTop.Controls.Add($txtScanSearch)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'Tìm:'
$lblSearch.Location = New-Object System.Drawing.Point(4, 52)
$lblSearch.AutoSize = $true
$scanTop.Controls.Add($lblSearch)

$btnDeviceDetails = New-Object System.Windows.Forms.Button
$btnDeviceDetails.Text = 'Chi tiết'
$btnDeviceDetails.Location = New-Object System.Drawing.Point(360, 45)
$btnDeviceDetails.Size = New-Object System.Drawing.Size(85, 30)
$btnDeviceDetails.Enabled = $false
$scanTop.Controls.Add($btnDeviceDetails)

$lblScanStatus = New-Object System.Windows.Forms.Label
$lblScanStatus.Text = 'Sẵn sàng. Chọn card mạng và nhấn Scan / Rescan.'
# Dedicated full-width status row: avoids clipping at 125/150% DPI and long runtime messages.
$lblScanStatus.Location = New-Object System.Drawing.Point(4, 80)
$lblScanStatus.Size = New-Object System.Drawing.Size(1065, 24)
$lblScanStatus.Anchor = 'Top,Left,Right'
$lblScanStatus.AutoEllipsis = $true
$lblScanStatus.ForeColor = [System.Drawing.Color]::DimGray
$scanTop.Controls.Add($lblScanStatus)

$lblTimeout = New-Object System.Windows.Forms.Label
$lblTimeout.Text = 'Base timeout:'
$lblTimeout.Location = New-Object System.Drawing.Point(458, 52)
$lblTimeout.AutoSize = $true
$scanTop.Controls.Add($lblTimeout)
$numScanTimeout = New-Object System.Windows.Forms.NumericUpDown
$numScanTimeout.Minimum=100;$numScanTimeout.Maximum=2000;$numScanTimeout.Increment=50;$numScanTimeout.Value=350
$numScanTimeout.Location = New-Object System.Drawing.Point(545,47);$numScanTimeout.Size=New-Object System.Drawing.Size(70,27)
$scanTop.Controls.Add($numScanTimeout)
$lblTimeoutMs=New-Object System.Windows.Forms.Label;$lblTimeoutMs.Text='ms';$lblTimeoutMs.Location=New-Object System.Drawing.Point(620,52);$lblTimeoutMs.AutoSize=$true;$scanTop.Controls.Add($lblTimeoutMs)

$lblScanProfile=New-Object System.Windows.Forms.Label
$lblScanProfile.Text='Profile:'
$lblScanProfile.Location=New-Object System.Drawing.Point(660,52)
$lblScanProfile.AutoSize=$true
$scanTop.Controls.Add($lblScanProfile)
$cmbScanProfile=New-Object System.Windows.Forms.ComboBox
$cmbScanProfile.DropDownStyle='DropDownList'
$cmbScanProfile.Location=New-Object System.Drawing.Point(712,47)
$cmbScanProfile.Size=New-Object System.Drawing.Size(112,27)
[void]$cmbScanProfile.Items.AddRange([object[]]@('FAST','BALANCED','DEEP'))
$cmbScanProfile.SelectedItem='BALANCED'
$scanTop.Controls.Add($cmbScanProfile)
$lblProfileHint=New-Object System.Windows.Forms.Label
$lblProfileHint.Text='Cân bằng tốc độ / độ phủ'
$lblProfileHint.Location=New-Object System.Drawing.Point(835,52)
$lblProfileHint.Size=New-Object System.Drawing.Size(230,20)
$lblProfileHint.AutoEllipsis=$true
$lblProfileHint.ForeColor=[Drawing.Color]::DimGray
$scanTop.Controls.Add($lblProfileHint)
$cmbScanProfile.Add_SelectedIndexChanged({
    $p=[string]$cmbScanProfile.SelectedItem
    $lblProfileHint.Text=switch($p){
        'FAST' {'Nhanh: ICMP + ARP, discovery tên ngắn'}
        'DEEP' {'Sâu: timeout dài hơn, discovery đầy đủ'}
        default {'Cân bằng tốc độ / độ phủ'}
    }
})


$lblAdapterInfo=New-Object System.Windows.Forms.Label
$lblAdapterInfo.Text='Local: - | Gateway: - | MAC: - | Link: -'
$lblAdapterInfo.Location=New-Object System.Drawing.Point(4,108);$lblAdapterInfo.Size=New-Object System.Drawing.Size(1065,22);$lblAdapterInfo.Anchor='Top,Left,Right';$lblAdapterInfo.AutoEllipsis=$true;$lblAdapterInfo.ForeColor=[Drawing.Color]::DimGray
$scanTop.Controls.Add($lblAdapterInfo)

$scanProgress=New-Object System.Windows.Forms.ProgressBar
$scanProgress.Location=New-Object System.Drawing.Point(4,138);$scanProgress.Size=New-Object System.Drawing.Size(630,23);$scanProgress.Minimum=0;$scanProgress.Maximum=100;$scanProgress.Value=0
$scanTop.Controls.Add($scanProgress)
$lblScanSummary=New-Object System.Windows.Forms.Label
$lblScanSummary.Text='Online 0 | Seen 0 | Total 0'
$lblScanSummary.Location=New-Object System.Drawing.Point(646,140);$lblScanSummary.Size=New-Object System.Drawing.Size(420,22);$lblScanSummary.ForeColor=[Drawing.Color]::DimGray
$scanTop.Controls.Add($lblScanSummary)

function Update-ScanHeaderLayout {
    try {
        $w=[Math]::Max(700,[int]$scanTop.ClientSize.Width)
        $right=[Math]::Max(120,$w-8)
        $lblScanStatus.Width=[Math]::Max(180,$right-$lblScanStatus.Left)
        $lblAdapterInfo.Width=[Math]::Max(180,$right-$lblAdapterInfo.Left)
        $progressWidth=[Math]::Max(300,[int]([Math]::Floor(($w-24)*0.60)))
        $scanProgress.Width=$progressWidth
        $lblScanSummary.Left=$scanProgress.Left+$progressWidth+12
        $lblScanSummary.Width=[Math]::Max(160,$w-$lblScanSummary.Left-8)
        $lblProfileHint.Width=[Math]::Max(80,$w-$lblProfileHint.Left-8)
    } catch { }
}
$scanTop.Add_Resize({ Update-ScanHeaderLayout })

$gridScan = New-Object System.Windows.Forms.DataGridView
$gridScan.Dock = 'Fill'
$gridScan.ReadOnly = $true
$gridScan.AllowUserToAddRows = $false
$gridScan.AllowUserToDeleteRows = $false
$gridScan.AllowUserToResizeRows = $false
$gridScan.SelectionMode = 'FullRowSelect'
$gridScan.MultiSelect = $false
$gridScan.AutoSizeColumnsMode = 'Fill'
$gridScan.RowHeadersVisible = $false
$gridScan.BackgroundColor = [System.Drawing.Color]::White
$gridScan.BorderStyle = 'Fixed3D'
$tabScan.Controls.Add($gridScan)
$gridScan.BringToFront()

$cols = @(
    @('Status','STATUS',65), @('Type','TYPE',100), @('Brand','BRAND',110), @('Model','MODEL',105),
    @('Name','NAME',150), @('Source','NAME SOURCE',105), @('IP','IP ADDRESS',95), @('MAC','MAC ADDRESS',115),
    @('Latency','PING',55), @('LastUpdate','LAST UPDATE',75)
)
foreach($c in $cols){
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name=$c[0]; $col.HeaderText=$c[1]; $col.FillWeight=[single]$c[2]
    [void]$gridScan.Columns.Add($col)
}

$gridScan.ShowCellToolTips=$true
$tip=New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($gridScan,'Double-click một thiết bị để xem chi tiết và phân tích sâu.')
$ctxScan=New-Object System.Windows.Forms.ContextMenuStrip
$miDetail=$ctxScan.Items.Add('Xem chi tiết thiết bị')
$miCopyIp=$ctxScan.Items.Add('Copy IP')
$gridScan.ContextMenuStrip=$ctxScan
$miDetail.Add_Click({if($gridScan.CurrentRow){$ai=Update-ScanAdapterDefaults;Show-DeviceDetails $gridScan.CurrentRow $ai}})
$miCopyIp.Add_Click({try{if($gridScan.CurrentRow){[void](Set-ClipboardTextSafe ([string]$gridScan.CurrentRow.Cells['IP'].Value) 'Copy IP')}}catch{Write-RuntimeLog 'COPY-IP' ($_ | Out-String)}})
$gridScan.Add_CellDoubleClick({param($source,$evt);if($evt.RowIndex -ge 0){$ai=Update-ScanAdapterDefaults;Show-DeviceDetails $gridScan.Rows[$evt.RowIndex] $ai}})
$gridScan.Add_KeyDown({param($source,$evt);if($evt.KeyCode -eq [Windows.Forms.Keys]::Enter -and $gridScan.CurrentRow){$evt.SuppressKeyPress=$true;$ai=Update-ScanAdapterDefaults;Show-DeviceDetails $gridScan.CurrentRow $ai}})

function Update-ScanAdapterDefaults {
    try {
        $arr=@($cmbScanAdapter.Tag)
        if($cmbScanAdapter.SelectedIndex -lt 0 -or $cmbScanAdapter.SelectedIndex -ge $arr.Count){return $null}
        $adapter=$arr[$cmbScanAdapter.SelectedIndex];$ai=Get-AdapterIPv4Info $adapter
        if(-not $ai){$txtCidr.Text='';$lblScanStatus.Text='Card mạng không có IPv4 hợp lệ.';$lblAdapterInfo.Text='Local: - | Gateway: - | MAC: - | Link: -';return $null}
        $prefix=[int]$ai.Prefix
        $txtCidr.Text=if($prefix -lt 22){Get-NetworkCidr $ai.IP 24}else{Get-NetworkCidr $ai.IP $prefix}
        if($prefix -lt 22){$lblScanStatus.Text="Sẵn sàng. CIDR đã tự giới hạn /24 để quét nhanh."}else{$lblScanStatus.Text="Sẵn sàng. Nhấn Scan / Rescan."}
        $mac=Format-Mac ($adapter.GetPhysicalAddress().ToString())
        $speedText=if($adapter.Speed -gt 0){if($adapter.Speed -ge 1000000000){"$([Math]::Round($adapter.Speed/1000000000,2)) Gbps"}else{"$([Math]::Round($adapter.Speed/1000000,0)) Mbps"}}else{'-'}
        $lblAdapterInfo.Text="Local $($ai.IP)/$prefix | Gateway $($ai.Gateway) | MAC $mac | Link $speedText | $($adapter.NetworkInterfaceType)"
        return [pscustomobject]@{Adapter=$adapter;AdapterName=$adapter.Name;IP=$ai.IP;Prefix=$ai.Prefix;Gateway=$ai.Gateway;InterfaceIndex=$ai.InterfaceIndex;MAC=$mac;LinkSpeed=$speedText}
    } catch {$txtCidr.Text='';$lblScanStatus.Text="Không xác định được CIDR: $($_.Exception.Message)";$lblAdapterInfo.Text='Local: - | Gateway: - | MAC: - | Link: -';return $null}
}

function Get-AdapterPreferenceScore($adapter) {
    try {
        $ai=Get-AdapterIPv4Info $adapter
        if(-not $ai){return -100000}
        $score=0
        if(-not [string]::IsNullOrWhiteSpace([string]$ai.Gateway)){$score+=10000}
        $identity=("$($adapter.Name) $($adapter.Description)").ToLowerInvariant()
        if($identity -match 'vmware|virtualbox|hyper-v|vethernet|bluetooth|loopback|tap|tun|vpn|tailscale|zerotier|npcap'){$score-=3000}
        if($adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Wireless80211){$score+=1000}
        elseif($adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Ethernet){$score+=800}
        if($adapter.Speed -gt 0){$score += [Math]::Min(500,[int]($adapter.Speed/10000000))}
        return $score
    } catch { return -100000 }
}

function Refresh-ScanAdapters {
    $cmbScanAdapter.Items.Clear();$cmbScanAdapter.Tag=@()
    try {
        $arr=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {$_.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up -and $_.NetworkInterfaceType -ne [Net.NetworkInformation.NetworkInterfaceType]::Loopback -and (Get-AdapterIPv4Info $_)} | Sort-Object Name)
        $cmbScanAdapter.Tag=$arr
        foreach($a in $arr){[void]$cmbScanAdapter.Items.Add("$($a.Name) [$($a.NetworkInterfaceType)]")}
        if($cmbScanAdapter.Items.Count -gt 0){
            $bestIndex=0;$bestScore=[int]::MinValue
            for($i=0;$i -lt $arr.Count;$i++){
                $score=Get-AdapterPreferenceScore $arr[$i]
                if($score -gt $bestScore){$bestScore=$score;$bestIndex=$i}
            }
            $cmbScanAdapter.SelectedIndex=$bestIndex
            [void](Update-ScanAdapterDefaults)
        }else{$txtCidr.Text='';$lblScanStatus.Text='Không tìm thấy card mạng IPv4 đang hoạt động.'}
    } catch {$lblScanStatus.Text="Không đọc được adapter: $($_.Exception.Message)"}
}

$cmbScanAdapter.Add_SelectedIndexChanged({[void](Update-ScanAdapterDefaults)})

$txtScanSearch.Add_TextChanged({
    try {
        $q=$txtScanSearch.Text.Trim().ToLowerInvariant()
        foreach($row in $gridScan.Rows){
            if([string]::IsNullOrWhiteSpace($q)){ $row.Visible=$true; continue }
            $all=''; foreach($cell in $row.Cells){ $all += ' ' + [string]$cell.Value }
            $shouldShow=$all.ToLowerInvariant().Contains($q)
            if($row -eq $gridScan.CurrentRow -and -not $shouldShow){$gridScan.ClearSelection()}
            $row.Visible=$shouldShow
        }
    } catch { Write-RuntimeLog 'SCAN-FILTER' ($_ | Out-String) }
})


function Get-ScanProfileSettings([string]$scanProfile,[int]$baseTimeout,[int]$targetCount) {
    $p=if([string]::IsNullOrWhiteSpace($scanProfile)){'BALANCED'}else{$scanProfile.ToUpperInvariant()}
    if($p -notin @('FAST','BALANCED','DEEP')){$p='BALANCED'}
    $base=[Math]::Max(100,[Math]::Min(2000,$baseTimeout))
    $count=[Math]::Max(1,$targetCount)
    switch($p){
        'FAST' {
            $fast=[Math]::Min(450,$base)
            $ping=if($count -le 64){64}else{128}
            $arp=if($count -le 64){32}else{64}
            return [pscustomobject]@{Profile='FAST';FastPingTimeoutMs=$fast;RetryEnabled=$false;RetryPingTimeoutMs=$fast;PingConcurrency=$ping;ArpConcurrency=$arp;DiscoveryDurationSec=8;DiscoveryMode='QUICK'}
        }
        'DEEP' {
            $fast=[Math]::Max(300,[Math]::Min(1500,$base))
            $retry=[Math]::Max(1200,[Math]::Min(3000,$base*3))
            $ping=if($count -le 64){32}elseif($count -le 256){64}else{96}
            $arp=if($count -le 64){24}elseif($count -le 256){32}else{48}
            return [pscustomobject]@{Profile='DEEP';FastPingTimeoutMs=$fast;RetryEnabled=$true;RetryPingTimeoutMs=$retry;PingConcurrency=$ping;ArpConcurrency=$arp;DiscoveryDurationSec=45;DiscoveryMode='DEEP'}
        }
        default {
            $fast=[Math]::Max(150,[Math]::Min(900,$base))
            $retry=[Math]::Max(700,[Math]::Min(2000,$base*2))
            $ping=if($count -le 64){48}elseif($count -le 256){96}else{128}
            $arp=if($count -le 64){32}elseif($count -le 256){48}else{64}
            return [pscustomobject]@{Profile='BALANCED';FastPingTimeoutMs=$fast;RetryEnabled=$true;RetryPingTimeoutMs=$retry;PingConcurrency=$ping;ArpConcurrency=$arp;DiscoveryDurationSec=20;DiscoveryMode='BALANCED'}
        }
    }
}

function Stop-ScanWorker([bool]$force=$false) {
    try {
        if($script:ScanActive){
            try{[IO.File]::WriteAllText($ScanCancelFile,'cancel',[Text.Encoding]::ASCII)}catch{}
        }
        if($force -and $script:ScanProcess -and -not $script:ScanProcess.HasExited){
            try{$script:ScanProcess.Kill()}catch{}
            try{$script:ScanProcess.WaitForExit(700)}catch{}
        }
    } catch { }
    if($force -and $script:ScanProcess){try{$script:ScanProcess.Dispose()}catch{};$script:ScanProcess=$null}
}

function Start-ScanWorker([array]$targets,$ai,$adapter,$settings) {
    if(-not (Test-Path -LiteralPath $ScanWorkerScript)){
        throw "Thiếu scan worker: $ScanWorkerScript"
    }
    if(-not $settings){throw 'Scan profile settings bị trống.'}

    Stop-ScanWorker $true
    Remove-Item -LiteralPath $ScanStateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ScanCancelFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ScanConfigFile -Force -ErrorAction SilentlyContinue

    $script:ScanRunId=[guid]::NewGuid().ToString('N')
    $script:ScanConfigFile=Join-Path $DataDir ("RF-Network-Tool.scan-config.$RuntimeSessionId.$($script:ScanRunId).json")
    $script:ScanStateFile=Join-Path $DataDir ("RF-Network-Tool.scan-state.$RuntimeSessionId.$($script:ScanRunId).json")
    $script:ScanCancelFile=Join-Path $DataDir ("RF-Network-Tool.scan-cancel.$RuntimeSessionId.$($script:ScanRunId).flag")
    $cfg=[ordered]@{
        schemaVersion=3
        RunId=$script:ScanRunId
        Targets=@($targets)
        Profile=[string]$settings.Profile
        LocalIP=[string]$ai.IP
        LocalMAC=(Format-Mac ($adapter.GetPhysicalAddress().ToString()))
        InterfaceIndex=[int]$ai.InterfaceIndex
        FastPingTimeoutMs=[int]$settings.FastPingTimeoutMs
        RetryEnabled=[bool]$settings.RetryEnabled
        RetryPingTimeoutMs=[int]$settings.RetryPingTimeoutMs
        PingConcurrency=[int]$settings.PingConcurrency
        ArpConcurrency=[int]$settings.ArpConcurrency
        DiscoveryDurationSec=[int]$settings.DiscoveryDurationSec
        DiscoveryMode=[string]$settings.DiscoveryMode
    }
    Write-TextAtomic $ScanConfigFile (ConvertTo-Json -InputObject $cfg -Depth 5)
    $script:ScanLogFile=Join-Path $RuntimeLogDir ("scan-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log")
    $scopeLog=if($script:ScanContext -and $script:ScanContext.PSObject.Properties['Scopes']){[string]::Join(',',@($script:ScanContext.Scopes))}else{$txtCidr.Text.Trim()}
    $routeAwareLog=if($script:ScanContext -and $script:ScanContext.PSObject.Properties['RouteAware']){[bool]$script:ScanContext.RouteAware}else{$false}
    Write-ScanLog $script:ScanLogFile "START ENGINE=v$AppVersion Profile=$($settings.Profile) CIDR=$($txtCidr.Text.Trim()) RouteAware=$routeAwareLog Scopes=$scopeLog Adapter=$($adapter.Name) Local=$($ai.IP)/$($ai.Prefix) Gateway=$($ai.Gateway) FastPing=$($settings.FastPingTimeoutMs)ms Retry=$($settings.RetryEnabled)/$($settings.RetryPingTimeoutMs)ms PingConcurrency=$($settings.PingConcurrency) ArpConcurrency=$($settings.ArpConcurrency)"

    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$psExe
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $parentTicks=Get-CurrentProcessStartTicks
    $psi.Arguments=('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigFile "{1}" -StateFile "{2}" -CancelFile "{3}" -LogFile "{4}" -ParentPid {5} -ParentStartTicks {6}' -f $ScanWorkerScript,$ScanConfigFile,$ScanStateFile,$ScanCancelFile,$script:ScanLogFile,$PID,$parentTicks)
    $proc=New-Object Diagnostics.Process
    $proc.StartInfo=$psi
    if(-not $proc.Start()){throw 'Không thể khởi động Network Scan worker.'}
    $script:ScanProcess=$proc
    return $true
}

function Read-ScanStateSafe {
    if(-not (Test-Path -LiteralPath $ScanStateFile)){return $null}
    try {
        $raw=[IO.File]::ReadAllText($ScanStateFile)
        if([string]::IsNullOrWhiteSpace($raw)){return $null}
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        # Atomic writer normally prevents partial reads; tolerate one bad poll.
        Write-RuntimeLog 'SCAN-STATE-READ' $_.Exception.Message
        return $null
    }
}

function Get-ScanIpKey([string]$ip) {
    if([string]::IsNullOrWhiteSpace($ip)){return ''}
    return $ip.Trim().ToLowerInvariant()
}

function Find-ScanGridRowByIp([string]$ip) {
    $key=Get-ScanIpKey $ip
    if(-not $key -or $null -eq $gridScan){return $null}
    foreach($candidate in $gridScan.Rows){
        if($candidate.IsNewRow){continue}
        $candidateKey=Get-ScanIpKey ([string]$candidate.Cells['IP'].Value)
        if($candidateKey -eq $key){return $candidate}
    }
    return $null
}

function Repair-ScanGridIndex {
    if($null -eq $gridScan){return 0}
    $script:ScanRowByIp=@{}
    $script:ScanRecordByIp=@{}
    $duplicateIndexes=New-Object 'System.Collections.Generic.List[int]'
    for($i=0;$i -lt $gridScan.Rows.Count;$i++){
        $candidate=$gridScan.Rows[$i]
        if($candidate.IsNewRow){continue}
        $key=Get-ScanIpKey ([string]$candidate.Cells['IP'].Value)
        if(-not $key){continue}
        if($script:ScanRowByIp.ContainsKey($key)){
            [void]$duplicateIndexes.Add($i)
            continue
        }
        $script:ScanRowByIp[$key]=$candidate
        if($null -ne $candidate.Tag){$script:ScanRecordByIp[$key]=$candidate.Tag}
    }
    for($j=$duplicateIndexes.Count-1;$j -ge 0;$j--){$gridScan.Rows.RemoveAt([int]$duplicateIndexes[$j])}
    $script:ScanResults=@($script:ScanRecordByIp.Values | Sort-Object IP)
    if($duplicateIndexes.Count -gt 0){Write-RuntimeLog 'SCAN-INTEGRITY' "Removed $($duplicateIndexes.Count) duplicate grid row(s); canonicalRows=$($script:ScanRowByIp.Count)"}
    return $duplicateIndexes.Count
}

function Apply-ScanStateToGrid($state) {
    if($null -eq $state -or $null -eq $script:ScanContext){return 0}
    [void](Repair-ScanGridIndex)
    $ctx=$script:ScanContext
    $changed=0
    foreach($it in @($state.results)){
        $ip=([string]$it.IP).Trim()
        $key=Get-ScanIpKey $ip
        if(-not $key){continue}
        $status=[string]$it.Status
        if($status -eq 'Unknown'){continue}
        $mac=Format-Mac ([string]$it.MAC)
        $lat=[string]$it.Latency
        if([string]::IsNullOrWhiteSpace($lat)){$lat=if($status -eq 'Online'){'-'}else{'No ICMP'}}

        $row=$null
        if($script:ScanRowByIp.ContainsKey($key)){$row=$script:ScanRowByIp[$key]}
        if($null -eq $row){
            $row=Find-ScanGridRowByIp $ip
            if($null -ne $row){$script:ScanRowByIp[$key]=$row;if($null -ne $row.Tag){$script:ScanRecordByIp[$key]=$row.Tag}}
        }
        if($null -eq $row){
            $initialResolved=if($ip -eq $ctx.LocalIP){[Environment]::MachineName}else{''}
            $pref=Get-InitialDeviceName $ip $initialResolved $ctx.Gateway $mac
            $vendor=Get-VendorFromMac $mac
            $fp=Get-DeviceFingerprint $ip $mac ([string]$pref.Name) $vendor $ctx.Gateway $ctx.LocalIP
            $idx=$gridScan.Rows.Add($status,$fp.Type,$fp.Brand,$fp.Model,[string]$pref.Name,[string]$pref.Source,$ip,$mac,$lat,(Get-Date).ToString('HH:mm:ss'))
            $row=$gridScan.Rows[$idx]
            $rec=[pscustomobject]@{
                Status=$status;IP=$ip;MAC=$mac;Name=[string]$pref.Name;NameSource=[string]$pref.Source;
                Brand=$fp.Brand;Type=$fp.Type;Model=$fp.Model;OS=$fp.OS;Confidence=$fp.Confidence;Latency=$lat;
                Evidence=[string]$it.Evidence;ScanEvidence=@(Get-ScanEvidenceRecords $it ([string]$state.updatedAt));DiscoveryEvidence=@()
            }
            $row.Tag=$rec
            $script:ScanRowByIp[$key]=$row
            $script:ScanRecordByIp[$key]=$rec
            [void](Update-DeviceHistory $rec $true)
            $changed++
        } else {
            $rec=$row.Tag
            if($null -eq $rec){
                $pref=Get-InitialDeviceName $ip '' $ctx.Gateway $mac
                $vendor=Get-VendorFromMac $mac
                $fp=Get-DeviceFingerprint $ip $mac ([string]$pref.Name) $vendor $ctx.Gateway $ctx.LocalIP
                $rec=[pscustomobject]@{Status=$status;IP=$ip;MAC=$mac;Name=[string]$pref.Name;NameSource=[string]$pref.Source;Brand=$fp.Brand;Type=$fp.Type;Model=$fp.Model;OS=$fp.OS;Confidence=$fp.Confidence;Latency=$lat;Evidence=[string]$it.Evidence;ScanEvidence=@(Get-ScanEvidenceRecords $it ([string]$state.updatedAt));DiscoveryEvidence=@()}
                $row.Tag=$rec
            }
            $oldSig="$($rec.Status)|$($rec.MAC)|$($rec.Latency)"
            $rec.Status=$status
            if($mac){$rec.MAC=$mac}
            $rec.Latency=$lat
            $rec.Evidence=[string]$it.Evidence
            $scanEv=@(Get-ScanEvidenceRecords $it ([string]$state.updatedAt))
            if($rec.PSObject.Properties['ScanEvidence']){$rec.ScanEvidence=$scanEv}else{$rec | Add-Member -NotePropertyName ScanEvidence -NotePropertyValue $scanEv -Force}
            $vendor=Get-VendorFromMac ([string]$rec.MAC)
            $fp=Get-DeviceFingerprint $ip ([string]$rec.MAC) ([string]$rec.Name) $vendor $ctx.Gateway $ctx.LocalIP
            $rec.Brand=$fp.Brand;$rec.Type=$fp.Type;$rec.Model=$fp.Model;$rec.OS=$fp.OS;$rec.Confidence=$fp.Confidence
            $row.Cells['Status'].Value=$rec.Status;$row.Cells['MAC'].Value=$rec.MAC;$row.Cells['Latency'].Value=$rec.Latency
            $row.Cells['Brand'].Value=$rec.Brand;$row.Cells['Type'].Value=$rec.Type;$row.Cells['Model'].Value=$rec.Model;$row.Cells['LastUpdate'].Value=(Get-Date).ToString('HH:mm:ss')
            $script:ScanRowByIp[$key]=$row;$script:ScanRecordByIp[$key]=$rec
            if($oldSig -ne "$($rec.Status)|$($rec.MAC)|$($rec.Latency)"){
                [void](Update-DeviceHistory $rec $false)
                $changed++
            }
        }

        if($status -eq 'Online'){$row.Cells['Status'].Style.ForeColor=[Drawing.Color]::ForestGreen}
        elseif($status -eq 'L2 Seen'){$row.Cells['Status'].Style.ForeColor=[Drawing.Color]::DarkOrange}
        else{$row.Cells['Status'].Style.ForeColor=[Drawing.Color]::DimGray}
    }
    $script:ScanResults=@($script:ScanRecordByIp.Values | Sort-Object IP)
    if($changed -gt 0){Save-DeviceHistory}
    return $changed
}

$btnStopScan.Add_Click({
    if($script:ScanActive){
        Stop-ScanWorker $false
        $lblScanStatus.Text='Đã yêu cầu dừng Network Scan...'
        $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
    }
    Stop-DiscoveryWorker
    if($discoveryTimer){$discoveryTimer.Stop()}
    if(-not $script:ScanActive){$btnStopScan.Enabled=$false}
})

$btnExportScan.Add_Click({ Export-ScanCsv $gridScan })
$btnUpdateOui.Add_Click({
    if($script:OuiUpdateActive){return}
    try {
        $btnUpdateOui.Enabled=$false
        $lblScanStatus.Text='Đang cập nhật IEEE OUI ở background worker...'
        $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
        if(-not(Start-OuiTaskWorker 'OUI_UPDATE')){throw 'OUI Task Worker đang bận.'}
        if($ouiTaskTimer){$ouiTaskTimer.Start()}
    } catch {
        $script:OuiUpdateActive=$false;$btnUpdateOui.Enabled=$true
        $lblScanStatus.Text=$_.Exception.Message;$lblScanStatus.ForeColor=[Drawing.Color]::Firebrick
        Write-RuntimeLog 'OUI-UPDATE' ($_ | Out-String)
    }
})

$discoveryTimer = New-Object System.Windows.Forms.Timer
$discoveryTimer.Interval = 1000
$discoveryTimer.Add_Tick({
    try {
        [void](Apply-DiscoveryCacheToGrid)
        if($script:DiscoveryProcess -and -not $script:DiscoveryProcess.HasExited){
            $elapsed=if($script:DiscoveryStartedAt){[int]((Get-Date)-$script:DiscoveryStartedAt).TotalSeconds}else{0}
            $elapsed=[Math]::Min($elapsed,[int]$script:DiscoveryDurationSec)
            $lblScanStatus.Text="$($script:CurrentScanProfile) scan xong | nhận dạng tên nền $elapsed/$($script:DiscoveryDurationSec)s | cập nhật $($script:DiscoveryAppliedCount) tên"
            $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
            $btnStopScan.Enabled=$true
        } else {
            [void](Apply-DiscoveryCacheToGrid)
            if($script:DiscoveryStartedAt){
                $totalSec=if($script:CurrentScanStartedAt){[Math]::Round(((Get-Date)-[datetime]$script:CurrentScanStartedAt).TotalSeconds,1)}else{0}
                $coreSec=[Math]::Round(([double]$script:CurrentScanCoreElapsedMs/1000.0),1)
                $lblScanStatus.Text="Hoàn tất $($script:CurrentScanProfile) + nhận dạng tên nền | cập nhật $($script:DiscoveryAppliedCount) tên | Core ${coreSec}s | Total ${totalSec}s"
                $lblScanSummary.Text="$($script:CurrentScanProfile) | IPv4 $($script:ScanResults.Count) | Core ${coreSec}s | Total ${totalSec}s"
                $lblScanStatus.ForeColor=[Drawing.Color]::ForestGreen
            }
            $btnStopScan.Enabled=$false
            $discoveryTimer.Stop()
            if($script:DiscoveryProcess){try{$script:DiscoveryProcess.Dispose()}catch{};$script:DiscoveryProcess=$null}
        }
    } catch {
        Write-RuntimeLog 'NAME-DISCOVERY-TIMER' ($_ | Out-String)
    }
})

$scanWorkerTimer = New-Object System.Windows.Forms.Timer
$scanWorkerTimer.Interval = 250
$scanWorkerTimer.Add_Tick({
    try {
        $state=Read-ScanStateSafe
        if($state){
            if($script:ScanRunId -and ((-not $state.PSObject.Properties['runId']) -or ([string]$state.runId -ne $script:ScanRunId))){
                Write-RuntimeLog 'SCAN-STATE-STALE' "Ignored state for runId=$([string]$state.runId); expected=$($script:ScanRunId)"
                return
            }
            $sig="$($state.updatedAt)|$($state.phase)|$($state.done)|$($state.online)|$($state.seen)|$(@($state.results).Count)"
            if($sig -ne $script:ScanStateSignature){
                $script:ScanStateSignature=$sig
                [void](Apply-ScanStateToGrid $state)
            }

            $phaseLabel=switch([string]$state.phase){
                'icmp-fast' {'1/5 Ping nhanh toàn dải'}
                'icmp-retry' {'2/5 Ping retry thích ứng'}
                'icmp-retry-skipped' {'2/5 Bỏ retry theo FAST profile'}
                'arp-active' {'3/5 Active ARP toàn dải'}
                'neighbor-merge' {'4/5 Hợp nhất Neighbor/ARP cache'}
                'ipv6-neighbor-snapshot' {'5/5 Snapshot IPv6 NDP thụ động'}
                'done' {'Hoàn tất discovery cơ bản'}
                'cancelled' {'Đã dừng'}
                'error' {'Lỗi scan worker'}
                default {[string]$state.phase}
            }
            $pct=0
            if([int]$state.total -gt 0){
                if($state.phase -eq 'icmp-fast'){$pct=[Math]::Min(30,[int](30*[int]$state.done/[int]$state.total))}
                elseif($state.phase -eq 'icmp-retry'){$pct=30+[Math]::Min(20,[int](20*[int]$state.done/[Math]::Max(1,[int]$state.total)))}
                elseif($state.phase -eq 'icmp-retry-skipped'){$pct=50}
                elseif($state.phase -eq 'arp-active'){$pct=50+[Math]::Min(40,[int](40*[int]$state.done/[int]$state.total))}
                elseif($state.phase -eq 'neighbor-merge'){$pct=95}
                elseif($state.phase -eq 'ipv6-neighbor-snapshot'){$pct=98}
                elseif($state.complete){$pct=100}
            }
            $scanProgress.Value=[Math]::Max(0,[Math]::Min(100,$pct))
            $ipv6Count=if($state.PSObject.Properties['ipv6Neighbors']){@($state.ipv6Neighbors).Count}else{0}
            $lblScanStatus.Text="$phaseLabel | $([int]$state.online) Online | $([int]$state.seen) L2 Seen | NDP6 $ipv6Count | $(@($state.results).Count) thiết bị IPv4"
            $elapsedText=if($state.PSObject.Properties['elapsedMs']){"$([Math]::Round(([int]$state.elapsedMs)/1000.0,1))s"}else{'-'}
            $profileText=if($state.PSObject.Properties['profile']){[string]$state.profile}else{$script:CurrentScanProfile}
            $lblScanSummary.Text="$profileText | Online $([int]$state.online) | L2 $([int]$state.seen) | NDP6 $ipv6Count | IPv4 $(@($state.results).Count) | Core $elapsedText"

            if([bool]$state.complete){
                $scanWorkerTimer.Stop()
                $script:ScanActive=$false
                if($script:ScanProcess){try{$script:ScanProcess.WaitForExit(300)}catch{};try{$script:ScanProcess.Dispose()}catch{};$script:ScanProcess=$null}
                Remove-Item -LiteralPath $ScanCancelFile -Force -ErrorAction SilentlyContinue

                $btnScan.Enabled=$true;$cmbScanAdapter.Enabled=$true;$txtCidr.Enabled=$true;$cmbScanProfile.Enabled=$true;$chkRouteAware.Enabled=$true
                if([string]$state.error){
                    $lblScanStatus.Text="Network Scan lỗi: $($state.error)"
                    $lblScanStatus.ForeColor=[Drawing.Color]::Firebrick
                    $btnStopScan.Enabled=$false
                } elseif([bool]$state.cancelled){
                    $lblScanStatus.Text="Đã dừng Network Scan | phát hiện $(@($state.results).Count) thiết bị"
                    $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
                    $btnStopScan.Enabled=$false
                } else {
                    $scanProgress.Value=100
                    $lblScanStatus.ForeColor=[Drawing.Color]::ForestGreen
                    $profileName=if($state.PSObject.Properties['profile']){[string]$state.profile}else{$script:CurrentScanProfile}
                    $durationSec=20
                    if($state.metrics -and $state.metrics.PSObject.Properties['DiscoveryDurationSec']){$durationSec=[int]$state.metrics.DiscoveryDurationSec}
                    $script:CurrentScanCoreElapsedMs=[int]$state.elapsedMs
                    $phaseJson=''
                    try {
                        if($state.metrics -and $state.metrics.PSObject.Properties['PhaseElapsedMs']){$phaseJson=ConvertTo-Json -InputObject $state.metrics.PhaseElapsedMs -Compress}
                    } catch {
                        Write-RuntimeLog 'SCAN-PHASE-METRICS' ($_ | Out-String)
                    }
                    Write-ScanLog $script:ScanLogFile "BASIC DONE Profile=$profileName Online=$([int]$state.online) L2Seen=$([int]$state.seen) IPv6Neighbors=$ipv6Count TotalIPv4=$(@($state.results).Count) ElapsedMs=$([int]$state.elapsedMs) PhaseMs=$phaseJson"
                    $started=$false
                    if($gridScan.Rows.Count -gt 0 -and $script:ScanContext -and $durationSec -gt 0){
                        $started=Start-DiscoveryWorker @($script:ScanResults) $script:ScanContext.Gateway $script:ScanContext.LocalIP $profileName $durationSec
                    }
                    if($started){
                        $lblScanStatus.Text="$profileName scan cơ bản xong. Name discovery nền $durationSec giây..."
                        $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
                        $btnStopScan.Enabled=$true
                        $discoveryTimer.Start()
                    } else {
                        $btnStopScan.Enabled=$false
                        $lblScanStatus.Text="Hoàn tất $profileName | Online $([int]$state.online) | L2 Seen $([int]$state.seen) | NDP6 $ipv6Count | IPv4 $(@($state.results).Count)"
                    }
                }
                Add-ScanHistoryRecord $state
                Save-DeviceHistory
                $script:ScanRunId=''
            }
        } elseif($script:ScanProcess -and $script:ScanProcess.HasExited -and $script:ScanActive){
            $scanWorkerTimer.Stop()
            $script:ScanActive=$false
            $btnScan.Enabled=$true;$btnStopScan.Enabled=$false;$cmbScanAdapter.Enabled=$true;$txtCidr.Enabled=$true;$cmbScanProfile.Enabled=$true;$chkRouteAware.Enabled=$true
            $lblScanStatus.Text='Scan worker đã thoát nhưng không tạo được state hợp lệ. Xem logs.'
            $lblScanStatus.ForeColor=[Drawing.Color]::Firebrick
            Write-RuntimeLog 'SCAN-WORKER' 'Process exited without a complete state file.'
        }
    } catch {
        Write-RuntimeLog 'SCAN-WORKER-TIMER' ($_ | Out-String)
    }
})

$btnScan.Add_Click({
    if($script:ScanActive){return}
    if($cmbScanAdapter.SelectedIndex -lt 0){ [System.Windows.Forms.MessageBox]::Show('Không có card mạng IPv4 đang hoạt động.','Network Scan','OK','Information')|Out-Null; return }
    if([string]::IsNullOrWhiteSpace($txtCidr.Text)){[void](Update-ScanAdapterDefaults)}
    $arr=@($cmbScanAdapter.Tag); $adapter=$arr[$cmbScanAdapter.SelectedIndex]; $ai=Get-AdapterIPv4Info $adapter
    if(-not $ai){[System.Windows.Forms.MessageBox]::Show('Card mạng đã thay đổi hoặc không còn IPv4 hợp lệ. Hãy chọn lại card mạng.','Network Scan','OK','Warning')|Out-Null;return}
    $primaryCidr=$txtCidr.Text.Trim()
    $routePlan=$null
    try {
        if($chkRouteAware.Checked){
            $routePlan=New-RftRouteAwareScanPlan -PrimaryCidr $primaryCidr -InterfaceIndex ([int]$ai.InterfaceIndex) -MaxAutoSubnets 4 -MaxTotalHosts 1024 -MaxAutoHostsPerSubnet 254
            $targets=@($routePlan.Targets)
            if([int]$routePlan.AutoScopeCount -gt 0){
                $autoCidrs=@($routePlan.Scopes | Where-Object {[string]$_.Source -eq 'Route'} | ForEach-Object {[string]$_.Cidr})
                $scopeText=[string]::Join([Environment]::NewLine,$autoCidrs)
                $confirmText="Route-aware sẽ thêm $($routePlan.AutoScopeCount) private routed scope:`n$scopeText`n`nTổng unique targets: $($routePlan.TotalTargets) (giới hạn 1024).`nChỉ tiếp tục nếu bạn được phép kiểm tra các mạng này.`n`nTiếp tục scan?"
                $choice=[System.Windows.Forms.MessageBox]::Show($confirmText,'Xác nhận Route-aware scan',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
                if($choice -ne [System.Windows.Forms.DialogResult]::Yes){return}
            }
        }else{
            $targets=@(Get-IPv4HostsFromCidr $primaryCidr 1024)
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Phạm vi scan không hợp lệ','OK','Warning')|Out-Null
        return
    }

    Stop-DiscoveryWorker
    if($discoveryTimer){$discoveryTimer.Stop()}
    $gridScan.Rows.Clear();$script:ScanResults=@();$script:ScanRecordByIp=@{};$script:ScanRowByIp=@{};$script:ScanStateSignature=''
    $script:ScanCancel=$false;$script:ScanActive=$true
    $script:DiscoverySnapshotReady=$false;$script:MdnsNameCache=@{};$script:SsdpNameCache=@{}
    $selectedScanProfile=[string]$cmbScanProfile.SelectedItem
    $settings=Get-ScanProfileSettings $selectedScanProfile ([int]$numScanTimeout.Value) $targets.Count
    $script:CurrentScanProfile=[string]$settings.Profile
    $script:CurrentScanStartedAt=Get-Date
    $script:CurrentScanCoreElapsedMs=0
    $script:DiscoveryDurationSec=[int]$settings.DiscoveryDurationSec
    $scopeCidrs=if($routePlan){@($routePlan.Scopes|ForEach-Object {[string]$_.Cidr})}else{@($primaryCidr)}
    $routeQueryError=if($routePlan){[string]$routePlan.RouteQueryError}else{''}
    $script:ScanContext=[pscustomobject]@{
        LocalIP=$ai.IP;Gateway=$ai.Gateway;InterfaceIndex=$ai.InterfaceIndex;AdapterName=$adapter.Name;
        CIDR=$primaryCidr;Profile=[string]$settings.Profile;RouteAware=[bool]$chkRouteAware.Checked;
        Scopes=@($scopeCidrs);ScopeCount=@($scopeCidrs).Count;RouteQueryError=$routeQueryError
    }
    $scanProgress.Value=0;$lblScanSummary.Text="$($settings.Profile) | Online 0 | L2 0 | NDP6 0 | IPv4 0"
    $btnScan.Enabled=$false;$btnStopScan.Enabled=$true;$cmbScanAdapter.Enabled=$false;$txtCidr.Enabled=$false;$cmbScanProfile.Enabled=$false;$chkRouteAware.Enabled=$false
    $scopeMode=if($routePlan){"Route-aware $(@($scopeCidrs).Count) scope"}else{"CIDR $primaryCidr"}
    $routeNote=if($routePlan -and $routePlan.RouteQueryError){" | route query fallback: $($routePlan.RouteQueryError)"}else{''}
    $lblScanStatus.Text="Khởi động $($settings.Profile): $scopeMode | $($targets.Count) IP$routeNote"
    $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange

    try {
        [void](Start-ScanWorker $targets $ai $adapter $settings)
        $scanWorkerTimer.Start()
    } catch {
        $script:ScanActive=$false
        $btnScan.Enabled=$true;$btnStopScan.Enabled=$false;$cmbScanAdapter.Enabled=$true;$txtCidr.Enabled=$true;$cmbScanProfile.Enabled=$true;$chkRouteAware.Enabled=$true
        $lblScanStatus.Text="Không thể khởi động scan worker: $($_.Exception.Message)"
        $lblScanStatus.ForeColor=[Drawing.Color]::Firebrick
        Write-RuntimeLog 'SCAN-WORKER-START' ($_ | Out-String)
    }
})


$pingWorkerTimer = New-Object System.Windows.Forms.Timer
$pingWorkerTimer.Interval = 150
$pingWorkerTimer.Add_Tick({
    try {
        [void](Apply-PingWorkerResults)
        if($script:PingWorkerProcess -and $script:PingWorkerProcess.HasExited -and $script:PingRequests.Count -gt 0){
            Write-RuntimeLog 'PING-WORKER' "Worker exited unexpectedly with $($script:PingRequests.Count) pending requests."
            Fail-PendingPingRequests 'Ping worker stopped'
            Stop-PingWorker
        }
        if($script:PingRequests.Count -gt 0 -and $script:PingWorkerLastHeartbeat){
            $age=((Get-Date)-$script:PingWorkerLastHeartbeat).TotalSeconds
            if($age -gt 20){
                Write-RuntimeLog 'PING-WATCHDOG' "Heartbeat stale $([int]$age)s; stopping worker."
                Fail-PendingPingRequests 'Ping worker heartbeat stale'
                Stop-PingWorker
            }
        }
    } catch {Write-RuntimeLog 'PING-WORKER-TIMER' ($_ | Out-String)}
})
$pingWorkerTimer.Start()

$ouiTaskTimer = New-Object System.Windows.Forms.Timer
$ouiTaskTimer.Interval = 250
$ouiTaskTimer.Add_Tick({
    Poll-OuiTaskWorker
    if(-not $script:OuiUpdateActive){$ouiTaskTimer.Stop()}
})

$ouiCacheTimer = New-Object System.Windows.Forms.Timer
$ouiCacheTimer.Interval = 80
$ouiCacheTimer.Add_Tick({
    if(-not(Read-OuiCacheChunk 1800)){$ouiCacheTimer.Stop()}
})


# ---------------- TAB 4: MONITORING ----------------
$tabMonitor = New-Object System.Windows.Forms.TabPage
$tabMonitor.Text = 'MONITORING'
$tabMonitor.Padding = New-Object System.Windows.Forms.Padding(10)
$tabs.TabPages.Add($tabMonitor) | Out-Null

$monitorAlertTip=New-Object System.Windows.Forms.ToolTip
$monitorAlertTip.IsBalloon=$true
$monitorAlertTip.ToolTipTitle='RF Network Monitoring'
$monitorAlertTip.ToolTipIcon=[System.Windows.Forms.ToolTipIcon]::Info

$monitorHeader = New-Object System.Windows.Forms.Panel
$monitorHeader.Dock='Top';$monitorHeader.Height=74
$tabMonitor.Controls.Add($monitorHeader)

$btnMonitorSync=New-Object System.Windows.Forms.Button
$btnMonitorSync.Text='Đồng bộ từ PING';$btnMonitorSync.Location=New-Object Drawing.Point(4,4);$btnMonitorSync.Size=New-Object Drawing.Size(125,30)
$monitorHeader.Controls.Add($btnMonitorSync)
$btnMonitorEnableAll=New-Object System.Windows.Forms.Button
$btnMonitorEnableAll.Text='Bật tất cả';$btnMonitorEnableAll.Location=New-Object Drawing.Point(137,4);$btnMonitorEnableAll.Size=New-Object Drawing.Size(88,30)
$monitorHeader.Controls.Add($btnMonitorEnableAll)
$btnMonitorDisableAll=New-Object System.Windows.Forms.Button
$btnMonitorDisableAll.Text='Tắt tất cả';$btnMonitorDisableAll.Location=New-Object Drawing.Point(233,4);$btnMonitorDisableAll.Size=New-Object Drawing.Size(88,30)
$monitorHeader.Controls.Add($btnMonitorDisableAll)
$btnMonitorReset=New-Object System.Windows.Forms.Button
$btnMonitorReset.Text='Reset thống kê';$btnMonitorReset.Location=New-Object Drawing.Point(329,4);$btnMonitorReset.Size=New-Object Drawing.Size(110,30)
$monitorHeader.Controls.Add($btnMonitorReset)
$btnMonitorClearHistory=New-Object System.Windows.Forms.Button
$btnMonitorClearHistory.Text='Xóa timeline';$btnMonitorClearHistory.Location=New-Object Drawing.Point(447,4);$btnMonitorClearHistory.Size=New-Object Drawing.Size(100,30)
$monitorHeader.Controls.Add($btnMonitorClearHistory)

$lblMonitorSummary=New-Object System.Windows.Forms.Label
$lblMonitorSummary.Location=New-Object Drawing.Point(5,42);$lblMonitorSummary.Size=New-Object Drawing.Size(1030,23);$lblMonitorSummary.Anchor='Top,Left,Right';$lblMonitorSummary.AutoEllipsis=$true
$lblMonitorSummary.Text='Monitoring: chưa có target được bật.';$lblMonitorSummary.ForeColor=[Drawing.Color]::DimGray
$monitorHeader.Controls.Add($lblMonitorSummary)

$monitorSplit=New-Object System.Windows.Forms.SplitContainer
$monitorSplit.Dock='Fill';$monitorSplit.Orientation='Horizontal';$monitorSplit.SplitterDistance=365;$monitorSplit.Panel1MinSize=220;$monitorSplit.Panel2MinSize=120
$tabMonitor.Controls.Add($monitorSplit);$monitorSplit.BringToFront()

$gridMonitor=New-Object System.Windows.Forms.DataGridView
$gridMonitor.Dock='Fill';$gridMonitor.AllowUserToAddRows=$false;$gridMonitor.AllowUserToDeleteRows=$false;$gridMonitor.AllowUserToResizeRows=$false;$gridMonitor.RowHeadersVisible=$false
$gridMonitor.MultiSelect=$false;$gridMonitor.SelectionMode='FullRowSelect';$gridMonitor.AutoSizeColumnsMode='Fill';$gridMonitor.BackgroundColor=[Drawing.Color]::White;$gridMonitor.AutoGenerateColumns=$false
$monitorSplit.Panel1.Controls.Add($gridMonitor)

$mcEnabled=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn;$mcEnabled.Name='MonEnabled';$mcEnabled.HeaderText='ON';$mcEnabled.FillWeight=5;[void]$gridMonitor.Columns.Add($mcEnabled)
$mcName=New-Object System.Windows.Forms.DataGridViewTextBoxColumn;$mcName.Name='MonName';$mcName.HeaderText='THIẾT BỊ';$mcName.ReadOnly=$true;$mcName.FillWeight=16;[void]$gridMonitor.Columns.Add($mcName)
$mcTarget=New-Object System.Windows.Forms.DataGridViewTextBoxColumn;$mcTarget.Name='MonTarget';$mcTarget.HeaderText='IP / HOST';$mcTarget.ReadOnly=$true;$mcTarget.FillWeight=17;[void]$gridMonitor.Columns.Add($mcTarget)
$mcInterval=New-Object System.Windows.Forms.DataGridViewComboBoxColumn;$mcInterval.Name='MonInterval';$mcInterval.HeaderText='GIÂY';$mcInterval.FillWeight=6;foreach($v in @('1','2','5','10','30')){[void]$mcInterval.Items.Add($v)};[void]$gridMonitor.Columns.Add($mcInterval)
$mcAlert=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn;$mcAlert.Name='MonAlert';$mcAlert.HeaderText='ALERT';$mcAlert.FillWeight=6;[void]$gridMonitor.Columns.Add($mcAlert)
foreach($spec in @(
    @('MonState','STATUS',9),@('MonCurrent','NOW',7),@('MonMin','MIN ms',6),@('MonAvg','AVG ms',6),@('MonMax','MAX ms',6),@('MonSamples','OK/TOTAL',8),@('MonLoss','LOSS',7),@('MonUptime','UPTIME',9),@('MonDowntime','DOWNTIME',9),@('MonOutages','OUTAGES',7),@('MonLastSample','LAST SAMPLE',10),@('MonChanged','LAST CHANGE',12)
)){
    $c=New-Object System.Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$spec[0];$c.HeaderText=$spec[1];$c.ReadOnly=$true;$c.FillWeight=[float]$spec[2];[void]$gridMonitor.Columns.Add($c)
}

$gridMonitorTimeline=New-Object System.Windows.Forms.DataGridView
$gridMonitorTimeline.Dock='Fill';$gridMonitorTimeline.AllowUserToAddRows=$false;$gridMonitorTimeline.AllowUserToDeleteRows=$false;$gridMonitorTimeline.AllowUserToResizeRows=$false;$gridMonitorTimeline.RowHeadersVisible=$false
$gridMonitorTimeline.ReadOnly=$true;$gridMonitorTimeline.MultiSelect=$false;$gridMonitorTimeline.SelectionMode='FullRowSelect';$gridMonitorTimeline.AutoSizeColumnsMode='Fill';$gridMonitorTimeline.BackgroundColor=[Drawing.Color]::White;$gridMonitorTimeline.AutoGenerateColumns=$false
$monitorSplit.Panel2.Controls.Add($gridMonitorTimeline)
foreach($spec in @(@('EvtAt','THỜI GIAN',18),@('EvtName','THIẾT BỊ',16),@('EvtTarget','IP / HOST',18),@('EvtFrom','TỪ',10),@('EvtTo','SANG',10),@('EvtLatency','LATENCY',9),@('EvtDetail','CHI TIẾT',19))){$c=New-Object System.Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$spec[0];$c.HeaderText=$spec[1];$c.FillWeight=[float]$spec[2];[void]$gridMonitorTimeline.Columns.Add($c)}

function Get-MonitorGridRow([string]$target){foreach($r in $gridMonitor.Rows){if(-not $r.IsNewRow -and [string]$r.Tag -eq $target){return $r}};return $null}

function Update-MonitorGridRow([string]$target){
    if(-not $script:MonitoringConfig.ContainsKey($target)){return}
    $priorUpdating=$script:MonitoringGridUpdating;$script:MonitoringGridUpdating=$true
    try {
        $cfg=$script:MonitoringConfig[$target];$stat=$script:MonitoringStats[$target];$row=Get-MonitorGridRow $target
        if($null -eq $row){$idx=$gridMonitor.Rows.Add();$row=$gridMonitor.Rows[$idx];$row.Tag=$target}
        $row.Cells['MonEnabled'].Value=[bool]$cfg.Enabled;$row.Cells['MonName'].Value=[string]$cfg.Name;$row.Cells['MonTarget'].Value=$target;$row.Cells['MonInterval'].Value=[string](Get-MonitorInterval $cfg.IntervalSec);$row.Cells['MonAlert'].Value=[bool]$cfg.Alert
        $state=if($stat){[string]$stat.State}else{'UNKNOWN'}
        $displayState=$state;$isPending=$false
        if([bool]$cfg.Enabled -and $script:PingTargetBusy.ContainsKey($target)){
            $busyId=[string]$script:PingTargetBusy[$target]
            if($script:PingRequests.ContainsKey($busyId) -and [string]$script:PingRequests[$busyId].Kind -eq 'MONITOR'){$isPending=$true}
        }
        if($isPending){$displayState='PENDING'}
        elseif($stat -and ([string]$stat.LastDetail).StartsWith('Engine error:')){$displayState='ENGINE ERROR'}
        elseif([bool]$cfg.Enabled -and $state -eq 'UNKNOWN'){$displayState='WAITING'}
        $row.Cells['MonState'].Value=$displayState
        if($displayState -eq 'ONLINE'){$row.Cells['MonState'].Style.ForeColor=[Drawing.Color]::ForestGreen}
        elseif($displayState -eq 'OFFLINE' -or $displayState -eq 'ENGINE ERROR'){$row.Cells['MonState'].Style.ForeColor=[Drawing.Color]::Firebrick}
        elseif($displayState -eq 'PENDING' -or $displayState -eq 'WAITING'){$row.Cells['MonState'].Style.ForeColor=[Drawing.Color]::DarkOrange}
        else{$row.Cells['MonState'].Style.ForeColor=[Drawing.Color]::DimGray}
        $row.Cells['MonState'].ToolTipText=if($stat -and $stat.LastDetail){[string]$stat.LastDetail}elseif($displayState -eq 'WAITING'){'Waiting for the first monitoring sample.'}elseif($displayState -eq 'PENDING'){'Monitoring sample is in flight.'}else{''}
        $row.Cells['MonCurrent'].Value=if($stat -and $null -ne $stat.CurrentMs){"$([Math]::Round([double]$stat.CurrentMs,1)) ms"}else{'--'}
        $row.Cells['MonMin'].Value=if($stat -and $null -ne $stat.MinMs){"$([Math]::Round([double]$stat.MinMs,1))"}else{'--'}
        $avg=Get-MonitorAverageMs $stat;$row.Cells['MonAvg'].Value=if($null -ne $avg){"$avg"}else{'--'}
        $row.Cells['MonMax'].Value=if($stat -and $null -ne $stat.MaxMs){"$([Math]::Round([double]$stat.MaxMs,1))"}else{'--'}
        $row.Cells['MonSamples'].Value=if($stat){"$([int]$stat.SuccessCount)/$([int]$stat.TotalCount)"}else{'0/0'}
        $row.Cells['MonSamples'].ToolTipText=if($stat){"Success=$([int]$stat.SuccessCount); Fail=$([int]$stat.FailureCount); Total=$([int]$stat.TotalCount)"}else{''}
        $row.Cells['MonLoss'].Value=if($stat){"$(Get-MonitorLossPercent $stat)%"}else{'0.0%'}
        $row.Cells['MonUptime'].Value=if($stat){Format-MonitorDuration (Get-MonitorDisplayedUptime $stat)}else{'00:00:00'}
        $row.Cells['MonDowntime'].Value=if($stat){Format-MonitorDuration (Get-MonitorDisplayedDowntime $stat)}else{'00:00:00'}
        $row.Cells['MonOutages'].Value=if($stat){[string]$stat.OutageCount}else{'0'}
        $row.Cells['MonLastSample'].Value=if($stat -and $stat.LastResultAt){([datetime]$stat.LastResultAt).ToString('HH:mm:ss')}else{'--'}
        $row.Cells['MonChanged'].Value=if($stat -and $stat.LastChange){([datetime]$stat.LastChange).ToString('HH:mm:ss')}else{'--'}
    } finally {$script:MonitoringGridUpdating=$priorUpdating}
}

function Refresh-MonitorGrid {
    if(-not $gridMonitor){return}
    $gridMonitor.SuspendLayout();try{$gridMonitor.Rows.Clear();foreach($cfg in @($script:MonitoringConfig.Values|Sort-Object Target)){Update-MonitorGridRow ([string]$cfg.Target)}}finally{$gridMonitor.ResumeLayout()}
    Refresh-MonitorSummary
}

function Refresh-MonitorTimelineGrid {
    if(-not $gridMonitorTimeline){return}
    $gridMonitorTimeline.SuspendLayout();try{$gridMonitorTimeline.Rows.Clear();foreach($ev in @($script:MonitoringEvents|Sort-Object At -Descending)){$lat=if($null -ne $ev.LatencyMs -and [string]$ev.LatencyMs -ne ''){"$($ev.LatencyMs) ms"}else{'--'};$at='';try{$at=([datetime]$ev.At).ToString('yyyy-MM-dd HH:mm:ss')}catch{$at=[string]$ev.At};$i=$gridMonitorTimeline.Rows.Add($at,[string]$ev.Name,[string]$ev.Target,[string]$ev.From,[string]$ev.To,$lat,[string]$ev.Detail);$r=$gridMonitorTimeline.Rows[$i];if([string]$ev.To -eq 'OFFLINE'){$r.DefaultCellStyle.ForeColor=[Drawing.Color]::Firebrick}elseif([string]$ev.To -eq 'ONLINE'){$r.DefaultCellStyle.ForeColor=[Drawing.Color]::ForestGreen}}}finally{$gridMonitorTimeline.ResumeLayout()}
}

function Refresh-MonitorSummary {
    if(-not $lblMonitorSummary){return}
    $enabled=@($script:MonitoringConfig.Values|Where-Object{[bool]$_.Enabled});$online=0;$offline=0;$unknown=0
    foreach($cfg in $enabled){$st=$script:MonitoringStats[[string]$cfg.Target];if($st -and $st.State -eq 'ONLINE'){$online++}elseif($st -and $st.State -eq 'OFFLINE'){$offline++}else{$unknown++}}
    $since=if($script:MonitoringSessionStartedAt){([datetime]$script:MonitoringSessionStartedAt).ToString('HH:mm:ss')}else{'--'}
    $lblMonitorSummary.Text="Monitoring: Enabled $($enabled.Count) | Online $online | Offline $offline | Unknown $unknown | Stats since $since | Timeline $($script:MonitoringEvents.Count)/$($script:MonitoringMaxEvents)"
    if($offline -gt 0){$lblMonitorSummary.ForeColor=[Drawing.Color]::Firebrick}elseif($enabled.Count -gt 0){$lblMonitorSummary.ForeColor=[Drawing.Color]::ForestGreen}else{$lblMonitorSummary.ForeColor=[Drawing.Color]::DimGray}
}

function Reset-MonitorStats {
    $new=@{};foreach($cfg in @($script:MonitoringConfig.Values)){$new[[string]$cfg.Target]=New-MonitorStat ([string]$cfg.Target) ([string]$cfg.Name)};$script:MonitoringStats=$new;$script:MonitoringSessionStartedAt=Get-Date;Refresh-MonitorGrid
}

function Invoke-MonitorScheduler {
    if($script:MonitoringSchedulerBusy){return};$script:MonitoringSchedulerBusy=$true
    try {
        $now=Get-Date;$due=New-Object System.Collections.Generic.List[object]
        foreach($cfg in @($script:MonitoringConfig.Values|Where-Object{[bool]$_.Enabled}|Sort-Object Target)){
            $target=[string]$cfg.Target;if($script:PingTargetBusy.ContainsKey($target)){continue}
            $stat=$script:MonitoringStats[$target];if(-not $stat){$stat=New-MonitorStat $target ([string]$cfg.Name);$script:MonitoringStats[$target]=$stat}
            $interval=Get-MonitorInterval $cfg.IntervalSec
            $isDue=(-not $stat.LastScheduledAt) -or (($now-[datetime]$stat.LastScheduledAt).TotalSeconds -ge $interval)
            if($isDue){$stat.LastScheduledAt=$now;[void]$due.Add([pscustomobject]@{Target=$target;Alias=[string]$cfg.Name})}
            if($due.Count -ge 24){break}
        }
        if($due.Count -gt 0){[void](Enqueue-PingRequest 'MONITOR' $due.ToArray() 1200 24)}
        if(-not $script:MonitoringLastUiRefresh -or (($now-[datetime]$script:MonitoringLastUiRefresh).TotalSeconds -ge 1)){
            foreach($cfg in @($script:MonitoringConfig.Values)){Update-MonitorGridRow ([string]$cfg.Target)};$script:MonitoringLastUiRefresh=$now;Refresh-MonitorSummary
        }
    } catch {Write-RuntimeLog 'MONITOR-SCHEDULER' ($_|Out-String)} finally {$script:MonitoringSchedulerBusy=$false}
}

$gridMonitor.Add_CurrentCellDirtyStateChanged({if($gridMonitor.IsCurrentCellDirty){$gridMonitor.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)|Out-Null}})
$gridMonitor.Add_CellValueChanged({param($source,$evt);if($script:MonitoringGridUpdating){return};if($evt.RowIndex -lt 0 -or $evt.ColumnIndex -lt 0){return};$row=$source.Rows[$evt.RowIndex];$target=[string]$row.Tag;if(-not $script:MonitoringConfig.ContainsKey($target)){return};$name=[string]$source.Columns[$evt.ColumnIndex].Name;$cfg=$script:MonitoringConfig[$target];if($name -eq 'MonEnabled'){Set-MonitorEnabledState $target ([bool]$row.Cells['MonEnabled'].Value)}elseif($name -eq 'MonAlert'){$cfg.Alert=[bool]$row.Cells['MonAlert'].Value}elseif($name -eq 'MonInterval'){$cfg.IntervalSec=Get-MonitorInterval $row.Cells['MonInterval'].Value};Save-MonitoringConfig;Refresh-MonitorSummary})
$gridMonitor.Add_DataError({param($source,$evt);$evt.ThrowException=$false})

$btnMonitorSync.Add_Click({Sync-MonitoringWithTargets -Save;Refresh-MonitorTimelineGrid})
$btnMonitorEnableAll.Add_Click({foreach($cfg in @($script:MonitoringConfig.Values)){Set-MonitorEnabledState ([string]$cfg.Target) $true};Save-MonitoringConfig;Refresh-MonitorGrid})
$btnMonitorDisableAll.Add_Click({foreach($cfg in @($script:MonitoringConfig.Values)){Set-MonitorEnabledState ([string]$cfg.Target) $false};Save-MonitoringConfig;Refresh-MonitorGrid})
$btnMonitorReset.Add_Click({Reset-MonitorStats})
$btnMonitorClearHistory.Add_Click({$script:MonitoringEvents=New-Object System.Collections.Generic.List[object];Save-MonitoringHistory;Refresh-MonitorTimelineGrid})

$monitorTimer=New-Object System.Windows.Forms.Timer
$monitorTimer.Interval=500
$monitorTimer.Add_Tick({Invoke-MonitorScheduler})
$monitorTimer.Start()

# ---------------- TAB 5: HƯỚNG DẪN ----------------
$tabHelp = New-Object System.Windows.Forms.TabPage
$tabHelp.Text = 'HƯỚNG DẪN'
$tabHelp.Padding = New-Object System.Windows.Forms.Padding(10)
$tabs.TabPages.Add($tabHelp) | Out-Null

$helpHeader = New-Object System.Windows.Forms.Panel
$helpHeader.Dock = 'Top'
$helpHeader.Height = 62
$tabHelp.Controls.Add($helpHeader)

$helpTitle = New-Object System.Windows.Forms.Label
$helpTitle.Text = 'HƯỚNG DẪN SỬ DỤNG - RF & NETWORK DIAGNOSTIC TOOL'
$helpTitle.Location = New-Object System.Drawing.Point(4,4)
$helpTitle.Size = New-Object System.Drawing.Size(610,22)
$helpTitle.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$helpHeader.Controls.Add($helpTitle)

$helpSub = New-Object System.Windows.Forms.Label
$helpSub.Text = 'Chọn mục bên trái để xem hướng dẫn. Nhấn F1 ở bất kỳ tab nào để mở trang này.'
$helpSub.Location = New-Object System.Drawing.Point(5,31)
$helpSub.Size = New-Object System.Drawing.Size(650,20)
$helpSub.ForeColor = [System.Drawing.Color]::DimGray
$helpHeader.Controls.Add($helpSub)

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = 'Mở thư mục logs'
$btnOpenLogs.Size = New-Object System.Drawing.Size(125,30)
$btnOpenLogs.Anchor = 'Top,Right'
$btnOpenLogs.Location = New-Object System.Drawing.Point(780,8)
$helpHeader.Controls.Add($btnOpenLogs)

$btnOpenAppDir = New-Object System.Windows.Forms.Button
$btnOpenAppDir.Text = 'Mở thư mục tool'
$btnOpenAppDir.Size = New-Object System.Drawing.Size(125,30)
$btnOpenAppDir.Anchor = 'Top,Right'
$btnOpenAppDir.Location = New-Object System.Drawing.Point(915,8)
$helpHeader.Controls.Add($btnOpenAppDir)

$helpSplit = New-Object System.Windows.Forms.SplitContainer
$helpSplit.Dock = 'Fill'
$tabHelp.Controls.Add($helpSplit)
$helpSplit.BringToFront()

function Set-HelpSplitterLayout {
    try {
        $w = [int]$helpSplit.ClientSize.Width
        if ($w -lt 360) { return }
        $p1Min = 150
        $p2Min = 220
        $splitW = [Math]::Max(4, [int]$helpSplit.SplitterWidth)
        $maxP1 = $w - $p2Min - $splitW
        if ($maxP1 -le $p1Min) { return }
        $desired = [Math]::Min(220, $maxP1)
        $helpSplit.Panel1MinSize = $p1Min
        $helpSplit.Panel2MinSize = $p2Min
        if ($desired -ge $p1Min -and $desired -le $maxP1) {
            $helpSplit.SplitterDistance = $desired
        }
    } catch {
        try { Write-RuntimeLog 'HELP-LAYOUT' $_.Exception.Message } catch { }
    }
}
$helpSplit.Add_Resize({ Set-HelpSplitterLayout })

$helpNav = New-Object System.Windows.Forms.ListBox
$helpNav.Dock = 'Fill'
$helpNav.Font = New-Font 9
$helpNav.IntegralHeight = $false
$helpSplit.Panel1.Controls.Add($helpNav)

$helpText = New-Object System.Windows.Forms.RichTextBox
$helpText.Dock = 'Fill'
$helpText.ReadOnly = $true
$helpText.BackColor = [System.Drawing.Color]::White
$helpText.BorderStyle = 'FixedSingle'
$helpText.Font = New-Object System.Drawing.Font('Segoe UI',10)
$helpText.DetectUrls = $true
$helpSplit.Panel2.Controls.Add($helpText)

$script:HelpPages = [ordered]@{
    'Bắt đầu nhanh' = @'
BẮT ĐẦU NHANH

1. Giải nén toàn bộ ZIP vào một thư mục có quyền ghi, ví dụ D:\Tools\RF-Network-Tool.
2. Khuyến nghị: double-click START-RF-NETWORK-TOOL.vbs để chạy không có cửa sổ console. VBS được đóng gói ASCII/no-BOM để tương thích Windows Script Host. RUN-PORTABLE.cmd vẫn được giữ làm phương án tương thích.
3. Nếu tool không mở: chạy RUN-DIAGNOSTIC.cmd, sau đó xem thư mục logs.
4. Dùng các tab theo nhu cầu:
   • PING: lưu IP/hostname, đặt tên gợi nhớ và ping nhanh.
   • RF / RJ45: nghe dữ liệu UDP từ thiết bị RF qua Ethernet/RJ45.
   • NETWORK SCAN: quét thiết bị trong LAN và xem Device Details.
   • MONITORING: theo dõi liên tục các target đã lưu bằng Ping Worker nền.

Mẹo: nhấn F1 ở bất kỳ tab nào để quay lại HƯỚNG DẪN.
'@
    '1. Tab PING' = @'
TAB PING

Mục đích: theo dõi nhanh các IP/hostname thường dùng.

Cách dùng:
1. Nhập IP hoặc hostname, ví dụ 192.168.15.1 hoặc router.local.
2. Nhấn + Lưu IP.
3. Tool tạo tên mặc định Default 1, Default 2...
4. Double-click/F2 ở cột TÊN GỢI NHỚ để đổi tên, ví dụ Router XR30, RF số 1, GPS, Jetson Nano. Tên được lưu ngay khi kết thúc chỉnh sửa.
5. Nhấn Ping ở từng dòng hoặc Ping tất cả.

Kết quả:
• ONLINE: có ICMP reply.
• ms: độ trễ round-trip.
• TTL: Time To Live của gói trả lời.
• Log phía dưới ghi thời điểm, tên gợi nhớ, IP và kết quả.

Dữ liệu IP + tên được lưu theo schemaVersion 2 trong RF-Network-Tool.targets.json; file cũ dạng mảng vẫn được tự migrate khi mở.
'@
    '2. Tab RF / RJ45 UDP' = @'
TAB RF / RJ45 UDP

Mục đích: nhận datagram UDP từ thiết bị RF nối qua Ethernet/RJ45.

Cách dùng:
1. Chọn đúng card mạng đang nối với thiết bị RF.
2. Nhập IP/Host RF nếu cần lọc nguồn.
3. Nhập UDP local port đúng với Destination Port mà thiết bị RF đang gửi tới.
4. Nhấn Start UDP.
5. Quan sát Source IP:Port, độ dài packet, TEXT và HEX.
6. Nếu payload có trường RSSI/SNR dạng text/JSON, tool sẽ thử nhận dạng tự động.
7. Nhấn Stop khi kết thúc.

Nếu không có packet:
• Kiểm tra IP PC và IP RF có cùng subnet.
• Kiểm tra đúng UDP destination port.
• Kiểm tra Windows Firewall và cấu hình phát UDP của thiết bị.
• Kiểm tra dây/link Ethernet và card mạng được chọn.

Lưu ý: UDP không bảo đảm delivery/thứ tự; packet có thể mất hoặc đến không theo thứ tự.
'@
    '3. Tab NETWORK SCAN' = @'
TAB NETWORK SCAN

Mục đích: tìm các thiết bị đang hiện diện trong LAN và gom thông tin từ nhiều nguồn.

Cách dùng:
1. Chọn card mạng. Tool hiện Local IP/prefix, Gateway, MAC, Link speed và loại interface.
2. CIDR được tự tính, ví dụ 192.168.0.0/24.
3. Chọn Base timeout và Profile rồi nhấn Scan / Rescan.
   • FAST: ưu tiên tốc độ; ICMP nhanh + Active ARP + Neighbor, bỏ ICMP retry dài; name discovery ngắn.
   • BALANCED: mặc định; có retry thích ứng và name discovery trung bình.
   • DEEP: timeout/quan sát dài hơn, concurrency bảo thủ hơn và name discovery đầy đủ.
4. Scan engine chạy ở process nền nên UI vẫn thao tác được. PASS 1 ping nhanh toàn dải trước; PASS 2 retry thích ứng nếu profile cho phép; PASS 3 Active ARP; PASS 4 hợp nhất Neighbor cache IPv4; PASS 5 chụp thụ động IPv6 NDP/Neighbor trên đúng interface. Tool không brute-force hay sinh dải địa chỉ IPv6. Concurrency của retry/ARP được tự giảm khi mạng phản hồi chậm hoặc tỷ lệ ICMP thấp.
5. Thiết bị trả ICMP được đánh dấu Online. Thiết bị chặn ping nhưng trả ARP được đánh dấu L2 Seen thay vì bị bỏ sót.
6. Sau discovery cơ bản, helper tên chạy nền theo Profile (FAST khoảng 8s, BALANCED khoảng 20s, DEEP khoảng 45s) để bổ sung DNS/PTR, mDNS/DNS-SD và SSDP/UPnP; ping -a/NetBIOS được bỏ trong FAST để giảm độ trễ. PING alias/History chỉ là fallback.
7. Nếu các giao thức trên không công bố tên, tool giữ PING alias/History hoặc Unknown.
8. Dùng ô Tìm để lọc; Export CSV để xuất; Update IEEE OUI để cập nhật vendor database.

Nguồn tên trong cột NAME SOURCE:
• System DNS / DNS PTR / Gateway DNS PTR: tên do hệ thống DNS hoặc gateway công bố.
• Ping -a reverse: Windows reverse-name resolution cho địa chỉ IP.
• LLMNR/NetBIOS resolver: fallback name resolution của Windows.
• NetBIOS: tên máy Windows/SMB khi thiết bị hỗ trợ NetBIOS.
• mDNS/DNS-SD snapshot: tên/instance/host .local từ multicast discovery toàn mạng.
• mDNS reverse PTR: thử reverse name qua mDNS trên local link.
• UPnP/SSDP snapshot/direct: friendlyName của thiết bị UPnP.
• PING alias: tên gợi nhớ ở tab PING, chỉ dùng khi chưa tìm được tên tự động.
• History: tên từng thấy ở lần quét trước.
• Unknown: thiết bị không công bố tên qua các giao thức mà tool kiểm tra.

Trạng thái:
• Online: ping phản hồi.
• L2 Seen: Active ARP/Neighbor xác nhận thiết bị cùng local subnet nhưng ICMP không trả lời.
• NDP6: số IPv6 neighbor đã có trong Windows neighbor cache trên interface được chọn; đây là snapshot thụ động, chưa phải danh sách đầy đủ mọi host IPv6.

Mỗi lần quét ghi logs\scan-*.log. Giới hạn an toàn: khuyến nghị /24; bản portable không tự quét mạng rất lớn.
'@
    '4. Chi tiết thiết bị' = @'
CHI TIẾT THIẾT BỊ

Mở bằng một trong các cách:
• Double-click dòng thiết bị.
• Chọn dòng rồi nhấn Chi tiết.
• Nhấn Enter trên dòng đang chọn.
• Chuột phải -> Xem chi tiết thiết bị.

Các nhóm thông tin:
1. TỔNG QUAN: status, type, brand, model, OS/hint, device name, nguồn tên, IP, MAC.
2. NETWORK & HISTORY: adapter, CIDR, gateway, neighbor state, ping statistics, First Seen, Last Seen, Seen Count.
3. PROTOCOLS & SERVICES: HTTP fingerprint, SSDP/UPnP và NetBIOS khi phù hợp.
4. OPEN PORTS: sau khi bấm Phân tích sâu, hiển thị tập TCP port phổ biến đã probe và trạng thái Open/Closed/Timeout. Đây không phải quét toàn bộ 1-65535.
5. DISCOVERY EVIDENCE: bảng SOURCE / STATE / VALUE / DETAIL / OBSERVED giải thích vì sao thiết bị được phát hiện và nguồn nào cung cấp tên/metadata.
   • ICMP fast / retry: phản hồi, latency, TTL hoặc lý do không phản hồi.
   • Active ARP / Neighbor cache: bằng chứng lớp 2; hữu ích khi thiết bị chặn Ping.
   • DNS/PTR / ping -a / NetBIOS / mDNS / LLMNR / SSDP-UPnP: bằng chứng nhận dạng tên theo từng giao thức.
   • IEEE OUI / MAC và PING alias được ghi riêng để không nhầm heuristic với dữ liệu mạng.
   • Phân tích sâu bổ sung ICMP statistics, common TCP services, HTTP fingerprint, SSDP/UPnP trực tiếp và NetBIOS deep probe.
6. Ý nghĩa STATE: PASS = có bằng chứng; NO RESPONSE = probe không nhận phản hồi; NOT OBSERVED = không thấy announcement/record trong cửa sổ quan sát; SKIPPED = không cần chạy probe đó; INFO = thông tin bổ trợ; ERROR = probe gặp lỗi.

Không phải mọi thiết bị đều công bố model/OS. NO RESPONSE/NOT OBSERVED không phải bằng chứng rằng thiết bị chắc chắn không hỗ trợ giao thức; trường không đủ bằng chứng sẽ để Unknown hoặc ghi rõ heuristic thay vì đoán chắc chắn.
'@
    '5. Tab MONITORING' = @'
TAB MONITORING

Mục đích: theo dõi liên tục các IP/hostname quan trọng như RF, GPS, Jetson Nano, router/switch mà không khóa giao diện.

Cách dùng:
1. Lưu thiết bị ở tab PING và đặt tên gợi nhớ.
2. Mở MONITORING -> Đồng bộ từ PING.
3. Tick ON ở thiết bị cần theo dõi.
4. Chọn chu kỳ 1 / 2 / 5 / 10 / 30 giây. Mặc định 5 giây.
5. ALERT là tùy chọn: khi thiết bị đã có trạng thái ổn định rồi chuyển ONLINE <-> OFFLINE, tool phát âm báo và hiện balloon tooltip không khóa giao diện.

Các cột:
• NOW: latency lần gần nhất.
• MIN / AVG / MAX: latency của các lần Ping thành công trong phiên hiện tại.
• LOSS: tỷ lệ lần Ping thất bại / tổng số mẫu trong phiên.
• UPTIME / DOWNTIME: tổng thời gian ONLINE/OFFLINE trong phiên hiện tại (được cập nhật động).
• OUTAGES: số lần chuyển từ ONLINE sang OFFLINE.
• LAST CHANGE: thời điểm đổi trạng thái gần nhất.

Timeline phía dưới lưu tối đa 500 transition gần nhất vào RF-Network-Tool.monitoring-history.json. Cấu hình ON/interval/ALERT lưu ở RF-Network-Tool.monitoring.json.

Monitoring dùng cùng persistent Ping Worker với Ping/Ping All/RF Ping. Mọi ICMP chạy ngoài UI thread. Nếu một target đang được Ping thủ công, scheduler bỏ qua vòng monitoring đó để thao tác thủ công có ưu tiên.

Lưu ý: trạng thái MONITORING dựa trên ICMP. Một thiết bị chặn Ping vẫn có thể hiện L2 Seen trong NETWORK SCAN nhưng OFFLINE trong MONITORING. Đây là khác biệt có chủ ý giữa reachability ICMP và presence lớp 2.
'@
    '6. Xử lý lỗi' = @'
XỬ LÝ LỖI

A. Tool không mở / tự tắt
1. Chạy RUN-DIAGNOSTIC.cmd.
2. Mở thư mục logs bằng nút phía trên.
3. Xem file startup-YYYYMMDD-HHMMSS.log mới nhất.

B. CIDR trống hoặc báo không hợp lệ
• Chọn lại card mạng.
• Kiểm tra card có IPv4 hợp lệ và đang Up.
• Có thể nhập CIDR thủ công, ví dụ 192.168.15.0/24.
• v0.5.4+ đã sửa lỗi PowerShell 5.1 khi tính subnet mask từ 0xFFFFFFFF.

C. Scan không thấy thiết bị / Scan báo lỗi
• Kiểm tra đúng adapter/subnet.
• Một số thiết bị chặn ICMP; tool vẫn thử Neighbor/ARP.
• Wi-Fi client isolation/VLAN có thể ngăn các máy nhìn thấy nhau.
• v0.5.6 đã sửa xung đột biến tự động PowerShell $Host trong Network Scan.
• v0.5.8 bỏ Router clients/Mở Router.
• v0.5.10 tách nhận dạng tên khỏi UI: quét IP/ARP hoàn tất trước, sau đó một helper PowerShell chạy nền tối đa 45 giây để thu DNS/PTR, ping -a, NetBIOS, mDNS/DNS-SD và SSDP/UPnP.
• Trong lúc nhận dạng tên nền, cửa sổ vẫn thao tác được; NAME có thể tự cập nhật sau khi scan IP đã xong.
• PING alias/History vẫn là fallback khi mạng không công bố hostname.
• Nếu Scan còn lỗi, gửi file logs\runtime-*.log mới nhất.

D. Không nhận UDP RF
• Kiểm tra destination IP/port trên RF.
• Kiểm tra local port trong tool.
• Kiểm tra firewall và link RJ45.

E. Tên gợi nhớ không lưu
• Đảm bảo thư mục tool có quyền ghi.
• Kiểm tra RF-Network-Tool.targets.json.
'@
    '7. File dữ liệu' = @'
FILE & THƯ MỤC DỮ LIỆU

RF-Network-Tool.targets.json
  IP/hostname + tên gợi nhớ của tab PING.

RF-Network-Tool.targets.txt
  Danh sách target tương thích với các bản cũ.

RF-Network-Tool.device-history.json
  First Seen / Last Seen / Seen Count của thiết bị scan.

RF-Network-Tool.scan-history.json
  Tối đa 50 lần scan gần nhất: Profile, CIDR, thời gian, Online/L2 Seen, response rate và concurrency thực tế.

RF-Network-Tool.monitoring.json
  Cấu hình ON/interval/ALERT của MONITORING.

RF-Network-Tool.monitoring-history.json
  Timeline chuyển trạng thái ONLINE/OFFLINE, giữ tối đa 500 event.

oui-data\
  Database IEEE OUI được tải khi người dùng nhấn Update IEEE OUI.

logs\
  startup-*.log: lỗi khởi động/diagnostic.
  runtime-*.log: lỗi callback/runtime.
  scan-*.log: chi tiết từng lần Network Scan.

Mặc định các file này nằm cạnh chương trình. Nếu thư mục chương trình không cho phép ghi, bản FINAL tự chuyển dữ liệu sang %LOCALAPPDATA%\RF-Network-Tool.
'@
    '8. Thuật ngữ nhanh' = @'
THUẬT NGỮ NHANH

IP / IPv4: địa chỉ logic của thiết bị trong mạng.
CIDR: cách biểu diễn subnet, ví dụ 192.168.15.0/24.
MAC: địa chỉ lớp liên kết của interface mạng.
ICMP / Ping: kiểm tra khả năng phản hồi và độ trễ.
TTL: trường Time To Live trong IP packet.
ARP / Neighbor: ánh xạ IP <-> MAC trong mạng cục bộ.
UDP: giao thức datagram không thiết lập kết nối.
RSSI: chỉ báo cường độ tín hiệu nhận, thường tính bằng dBm.
SNR: tỷ số tín hiệu trên nhiễu, thường tính bằng dB.
OUI: prefix MAC do IEEE cấp, có thể dùng để suy ra vendor khi MAC không bị randomize.`r`nKnownOui: fallback offline chỉ suy ra hãng NIC/module, KHÔNG khẳng định vai trò thiết bị. Jetson/GPS/RF vẫn ưu tiên hostname, protocol evidence và IEEE OUI database.
SSDP / UPnP: discovery/metadata thường gặp ở thiết bị mạng và IoT.
'@
}

foreach ($k in $script:HelpPages.Keys) { [void]$helpNav.Items.Add($k) }
$helpNav.Add_SelectedIndexChanged({
    if ($helpNav.SelectedItem) {
        $key = [string]$helpNav.SelectedItem
        if ($script:HelpPages.Contains($key)) {
            $helpText.Text = [string]$script:HelpPages[$key]
            $helpText.SelectionStart = 0
            $helpText.ScrollToCaret()
        }
    }
})
$helpNav.SelectedIndex = 0

$btnOpenLogs.Add_Click({
    try {
        $logDir = $RuntimeLogDir
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $explorer=Join-Path $env:SystemRoot 'explorer.exe';Start-Process -FilePath $explorer -ArgumentList ('"' + $logDir + '"')
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Mở logs','OK','Warning') | Out-Null }
})
$btnOpenAppDir.Add_Click({
    try { $explorer=Join-Path $env:SystemRoot 'explorer.exe';Start-Process -FilePath $explorer -ArgumentList ('"' + $BaseDir + '"') }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Mở thư mục tool','OK','Warning') | Out-Null }
})

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($source,$evt)
    if ($evt.KeyCode -eq [System.Windows.Forms.Keys]::F1) {
        $tabs.SelectedTab = $tabHelp
        $evt.SuppressKeyPress = $true
    }
})

$form.Add_Shown({
    Set-HelpSplitterLayout
    Load-DeviceHistory
    Load-ScanHistory
    Load-MonitoringConfig
    Load-MonitoringHistory
    $script:MainForm=$form
    Refresh-Adapters
    Refresh-ScanAdapters
    if(-not(Start-PingWorker)){Add-Log $pingLog 'Cảnh báo: Ping Worker chưa khởi động; sẽ thử lại khi ping.'}
    if(Test-Path -LiteralPath $OuiCacheFile){
        [void](Start-OuiCacheLoad)
    } elseif((Test-Path -LiteralPath (Join-Path $OuiDir 'oui.csv')) -or (Test-Path -LiteralPath (Join-Path $OuiDir 'mam.csv')) -or (Test-Path -LiteralPath (Join-Path $OuiDir 'oui36.csv'))){
        try {
            $btnUpdateOui.Enabled=$false
            $lblScanStatus.Text='Đang build IEEE OUI cache nền từ CSV hiện có...'
            $lblScanStatus.ForeColor=[Drawing.Color]::DarkOrange
            if(Start-OuiTaskWorker 'OUI_BUILD_CACHE'){$ouiTaskTimer.Start()}
        } catch {Write-RuntimeLog 'OUI-STARTUP' ($_ | Out-String);$btnUpdateOui.Enabled=$true}
    } else {
        $lblScanStatus.Text='Sẵn sàng. Nhấn Scan / Rescan. Có thể Update IEEE OUI khi cần.'
    }
    $loadedCount = 0
    foreach ($item in @(Load-TargetEntries)) {
        try {
            if (Add-TargetRow ([string]$item.Target) ([string]$item.Name)) { $loadedCount++ }
        } catch { Write-RuntimeLog 'TARGETS-LOAD' ($_ | Out-String) }
    }
    if($loadedCount -gt 0){Save-Targets}
    Sync-MonitoringWithTargets -Save
    Refresh-MonitorTimelineGrid
    if($script:DeepUiE2eMode){
        try {
            $testDevice=[pscustomobject]@{Status='Online';Type='This PC';Brand='';Model='';Name='Loopback';IP='127.0.0.1';MAC='';Latency='0 ms';OS='Windows';Confidence='High';NameSource='System DNS';ScanEvidence=@();DiscoveryEvidence=@()}
            $ri=$gridScan.Rows.Add('Online','This PC','','','Loopback','System DNS','127.0.0.1','','0 ms',(Get-Date).ToString('HH:mm:ss'))
            $testRow=$gridScan.Rows[$ri];$testRow.Tag=$testDevice;$gridScan.CurrentCell=$testRow.Cells['IP'];$tabs.SelectedTab=$tabScan
            $script:DeepUiE2eLaunchState.Row=$testRow
            $script:DeepUiE2eLaunchState.Timer=New-Object System.Windows.Forms.Timer;$script:DeepUiE2eLaunchState.Timer.Interval=250
            $script:DeepUiE2eLaunchState.Timer.Add_Tick({
                $script:DeepUiE2eLaunchState.Timer.Stop()
                try {Show-DeviceDetails $script:DeepUiE2eLaunchState.Row $null}
                catch {Write-DeepUiE2eResult 'FAIL' 'open-details' $_.Exception.Message $null}
                finally {try{$script:DeepUiE2eLaunchState.Timer.Dispose()}catch{Write-RuntimeLog 'DEEP-UI-E2E-LAUNCH-CLEANUP' $_.Exception.Message};$script:DeepUiE2eLaunchState.Timer=$null;$script:DeepUiE2eLaunchState.Row=$null;if(-not $form.IsDisposed){$form.Close()}}
            })
            $script:DeepUiE2eLaunchState.Timer.Start()
        } catch {
            Write-DeepUiE2eResult 'FAIL' 'seed-device' $_.Exception.Message $null
            $form.Close()
        }
    }
    Add-Log $pingLog "RF & Network Diagnostic Tool v$AppVersion Full QA / CI-E2E đã sẵn sàng. Tên gợi nhớ sửa trực tiếp trong bảng PING (double-click/F2)."
    Add-Log $rfLog 'Tab RF UDP: nhập local port -> Start UDP. Packet nhận được sẽ hiện TEXT/HEX và tự dò RSSI/SNR.'
})

$form.Add_FormClosing({ param($source,$evt); try{$scanWorkerTimer.Stop()}catch{}; try{$pingWorkerTimer.Stop()}catch{}; try{$monitorTimer.Stop()}catch{}; try{$ouiTaskTimer.Stop()}catch{}; try{$ouiCacheTimer.Stop()}catch{}; Stop-ScanWorker $true; Stop-PingWorker; Stop-OuiTaskWorker; try{if($script:OuiCacheReader){$script:OuiCacheReader.Dispose();$script:OuiCacheReader=$null}}catch{}; try{$udpTimer.Stop()}catch{}; try{$timer.Stop()}catch{}; try{$discoveryTimer.Stop()}catch{}; Stop-DiscoveryWorker; Stop-UdpListener; Save-Targets; Save-MonitoringConfig; Save-MonitoringHistory; Save-DeviceHistory; Save-ScanHistory; try{if($monitorAlertTip){$monitorAlertTip.Dispose()}}catch{}; Remove-TransientRuntimeFiles })
$form.Add_Shown({ Update-ScanHeaderLayout })
Update-ScanHeaderLayout
try { [void]$form.ShowDialog() }
finally {
    try { Stop-ScanWorker $true } catch { }
    try { Stop-DiscoveryWorker } catch { }
    try { Stop-PingWorker } catch { }
    try { Stop-OuiTaskWorker } catch { }
    try { if($script:OuiCacheReader){$script:OuiCacheReader.Dispose();$script:OuiCacheReader=$null} } catch { }
    try { Stop-UdpListener } catch { }
    try { Save-MonitoringConfig; Save-MonitoringHistory } catch { }
    try { if($monitorAlertTip){$monitorAlertTip.Dispose()} } catch { }
    try { Remove-TransientRuntimeFiles } catch { }
    foreach($tm in @($udpTimer,$timer,$discoveryTimer,$scanWorkerTimer,$pingWorkerTimer,$monitorTimer,$ouiTaskTimer,$ouiCacheTimer)){if($tm){try{$tm.Stop()}catch{};try{$tm.Dispose()}catch{}}}
    try { if($script:ThreadExceptionHandler){[System.Windows.Forms.Application]::remove_ThreadException($script:ThreadExceptionHandler)} } catch { }
    try { if($script:DomainExceptionHandler){[System.AppDomain]::CurrentDomain.remove_UnhandledException($script:DomainExceptionHandler)} } catch { }
    try { if($form -and -not $form.IsDisposed){$form.Dispose()} } catch { }
}
