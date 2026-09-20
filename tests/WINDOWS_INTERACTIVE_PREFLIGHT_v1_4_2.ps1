param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$artifactDir=Join-Path $root 'ci-artifacts';New-Item -ItemType Directory -Path $artifactDir -Force|Out-Null
$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$c,[string]$n){if($c){Write-Host "PASS $n" -ForegroundColor Green}else{Write-Host "FAIL $n" -ForegroundColor Red;[void]$fail.Add($n)}}
$proc=Get-Process -Id $PID
$interactive=[Environment]::UserInteractive
$sessionId=[int]$proc.SessionId
$sessionName=[string]$env:SESSIONNAME
Assert-True $interactive 'UserInteractive is true'
Assert-True ($sessionId -gt 0) 'Runner is not in Windows Session 0'
if($sessionName){Assert-True ($sessionName -notmatch '^Services$') 'SESSIONNAME is not Services'}
try{Add-Type -AssemblyName System.Windows.Forms;Assert-True $true 'System.Windows.Forms loads'}catch{Assert-True $false 'System.Windows.Forms loads'}
try{Add-Type -AssemblyName UIAutomationClient;Add-Type -AssemblyName UIAutomationTypes;Assert-True $true 'UIAutomation assemblies load'}catch{Assert-True $false 'UIAutomation assemblies load'}
$lines=@("timestamp=$((Get-Date).ToString('o'))","computer=$env:COMPUTERNAME","user=$env:USERNAME","userInteractive=$interactive","sessionId=$sessionId","sessionName=$sessionName","runnerName=$env:RUNNER_NAME")
$lines|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-interactive-preflight.txt') -Encoding UTF8
if($fail.Count){Write-Host ("FAILED: "+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'WINDOWS INTERACTIVE UI PREFLIGHT PASSED' -ForegroundColor Green
exit 0
