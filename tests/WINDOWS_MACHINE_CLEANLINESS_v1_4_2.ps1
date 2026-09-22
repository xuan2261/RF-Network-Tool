[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Snapshot','Assert')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$StateFile,
    [int]$TimeoutSec=15
)

$ErrorActionPreference='Stop'
$processTokens=@(
    'RF-Network-Tool-Launcher.ps1',
    'RF-Network-Tool-Portable.ps1',
    'RF-Network-Tool-ScanWorker.ps1',
    'RF-Network-Tool-DiscoveryWorker.ps1',
    'RF-Network-Tool-PingWorker.ps1',
    'RF-Network-Tool-TaskWorker.ps1',
    'RFT-v142-e2e-',
    'RFT-versioned-e2e-',
    'RFT-real-lan-'
)
$tempPrefixes=@(
    'RFT-v142-test-',
    'RFT-v142-chaos-',
    'RFT-v142-perf-',
    'RFT-v142-e2e-',
    'RFT-versioned-e2e-',
    'RFT-real-lan-'
)

function Get-RftProcesses {
    $items=New-Object System.Collections.Generic.List[object]
    foreach($proc in @(Get-CimInstance Win32_Process -ErrorAction Stop)){
        if([int]$proc.ProcessId -eq [int]$PID){continue}
        $cmd=[string]$proc.CommandLine
        if([string]::IsNullOrWhiteSpace($cmd)){continue}
        $matched=$false
        foreach($token in $processTokens){
            if($cmd.IndexOf($token,[StringComparison]::OrdinalIgnoreCase) -ge 0){$matched=$true;break}
        }
        if(-not $matched){continue}
        $created=[string]$proc.CreationDate
        [void]$items.Add([pscustomobject]@{
            fingerprint=("{0}|{1}" -f [int]$proc.ProcessId,$created)
            processId=[int]$proc.ProcessId
            name=[string]$proc.Name
        })
    }
    return @($items.ToArray())
}

function Get-RftTempArtifacts {
    $items=New-Object System.Collections.Generic.List[object]
    foreach($prefix in $tempPrefixes){
        foreach($dir in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter ($prefix+'*') -ErrorAction SilentlyContinue)){
            [void]$items.Add([pscustomobject]@{path=[string]$dir.FullName;name=[string]$dir.Name})
        }
    }
    return @($items.ToArray()|Sort-Object path -Unique)
}

function Remove-StateFile {
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}

if($Mode -eq 'Snapshot'){
    $processes=@(Get-RftProcesses)
    $tempArtifacts=@(Get-RftTempArtifacts)
    if($processes.Count -or $tempArtifacts.Count){
        Write-Host ("FAIL machine cleanliness baseline: processLeaks={0} tempArtifacts={1}" -f $processes.Count,$tempArtifacts.Count) -ForegroundColor Red
        foreach($p in $processes){Write-Host ("LEAK process pid={0} name={1}" -f $p.processId,$p.name) -ForegroundColor Red}
        foreach($d in $tempArtifacts){Write-Host ("LEAK temp name={0}" -f $d.name) -ForegroundColor Red}
        Remove-StateFile
        exit 1
    }
    $parent=Split-Path -Parent $StateFile
    if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $state=[ordered]@{
        schemaVersion=1
        capturedAt=(Get-Date).ToString('o')
        processFingerprints=@($processes|ForEach-Object {$_.fingerprint})
        tempPaths=@($tempArtifacts|ForEach-Object {$_.path})
    }
    [IO.File]::WriteAllText($StateFile,($state|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))
    Write-Host 'PASS machine cleanliness baseline: processLeaks=0 tempArtifacts=0' -ForegroundColor Green
    exit 0
}

if(-not(Test-Path -LiteralPath $StateFile)){throw "Machine-cleanliness state file is missing: $StateFile"}
$state=[IO.File]::ReadAllText($StateFile)|ConvertFrom-Json
if([int]$state.schemaVersion -ne 1){throw 'Unsupported machine-cleanliness state schema.'}
$baselineProcesses=@{}
foreach($fp in @($state.processFingerprints)){$baselineProcesses[[string]$fp]=$true}
$baselineTemp=@{}
foreach($path in @($state.tempPaths)){$baselineTemp[[string]$path]=$true}

$deadline=[DateTime]::UtcNow.AddSeconds([Math]::Max(1,$TimeoutSec))
$newProcesses=@()
$newTemp=@()
do{
    $newProcesses=@(Get-RftProcesses|Where-Object {-not $baselineProcesses.ContainsKey([string]$_.fingerprint)})
    $newTemp=@(Get-RftTempArtifacts|Where-Object {-not $baselineTemp.ContainsKey([string]$_.path)})
    if(-not $newProcesses.Count -and -not $newTemp.Count){break}
    Start-Sleep -Milliseconds 250
}while([DateTime]::UtcNow -lt $deadline)

try{
    if($newProcesses.Count -or $newTemp.Count){
        Write-Host ("FAIL machine cleanliness post-run: processLeaks={0} tempArtifacts={1}" -f $newProcesses.Count,$newTemp.Count) -ForegroundColor Red
        foreach($p in $newProcesses){Write-Host ("LEAK process pid={0} name={1}" -f $p.processId,$p.name) -ForegroundColor Red}
        foreach($d in $newTemp){Write-Host ("LEAK temp name={0}" -f $d.name) -ForegroundColor Red}
        exit 1
    }
    Write-Host 'PASS machine cleanliness post-run: processLeaks=0 tempArtifacts=0' -ForegroundColor Green
    exit 0
}finally{
    Remove-StateFile
}
