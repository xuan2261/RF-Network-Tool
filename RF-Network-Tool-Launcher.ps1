param(
    [switch]$Diagnostic
)

$ErrorActionPreference = 'Stop'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainScript = Join-Path $BaseDir 'RF-Network-Tool-Portable.ps1'
$VersionFile = Join-Path $BaseDir 'VERSION'
$AppVersion = ''
$WorkerScript = Join-Path $BaseDir 'RF-Network-Tool-DiscoveryWorker.ps1'
$ScanWorkerScript = Join-Path $BaseDir 'RF-Network-Tool-ScanWorker.ps1'
$PingWorkerScript = Join-Path $BaseDir 'RF-Network-Tool-PingWorker.ps1'
$TaskWorkerScript = Join-Path $BaseDir 'RF-Network-Tool-TaskWorker.ps1'
$RoutePlannerScript = Join-Path $BaseDir 'RF-Network-Tool-RoutePlanner.ps1'
$StartScript = Join-Path $BaseDir 'START-RF-NETWORK-TOOL.vbs'
$SystemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$DataDir = $BaseDir
$LogFile = ''
$InstanceLockStream = $null
$InstanceLockPath = ''

function Test-DirectoryWritable([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
        $probe = Join-Path $dir ('.rft-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($probe,'ok',[Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}


function Acquire-InstanceLock {
    # Use a per-data-directory locked file instead of a global mutex. This limits one
    # GUI instance to the data store that would otherwise share scan/cache/history files.
    $script:InstanceLockPath = Join-Path $DataDir 'RF-Network-Tool.instance.lock'
    try {
        $script:InstanceLockStream = [IO.File]::Open($script:InstanceLockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $script:InstanceLockStream.SetLength(0)
        $payload = "PID=$PID`r`nStarted=$((Get-Date).ToString('o'))`r`nBaseDir=$BaseDir`r`nDataDir=$DataDir`r`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $script:InstanceLockStream.Write($bytes,0,$bytes.Length)
        $script:InstanceLockStream.Flush()
        return $true
    } catch [System.IO.IOException] {
        return $false
    }
}

function Release-InstanceLock {
    if($script:InstanceLockStream){
        try{$script:InstanceLockStream.Dispose()}catch{}
        $script:InstanceLockStream=$null
        if($script:InstanceLockPath){try{Remove-Item -LiteralPath $script:InstanceLockPath -Force -ErrorAction SilentlyContinue}catch{}}
    }
}

function Show-Fatal([string]$message) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($message,'RF Network Tool - Startup Error','OK','Error') | Out-Null
    } catch { try{Write-Host $message -ForegroundColor Red}catch{} }
}

# Bootstrap a writable data/log directory before the normal launcher log exists.
try {
    if (-not (Test-DirectoryWritable $DataDir)) {
        $fallbackRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($fallbackRoot)) { throw 'Không xác định được LOCALAPPDATA.' }
        $DataDir = Join-Path $fallbackRoot 'RF-Network-Tool'
        if (-not (Test-DirectoryWritable $DataDir)) { throw "Không có thư mục ghi dữ liệu khả dụng. Đã thử: $BaseDir và $DataDir" }
    }
    $env:RFT_BASEDIR = $BaseDir
    $env:RFT_DATADIR = $DataDir
    $LogDir = Join-Path $DataDir 'logs'
    if (-not (Test-Path -LiteralPath $LogDir)) { [void](New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop) }
    $Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $LogFile = Join-Path $LogDir ("startup-$Stamp.log")
} catch {
    $bootstrapMessage="RF Network Tool không thể chuẩn bị thư mục dữ liệu.`r`n`r`n$($_.Exception.Message)"
    if($Diagnostic){[Console]::Error.WriteLine($bootstrapMessage)}
    else{Show-Fatal $bootstrapMessage}
    exit 1
}

function Write-LaunchLog([string]$text) {
    try {
        $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))] $text"
        [IO.File]::AppendAllText($LogFile,$line+[Environment]::NewLine,[Text.Encoding]::UTF8)
    } catch { }
}

try {
    if (-not (Test-Path -LiteralPath $VersionFile)) { throw "Không tìm thấy VERSION: $VersionFile" }
    $AppVersion = ([IO.File]::ReadAllText($VersionFile)).Trim()
    if ($AppVersion -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION không hợp lệ: $AppVersion" }
    Write-LaunchLog "Launcher v$AppVersion Full QA / CI-E2E start"
    Write-LaunchLog "PowerShell=$($PSVersionTable.PSVersion) Edition=$($PSVersionTable.PSEdition) OS=$env:OS"
    Write-LaunchLog "ApartmentState=$([Threading.Thread]::CurrentThread.ApartmentState)"
    Write-LaunchLog "BaseDir=$BaseDir"
    Write-LaunchLog "DataDir=$DataDir"

    if ($env:OS -ne 'Windows_NT') { throw 'Ứng dụng này chỉ hỗ trợ Windows.' }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw "Cần Windows PowerShell 5.1 trở lên. Hiện tại: $($PSVersionTable.PSVersion)" }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) { throw 'PowerShell phải chạy ở STA. Hãy dùng START-RF-NETWORK-TOOL.vbs hoặc RUN-PORTABLE.cmd.' }
    if (-not (Test-Path -LiteralPath $SystemPowerShell)) { throw "Không tìm thấy Windows PowerShell hệ thống: $SystemPowerShell" }
    foreach($required in @($MainScript,$WorkerScript,$ScanWorkerScript,$PingWorkerScript,$TaskWorkerScript,$RoutePlannerScript,$StartScript,$VersionFile)) { if(-not (Test-Path -LiteralPath $required)){throw "Không tìm thấy file bắt buộc: $required"} }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Write-LaunchLog 'WinForms/System.Drawing load: PASS'

    foreach($spec in @(@('Main',$MainScript),@('DiscoveryWorker',$WorkerScript),@('ScanWorker',$ScanWorkerScript),@('PingWorker',$PingWorkerScript),@('TaskWorker',$TaskWorkerScript),@('RoutePlanner',$RoutePlannerScript))) {
        $tokens=$null;$parseErrors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($spec[1],[ref]$tokens,[ref]$parseErrors)
        if($parseErrors -and $parseErrors.Count -gt 0){
            foreach($pe in $parseErrors){
                Write-LaunchLog ("$($spec[0]) PARSE ERROR line {0}, col {1}: {2}" -f $pe.Extent.StartLineNumber,$pe.Extent.StartColumnNumber,$pe.Message)
                if($pe.Extent -and $pe.Extent.Text){Write-LaunchLog ('PARSE EXTENT: '+$pe.Extent.Text.Replace("`r",' ').Replace("`n",' '))}
            }
            throw "$($spec[0]) script có $($parseErrors.Count) lỗi cú pháp."
        }
        Write-LaunchLog "$($spec[0]) parser: PASS"
    }

    $vbsBytes=[IO.File]::ReadAllBytes($StartScript)
    if($vbsBytes.Length -ge 3 -and $vbsBytes[0] -eq 0xEF -and $vbsBytes[1] -eq 0xBB -and $vbsBytes[2] -eq 0xBF){throw 'START-RF-NETWORK-TOOL.vbs có UTF-8 BOM; Windows Script Host có thể báo Invalid character.'}
    $vbsText=[Text.Encoding]::ASCII.GetString($vbsBytes)
    if(-not $vbsText.StartsWith('Option Explicit')){throw 'START-RF-NETWORK-TOOL.vbs không bắt đầu bằng Option Explicit.'}
    if($vbsText -match '[^\x00-\x7F]'){throw 'START-RF-NETWORK-TOOL.vbs phải là ASCII để tương thích Windows Script Host.'}
    Write-LaunchLog 'VBScript launcher encoding: PASS (ASCII/no BOM)'
    Write-LaunchLog 'Data directory write test: PASS'

    if ($Diagnostic) {
        Write-LaunchLog 'Diagnostic-only mode: PASS'
        Write-Host 'PASS: PowerShell/STA/WinForms/main+workers+route-planner parsers/VBScript/data-dir checks completed.' -ForegroundColor Green
        Write-Host "BaseDir: $BaseDir"
        Write-Host "DataDir: $DataDir"
        Write-Host "Log: $LogFile"
        exit 0
    }

    if(-not (Acquire-InstanceLock)){
        Write-LaunchLog "Another instance already owns the data-directory lock: $InstanceLockPath"
        Show-Fatal "RF Network Tool đang chạy ở một cửa sổ khác dùng cùng thư mục dữ liệu.`r`n`r`nHãy đóng cửa sổ hiện tại trước khi mở thêm.`r`n`r`nDataDir: $DataDir"
        exit 2
    }
    Write-LaunchLog "Single-instance lock: PASS ($InstanceLockPath)"

    Write-LaunchLog 'Starting main GUI script (dot-sourced for WinForms callback scope stability)'
    . $MainScript
    Write-LaunchLog 'Main GUI exited normally'
    exit 0
}
catch {
    $err=$_
    Write-LaunchLog ('FATAL: '+$err.Exception.Message)
    if($err.InvocationInfo){Write-LaunchLog ('At: '+$err.InvocationInfo.PositionMessage.Replace("`r",' ').Replace("`n",' '))}
    Write-LaunchLog ($err | Out-String)
    $msg="RF Network Tool không thể khởi động.`r`n`r`n$($err.Exception.Message)`r`n`r`nChi tiết đã lưu tại:`r`n$LogFile"
    if($Diagnostic){[Console]::Error.WriteLine($msg)}
    else{Show-Fatal $msg}
    exit 1
}
finally {
    Release-InstanceLock
}