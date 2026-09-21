[CmdletBinding()]
param(
    [ValidateSet('Pre','Post')][string]$Phase='Post',
    [string]$EvidencePath=''
)

$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if([string]::IsNullOrWhiteSpace($EvidencePath)){
    $EvidencePath=Join-Path $root ("ci-artifacts\runner-cleanliness-{0}.json" -f $Phase.ToLowerInvariant())
}
$evidenceDir=Split-Path -Parent $EvidencePath
if($evidenceDir -and -not(Test-Path -LiteralPath $evidenceDir)){
    New-Item -ItemType Directory -Path $evidenceDir -Force|Out-Null
}

$ownedScripts=@(
    'RF-Network-Tool-Launcher.ps1',
    'RF-Network-Tool-Portable.ps1',
    'RF-Network-Tool-DiscoveryWorker.ps1',
    'RF-Network-Tool-ScanWorker.ps1',
    'RF-Network-Tool-PingWorker.ps1',
    'RF-Network-Tool-TaskWorker.ps1'
)
$processNames=@('powershell.exe','pwsh.exe','cscript.exe','wscript.exe')
$processHits=New-Object System.Collections.Generic.List[object]

foreach($p in @(Get-CimInstance Win32_Process -ErrorAction Stop)){
    if([int]$p.ProcessId -eq $PID){continue}
    $name=[string]$p.Name
    if($processNames -notcontains $name.ToLowerInvariant()){continue}
    $cmd=[string]$p.CommandLine
    if([string]::IsNullOrWhiteSpace($cmd)){continue}

    $kind=''
    foreach($scriptName in $ownedScripts){
        $sourceToken=Join-Path $root $scriptName
        $sourceOwned=($cmd.IndexOf($sourceToken,[StringComparison]::OrdinalIgnoreCase) -ge 0)
        $sandboxOwned=($cmd.IndexOf($scriptName,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $cmd -match 'RFT-v142-e2e-[0-9a-f]+')
        if($sourceOwned -or $sandboxOwned){$kind=$scriptName;break}
    }
    if($kind){
        [void]$processHits.Add([pscustomobject]@{pid=[int]$p.ProcessId;kind=$kind})
    }
}

$tempHits=New-Object System.Collections.Generic.List[object]
foreach($spec in @(
    @('gui-e2e','RFT-v142-e2e-*'),
    @('real-lan','RFT-real-lan-*')
)){
    foreach($d in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter $spec[1] -ErrorAction SilentlyContinue)){
        [void]$tempHits.Add([pscustomobject]@{kind=$spec[0];name=[string]$d.Name})
    }
}

$summary=[ordered]@{
    schemaVersion=1
    phase=$Phase
    checkedAt=(Get-Date).ToString('o')
    activeProcessCount=$processHits.Count
    residualTempDirCount=$tempHits.Count
    activeProcessKinds=@($processHits.ToArray()|ForEach-Object {$_.kind}|Sort-Object -Unique)
    residualTempKinds=@($tempHits.ToArray()|ForEach-Object {$_.kind}|Sort-Object -Unique)
    privacy='Command lines, user paths, usernames and machine names are not persisted.'
}
[IO.File]::WriteAllText(
    $EvidencePath,
    ($summary|ConvertTo-Json -Depth 5),
    (New-Object Text.UTF8Encoding($true))
)

if($processHits.Count -gt 0 -or $tempHits.Count -gt 0){
    Write-Host ("FAIL RUNNER CLEANLINESS {0}: activeProcesses={1} residualTempDirs={2}" -f $Phase,$processHits.Count,$tempHits.Count) -ForegroundColor Red
    foreach($kind in @($summary.activeProcessKinds)){Write-Host ("  active process kind: "+$kind) -ForegroundColor Red}
    foreach($kind in @($summary.residualTempKinds)){Write-Host ("  residual temp kind: "+$kind) -ForegroundColor Red}
    exit 1
}

Write-Host ("RUNNER CLEANLINESS {0} PASSED" -f $Phase) -ForegroundColor Green
exit 0
