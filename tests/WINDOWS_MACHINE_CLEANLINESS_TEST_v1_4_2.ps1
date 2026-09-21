[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$checker=Join-Path $root 'tests\WINDOWS_MACHINE_CLEANLINESS_v1_4_2.ps1'
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fail=New-Object System.Collections.Generic.List[string]

function Assert-True([bool]$condition,[string]$name){
    if($condition){Write-Host ('PASS '+$name) -ForegroundColor Green}
    else{Write-Host ('FAIL '+$name) -ForegroundColor Red;[void]$fail.Add($name)}
}

function Invoke-Checker([string]$mode,[string]$stateFile,[int]$timeoutSec=2){
    $quotedChecker='"'+$checker+'"'
    $quotedState='"'+$stateFile+'"'
    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quotedChecker -Mode $mode -StateFile $quotedState -TimeoutSec $timeoutSec"
    $p=Start-Process -FilePath $psExe -ArgumentList $argLine -WindowStyle Hidden -PassThru
    try{
        if(-not $p.WaitForExit(15000)){try{$p.Kill()}catch{};throw "Checker timeout in $mode mode."}
        $p.Refresh()
        return [int]$p.ExitCode
    }finally{try{$p.Dispose()}catch{}}
}

Assert-True (Test-Path -LiteralPath $checker) 'Machine-cleanliness checker exists'
if($fail.Count){exit 1}

$token=[guid]::NewGuid().ToString('N')
$fixture=Join-Path $env:TEMP ('RFT-v142-test-cleanliness-fixture-'+$token)
$stateDirty=Join-Path $env:TEMP ('RFT-cleanliness-test-dirty-'+$token+'.json')
$stateLeak=Join-Path $env:TEMP ('RFT-cleanliness-test-leak-'+$token+'.json')
$stateClean=Join-Path $env:TEMP ('RFT-cleanliness-test-clean-'+$token+'.json')

try{
    New-Item -ItemType Directory -Path $fixture -Force|Out-Null
    $rc=Invoke-Checker 'Snapshot' $stateDirty 1
    Assert-True ($rc -ne 0) 'Dirty baseline fails closed'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stateDirty -Force -ErrorAction SilentlyContinue

    $rc=Invoke-Checker 'Snapshot' $stateLeak 1
    Assert-True ($rc -eq 0 -and (Test-Path -LiteralPath $stateLeak)) 'Clean baseline snapshot succeeds'
    New-Item -ItemType Directory -Path $fixture -Force|Out-Null
    $rc=Invoke-Checker 'Assert' $stateLeak 1
    Assert-True ($rc -ne 0) 'Post-run temp leak fails closed'
    Assert-True (-not(Test-Path -LiteralPath $stateLeak)) 'Leak assertion removes state file'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue

    $rc=Invoke-Checker 'Snapshot' $stateClean 1
    Assert-True ($rc -eq 0 -and (Test-Path -LiteralPath $stateClean)) 'Second clean baseline snapshot succeeds'
    $rc=Invoke-Checker 'Assert' $stateClean 1
    Assert-True ($rc -eq 0) 'Clean post-run assertion succeeds'
    Assert-True (-not(Test-Path -LiteralPath $stateClean)) 'Clean assertion removes state file'
}finally{
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stateDirty -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stateLeak -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stateClean -Force -ErrorAction SilentlyContinue
}

if($fail.Count){Write-Host ('FAILED: '+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL WINDOWS MACHINE CLEANLINESS TESTS PASSED' -ForegroundColor Green
exit 0
