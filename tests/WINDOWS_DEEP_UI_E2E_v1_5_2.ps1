[CmdletBinding()]
param(
    [ValidateRange(20,120)][int]$TimeoutSec=70,
    [switch]$FailureExitSelfTest
)

$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$launcher=Join-Path $root 'RF-Network-Tool-Launcher.ps1'
$artifactDir=Join-Path $root 'ci-artifacts'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$tmp=Join-Path $env:TEMP ('RFT-deep-ui-e2e-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$resultFile=Join-Path $tmp 'deep-ui-e2e-result.json'
$artifactFile=Join-Path $artifactDir 'deep-ui-e2e.json'
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$proc=$null
$scriptExitCode=1
$oldBase=$env:RFT_BASEDIR
$oldData=$env:RFT_DATADIR
$oldMode=$env:RFT_DEEP_UI_E2E
$oldResult=$env:RFT_DEEP_UI_E2E_RESULT

function Restore-Env([string]$name,[string]$value){
    if($null -eq $value){Remove-Item -LiteralPath ("Env:"+$name) -ErrorAction SilentlyContinue}
    else{Set-Item -LiteralPath ("Env:"+$name) -Value $value}
}

function Get-SafeDetail([string]$text){
    if($null -eq $text){return ''}
    foreach($value in @([string]$env:USERPROFILE,[string]$env:USERNAME,[string]$env:COMPUTERNAME,[string]$root,[string]$tmp)){
        if(-not [string]::IsNullOrWhiteSpace($value)){$text=$text.Replace($value,'<REDACTED>')}
    }
    $text=[regex]::Replace($text,'(?i)\b(?:[0-9A-F]{2}[-:]){5}[0-9A-F]{2}\b','<MAC>')
    $text=[regex]::Replace($text,'(?<!\d)(\d{1,3}\.){3}\d{1,3}(?!\d)','<IPv4>')
    if($text.Length -gt 1200){$text=$text.Substring($text.Length-1200)}
    return $text
}

if($FailureExitSelfTest){
    Write-Host 'FAIL deep_ui_e2e :: intentional failure-exit self-test'
    exit 23
}

try {
    if(-not [Environment]::UserInteractive){throw 'Interactive desktop is required for deep UI E2E.'}
    if(-not (Test-Path -LiteralPath $launcher)){throw "Launcher script missing: $launcher"}

    $env:RFT_BASEDIR=$root
    $env:RFT_DATADIR=$tmp
    $env:RFT_DEEP_UI_E2E='1'
    $env:RFT_DEEP_UI_E2E_RESULT=$resultFile

    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$psExe
    $psi.Arguments="-STA -NoProfile -ExecutionPolicy Bypass -File \`"$launcher\`""
    $psi.UseShellExecute=$false
    $psi.RedirectStandardError=$true
    $proc=New-Object Diagnostics.Process
    $proc.StartInfo=$psi
    if(-not $proc.Start()){throw 'Failed to start deep UI E2E launcher process.'}

    if(-not $proc.WaitForExit($TimeoutSec*1000)){
        try{$proc.Kill()}catch{Write-Host ("WARN kill timeout process: "+$_.Exception.Message)}
        throw ("Deep UI E2E exceeded {0}s." -f $TimeoutSec)
    }

    $stderrText=''
    try{$stderrText=$proc.StandardError.ReadToEnd()}catch{Write-Host ("WARN stderr read failed: "+$_.Exception.Message)}
    if(-not (Test-Path -LiteralPath $resultFile)){
        $safeErr=Get-SafeDetail $stderrText
        $suffix=if([string]::IsNullOrWhiteSpace($safeErr)){''}else{" stderr=$safeErr"}
        throw "Deep UI E2E result was not produced (exit=$($proc.ExitCode)).$suffix"
    }

    $result=[IO.File]::ReadAllText($resultFile) | ConvertFrom-Json -ErrorAction Stop
    Copy-Item -LiteralPath $resultFile -Destination $artifactFile -Force

    if([string]$result.status -ne 'PASS'){throw "Deep UI E2E status=$($result.status) stage=$($result.stage) detail=$($result.detail)"}
    if([string]$result.stage -ne 'completed'){throw "Deep UI E2E unexpected stage: $($result.stage)"}
    if(-not [bool]$result.workerCompleted){throw 'Deep worker did not report completion.'}
    if(-not [bool]$result.workerSucceeded){throw 'Deep worker did not report success.'}
    if([string]$result.lastPhase -ne 'Completed'){throw "Deep worker final phase was '$($result.lastPhase)'."}
    if(-not [string]::IsNullOrWhiteSpace([string]$result.lastError)){throw "Deep worker reported error: $($result.lastError)"}
    if($proc.ExitCode -ne 0){throw "Deep UI launcher process exit code $($proc.ExitCode)."}

    Write-Host 'PASS deep UI opened deterministic Device Details fixture'
    Write-Host 'PASS real Phân tích sâu / Refresh button callback completed'
    Write-Host 'PASS worker heartbeat/progress observed'
    Write-Host 'PASS deep worker result succeeded'
    Write-Host 'PASS controls restored after completion'
    Write-Host 'DEEP UI E2E PASSED' -ForegroundColor Green
    $scriptExitCode=0
}
catch {
    $safeDetail=Get-SafeDetail $_.Exception.Message
    $failure=[ordered]@{
        schemaVersion=1
        status='FAIL'
        stage='test-wrapper'
        detail=$safeDetail
        recordedAt=(Get-Date).ToString('o')
    }
    try{$failure|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $artifactFile -Encoding UTF8}catch{Write-Host ("WARN evidence write failed: "+$_.Exception.Message)}
    Write-Host ("FAIL deep_ui_e2e :: "+$safeDetail) -ForegroundColor Red
    $scriptExitCode=1
}
finally {
    if($proc){
        try{if(-not $proc.HasExited){$proc.Kill()}}catch{Write-Host ("WARN process cleanup: "+$_.Exception.Message)}
        try{$proc.Dispose()}catch{Write-Host ("WARN process dispose: "+$_.Exception.Message)}
    }
    Restore-Env 'RFT_BASEDIR' $oldBase
    Restore-Env 'RFT_DATADIR' $oldData
    Restore-Env 'RFT_DEEP_UI_E2E' $oldMode
    Restore-Env 'RFT_DEEP_UI_E2E_RESULT' $oldResult
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $scriptExitCode
