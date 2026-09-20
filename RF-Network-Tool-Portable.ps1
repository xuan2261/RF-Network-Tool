Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$BaseDir = if ($env:RFT_BASEDIR -and (Test-Path -LiteralPath $env:RFT_BASEDIR)) { $env:RFT_BASEDIR } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
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
        param($sender,$e)
        if ($script:HandlingUiException) { return }
        $script:HandlingUiException = $true
        try {
            $ex = if ($e -and $e.Exception) { $e.Exception } else { New-Object System.Exception('Unknown WinForms exception') }
            Write-RuntimeLog 'UI-UNHANDLED' ($ex.ToString())
            [System.Windows.Forms.MessageBox]::Show("Ứng dụng vừa chặn một lỗi giao diện ngoài dự kiến.`r`n`r`n$($ex.Message)`r`n`r`nChi tiết: $RuntimeLogFile`r`n`r`nNếu lỗi lặp lại, hãy đóng và mở lại tool.",'RF Network Tool - Runtime Error','OK','Error') | Out-Null
        } catch { } finally { $script:HandlingUiException = $false }
    }
    [System.Windows.Forms.Application]::add_ThreadException($script:ThreadExceptionHandler)
} catch { Write-RuntimeLog 'EXCEPTION-HANDLER' ("ThreadException setup failed: " + $_.Exception.Message) }

try {
    $script:DomainExceptionHandler = [System.UnhandledExceptionEventHandler]{
        param($sender,$e)
        try {
            $obj = $e.ExceptionObject
            $msg = if ($obj -is [System.Exception]) { $obj.ToString() } else { [string]$obj }
            Write-RuntimeLog 'APPDOMAIN-UNHANDLED' ("Terminating=$($e.IsTerminating) `r`n$msg")
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
            if ($metrics.RSSI -ne $null -or $metrics.SNR -ne $null) {
                $rssiText = if ($metrics.RSSI -ne $null) { "$($metrics.RSSI) dBm" } else { '---' }
                $snrText  = if ($metrics.SNR  -ne $null) { "$($metrics.SNR) dB" } else { '---' }
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
        $script:DeviceHistory[$key]=[pscustomobject]@{Key=$key;FirstSeen=$now;LastSeen=$now;SeenCount=0;LastIP=$device.IP;LastMAC=$device.MAC;LastName=$device.Name;LastBrand=$device.Brand;LastModel=$device.Model;LastType=$device.Type}
    }
    $h=$script:DeviceHistory[$key]
    $h.LastSeen=$now
    if($incrementSeen){$h.SeenCount=[int]$h.SeenCount+1}
    $h.LastIP=$device.IP;$h.LastMAC=$device.MAC
    if($device.Name){$h.LastName=$device.Name}; if($device.Brand){$h.LastBrand=$device.Brand}; if($device.Model){$h.LastModel=$device.Model}; if($device.Type){$h.LastType=$device.Type}
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
        }
        $script:ScanHistory=@($record)+@($script:ScanHistory | Where-Object {[string]$_.RunId -ne [string]$record.RunId} | Select-Object -First 49)
        Save-ScanHistory
    } catch { Write-RuntimeLog 'SCAN-HISTORY' ($_ | Out-String) }
}

function Get-MacCharacteristics([string]$mac) {
    $clean=if($mac){($mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()}else{''}
    if($clean.Length -lt 12){return [pscustomobject]@{Scope='Unknown';Traffic='Unknown';Normalized=$clean}}
    try {