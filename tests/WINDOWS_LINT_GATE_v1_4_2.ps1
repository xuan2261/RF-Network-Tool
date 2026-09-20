param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$runtime=@(
  'RF-Network-Tool-Launcher.ps1','RF-Network-Tool-Portable.ps1','RF-Network-Tool-DiscoveryWorker.ps1',
  'RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1'
)
$fail=New-Object System.Collections.Generic.List[string]
foreach($name in $runtime){
  $path=Join-Path $root $name
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
  if($errors){foreach($e in $errors){Write-Host ("PARSE {0}:{1}:{2} {3}" -f $name,$e.Extent.StartLineNumber,$e.Extent.StartColumnNumber,$e.Message) -ForegroundColor Red};[void]$fail.Add("Parser $name")}
}
$module=Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if(-not $module){throw 'PSScriptAnalyzer is required for this CI gate.'}
Import-Module $module.Path -Force
$all=@()
foreach($name in $runtime){$all += @(Invoke-ScriptAnalyzer -Path (Join-Path $root $name) -Recurse:$false)}
$errors=@($all | Where-Object {$_.Severity -eq 'Error' -or $_.RuleName -eq 'ParseError'})
$reportDir=Join-Path $root 'ci-artifacts';New-Item -ItemType Directory -Path $reportDir -Force|Out-Null
$all | Sort-Object ScriptName,Line,RuleName | Format-Table -AutoSize | Out-String -Width 240 | Set-Content -LiteralPath (Join-Path $reportDir 'PSScriptAnalyzer.txt') -Encoding UTF8
Write-Host ("PSScriptAnalyzer {0}: diagnostics={1}, gate-errors={2}" -f $module.Version,@($all).Count,@($errors).Count)
if($errors){$errors|Format-Table -AutoSize|Out-Host;[void]$fail.Add('PSScriptAnalyzer errors')}
if($fail.Count){Write-Host ('FAILED: '+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL POWERSHELL PARSER/LINT GATES PASSED' -ForegroundColor Green
exit 0