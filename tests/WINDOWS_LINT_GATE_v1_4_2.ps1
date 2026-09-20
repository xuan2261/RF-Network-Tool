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
$highSignalRules=@('PSAvoidAssignmentToAutomaticVariable','PSPossibleIncorrectComparisonWithNull')
$highSignal=@($all | Where-Object {$highSignalRules -contains $_.RuleName})
# Pinned PSScriptAnalyzer 1.25.0 warning/information debt baseline.
# Existing debt may decrease, but any new rule or per-rule increase fails CI.
$diagnosticBaseline=@{
  'PSAvoidUsingEmptyCatchBlock'=157
  'PSAvoidUsingPositionalParameters'=128
  'PSUseApprovedVerbs'=34
  'PSUseShouldProcessForStateChangingFunctions'=34
  'PSUseSingularNouns'=28
  'PSReviewUnusedParameter'=25
  'PSUseDeclaredVarsMoreThanAssignments'=6
  'PSAvoidUsingWriteHost'=4
}
$actualByRule=@{}
foreach($diag in @($all)){
  $rule=[string]$diag.RuleName
  if(-not $rule){continue}
  if(-not $actualByRule.ContainsKey($rule)){$actualByRule[$rule]=0}
  $actualByRule[$rule]=[int]$actualByRule[$rule]+1
}
$newDiagnosticRules=@($actualByRule.Keys | Where-Object {-not $diagnosticBaseline.ContainsKey($_)})
$baselineRegressions=New-Object System.Collections.Generic.List[string]
foreach($rule in $diagnosticBaseline.Keys){
  $current=if($actualByRule.ContainsKey($rule)){[int]$actualByRule[$rule]}else{0}
  $allowed=[int]$diagnosticBaseline[$rule]
  if($current -gt $allowed){[void]$baselineRegressions.Add(("$rule $current>$allowed"))}
}
$reportDir=Join-Path $root 'ci-artifacts';New-Item -ItemType Directory -Path $reportDir -Force|Out-Null
$all | Sort-Object ScriptName,Line,RuleName | Format-Table -AutoSize | Out-String -Width 240 | Set-Content -LiteralPath (Join-Path $reportDir 'PSScriptAnalyzer.txt') -Encoding UTF8
Write-Host ("PSScriptAnalyzer {0}: diagnostics={1}, gate-errors={2}, high-signal={3}, new-rules={4}, baseline-regressions={5}" -f $module.Version,@($all).Count,@($errors).Count,@($highSignal).Count,@($newDiagnosticRules).Count,@($baselineRegressions).Count)
if($errors){$errors|Format-Table -AutoSize|Out-Host;[void]$fail.Add('PSScriptAnalyzer errors')}
if($highSignal){$highSignal|Format-Table -AutoSize|Out-Host;[void]$fail.Add('PSScriptAnalyzer high-signal warnings')}
if($newDiagnosticRules.Count){Write-Host ("New PSScriptAnalyzer diagnostic rules: "+($newDiagnosticRules -join ', ')) -ForegroundColor Red;[void]$fail.Add('PSScriptAnalyzer new diagnostic rule')}
if($baselineRegressions.Count){Write-Host ("PSScriptAnalyzer diagnostic baseline regression: "+($baselineRegressions -join ', ')) -ForegroundColor Red;[void]$fail.Add('PSScriptAnalyzer diagnostic baseline regression')}
if($fail.Count){Write-Host ('FAILED: '+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL POWERSHELL PARSER/LINT GATES PASSED' -ForegroundColor Green
exit 0