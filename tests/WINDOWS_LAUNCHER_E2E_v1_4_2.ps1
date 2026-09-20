param([switch]$DiagnosticOnly,[int]$TimeoutSec=15)
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$artifactDir=Join-Path $sourceRoot 'ci-artifacts';New-Item -ItemType Directory -Path $artifactDir -Force|Out-Null
$versionFile=Join-Path $sourceRoot 'VERSION';if(-not(Test-Path $versionFile)){throw 'VERSION is missing'};$appVersion=([IO.File]::ReadAllText($versionFile)).Trim();if($appVersion -notmatch '^\d+\.\d+\.\d+$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$c,[string]$n){if($c){Write-Host "PASS $n" -ForegroundColor Green}else{Write-Host "FAIL $n" -ForegroundColor Red;[void]$fail.Add($n)}}
function Normalize-UiName([string]$value){if($null -eq $value){return ''};return (($value -replace '&','' -replace '\s+',' ').Trim())}
function Invoke-Captured([string]$exe,[string]$argumentString,[int]$timeoutMs=20000){
  $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$exe;$psi.Arguments=$argumentString;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();if(-not $p.WaitForExit($timeoutMs)){try{$p.Kill()}catch{};throw "Process timeout: $exe $argumentString"};$o=$p.StandardOutput.ReadToEnd();$e=$p.StandardError.ReadToEnd();$rc=$p.ExitCode;$p.Dispose();return [pscustomobject]@{ExitCode=$rc;Out=$o;Err=$e}
}
$runtime=@('START-RF-NETWORK-TOOL.vbs','RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd','RF-Network-Tool-Launcher.ps1','RF-Network-Tool-Portable.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-DiscoveryWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1','README.txt','VERSION')
$sandbox=Join-Path $env:TEMP ('RFT-versioned-e2e-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $sandbox -Force|Out-Null
foreach($name in $runtime){Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $sandbox $name) -Force}
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher=Join-Path $sandbox 'RF-Network-Tool-Launcher.ps1'
try {
  $d=Invoke-Captured $psExe ("-STA -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -Diagnostic")
  Assert-True ($d.ExitCode -eq 0) 'Launcher diagnostic exit 0'
  Assert-True ($d.Out -match 'PASS: PowerShell/STA/WinForms') 'Launcher diagnostic confirms WinForms/parser gate'
  ($d.Out+"`r`n"+$d.Err)|Set-Content -LiteralPath (Join-Path $artifactDir 'launcher-diagnostic.txt') -Encoding UTF8
  if(-not $DiagnosticOnly){
    Assert-True ([Environment]::UserInteractive) 'Interactive desktop available'
    if([Environment]::UserInteractive){
      Add-Type -AssemblyName UIAutomationClient
      Add-Type -AssemblyName UIAutomationTypes
      $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$psExe;$psi.Arguments="-STA -NoProfile -ExecutionPolicy Bypass -File `"$launcher`"";$psi.UseShellExecute=$false
      $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
      try{
        # PowerShell.exe can expose a host/console handle as MainWindowHandle. Discover the actual
        # top-level WinForms window by UIAutomation ProcessId + title instead.
        $desktop=[System.Windows.Automation.AutomationElement]::RootElement
        $windowCond=New-Object System.Windows.Automation.PropertyCondition -ArgumentList @([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Window)
        $sw=[Diagnostics.Stopwatch]::StartNew();$rootEl=$null;$observed=New-Object System.Collections.Generic.List[string]
        while($sw.Elapsed.TotalSeconds -lt $TimeoutSec -and -not $p.HasExited -and $null -eq $rootEl){
          $windows=$desktop.FindAll([System.Windows.Automation.TreeScope]::Children,$windowCond)
          foreach($candidate in $windows){
            if([int]$candidate.Current.ProcessId -ne [int]$p.Id){continue}
            $windowName=[string]$candidate.Current.Name
            if($windowName -and -not $observed.Contains($windowName)){[void]$observed.Add($windowName)}
            $normalizedWindowName=Normalize-UiName $windowName
            if($normalizedWindowName -match ('^RF Network Diagnostic Tool - Portable v'+$escapedVersion)){ $rootEl=$candidate;break }
          }
          if($null -eq $rootEl){Start-Sleep -Milliseconds 150}
        }
        $observed.ToArray()|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-top-level-windows.txt') -Encoding UTF8
        Assert-True ($null -ne $rootEl) 'Main WinForms window discovered via UIAutomation'
        if($null -ne $rootEl){
          $normalizedRootName=Normalize-UiName ([string]$rootEl.Current.Name)
          Assert-True ($normalizedRootName -match ('^RF Network Diagnostic Tool - Portable v'+$escapedVersion)) 'Window title/version'
          $cond=New-Object System.Windows.Automation.PropertyCondition -ArgumentList @([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::TabItem)
          $items=$rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants,$cond)
          $names=@();foreach($x in $items){$names += [string]$x.Current.Name}
          $names|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-tab-items.txt') -Encoding UTF8
          foreach($expected in @('PING','RF / RJ45','NETWORK SCAN','MONITORING','HƯỚNG DẪN')){Assert-True ($names -contains $expected) "Tab present: $expected"}
          foreach($x in $items){if($x.Current.Name -in @('PING','NETWORK SCAN','MONITORING','HƯỚNG DẪN')){try{$pat=$x.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern);$pat.Select();Start-Sleep -Milliseconds 100}catch{Write-Host ("Tab automation failed: "+$x.Current.Name+" :: "+$_.Exception.Message);[void]$fail.Add("Tab selectable: $($x.Current.Name)")}}}
          Assert-True (-not $p.HasExited) 'GUI survives tab navigation'
        }
      } finally {
        if(-not $p.HasExited){
          $closed=$false
          if($null -ne $rootEl){
            try{$wp=$rootEl.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern);$wp.Close();$closed=$true}catch{}
          }
          if(-not $closed){try{[void]$p.CloseMainWindow()}catch{}}
          if(-not $p.WaitForExit(5000)){try{$p.Kill()}catch{};[void]$fail.Add('Graceful GUI shutdown')}
        }
        try{$p.Dispose()}catch{}
      }
    }
  }
  $logs=Join-Path $sandbox 'logs';$latest=Get-ChildItem -LiteralPath $logs -Filter 'startup-*.log' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
  if($latest){$txt=[IO.File]::ReadAllText($latest.FullName);Assert-True ($txt -notmatch 'FATAL:|PARSE ERROR') 'Startup log has no fatal/parser error';Copy-Item $latest.FullName (Join-Path $artifactDir 'startup-e2e.log') -Force}
  if($fail.Count){Write-Host ('FAILED: '+($fail -join ', ')) -ForegroundColor Red;exit 1}
  Write-Host $(if($DiagnosticOnly){'DIAGNOSTIC E2E PASSED'}else{'ALL WINDOWS GUI E2E SMOKE TESTS PASSED'}) -ForegroundColor Green
  exit 0
} finally {
  Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}){throw "Invalid VERSION: $appVersion"};$escapedVersion=[regex]::Escape($appVersion)
$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$c,[string]$n){if($c){Write-Host "PASS $n" -ForegroundColor Green}else{Write-Host "FAIL $n" -ForegroundColor Red;[void]$fail.Add($n)}}
function Normalize-UiName([string]$value){if($null -eq $value){return ''};return (($value -replace '&','' -replace '\s+',' ').Trim())}
function Invoke-Captured([string]$exe,[string]$argumentString,[int]$timeoutMs=20000){
  $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$exe;$psi.Arguments=$argumentString;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();if(-not $p.WaitForExit($timeoutMs)){try{$p.Kill()}catch{};throw "Process timeout: $exe $argumentString"};$o=$p.StandardOutput.ReadToEnd();$e=$p.StandardError.ReadToEnd();$rc=$p.ExitCode;$p.Dispose();return [pscustomobject]@{ExitCode=$rc;Out=$o;Err=$e}
}
$runtime=@('START-RF-NETWORK-TOOL.vbs','RUN-PORTABLE.cmd','RUN-DIAGNOSTIC.cmd','RF-Network-Tool-Launcher.ps1','RF-Network-Tool-Portable.ps1','RF-Network-Tool-ScanWorker.ps1','RF-Network-Tool-DiscoveryWorker.ps1','RF-Network-Tool-PingWorker.ps1','RF-Network-Tool-TaskWorker.ps1','README.txt')
$sandbox=Join-Path $env:TEMP ('RFT-v142-e2e-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $sandbox -Force|Out-Null
foreach($name in $runtime){Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $sandbox $name) -Force}
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher=Join-Path $sandbox 'RF-Network-Tool-Launcher.ps1'
try {
  $d=Invoke-Captured $psExe ("-STA -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -Diagnostic")
  Assert-True ($d.ExitCode -eq 0) 'Launcher diagnostic exit 0'
  Assert-True ($d.Out -match 'PASS: PowerShell/STA/WinForms') 'Launcher diagnostic confirms WinForms/parser gate'
  ($d.Out+"`r`n"+$d.Err)|Set-Content -LiteralPath (Join-Path $artifactDir 'launcher-diagnostic.txt') -Encoding UTF8
  if(-not $DiagnosticOnly){
    Assert-True ([Environment]::UserInteractive) 'Interactive desktop available'
    if([Environment]::UserInteractive){
      Add-Type -AssemblyName UIAutomationClient
      Add-Type -AssemblyName UIAutomationTypes
      $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$psExe;$psi.Arguments="-STA -NoProfile -ExecutionPolicy Bypass -File `"$launcher`"";$psi.UseShellExecute=$false
      $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
      try{
        # PowerShell.exe can expose a host/console handle as MainWindowHandle. Discover the actual
        # top-level WinForms window by UIAutomation ProcessId + title instead.
        $desktop=[System.Windows.Automation.AutomationElement]::RootElement
        $windowCond=New-Object System.Windows.Automation.PropertyCondition -ArgumentList @([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Window)
        $sw=[Diagnostics.Stopwatch]::StartNew();$rootEl=$null;$observed=New-Object System.Collections.Generic.List[string]
        while($sw.Elapsed.TotalSeconds -lt $TimeoutSec -and -not $p.HasExited -and $null -eq $rootEl){
          $windows=$desktop.FindAll([System.Windows.Automation.TreeScope]::Children,$windowCond)
          foreach($candidate in $windows){
            if([int]$candidate.Current.ProcessId -ne [int]$p.Id){continue}
            $windowName=[string]$candidate.Current.Name
            if($windowName -and -not $observed.Contains($windowName)){[void]$observed.Add($windowName)}
            $normalizedWindowName=Normalize-UiName $windowName
            if($normalizedWindowName -match ('^RF Network Diagnostic Tool - Portable v'+$escapedVersion)){ $rootEl=$candidate;break }
          }
          if($null -eq $rootEl){Start-Sleep -Milliseconds 150}
        }
        $observed.ToArray()|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-top-level-windows.txt') -Encoding UTF8
        Assert-True ($null -ne $rootEl) 'Main WinForms window discovered via UIAutomation'
        if($null -ne $rootEl){
          $normalizedRootName=Normalize-UiName ([string]$rootEl.Current.Name)
          Assert-True ($normalizedRootName -match ('^RF Network Diagnostic Tool - Portable v'+$escapedVersion)) 'Window title/version'
          $cond=New-Object System.Windows.Automation.PropertyCondition -ArgumentList @([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::TabItem)
          $items=$rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants,$cond)
          $names=@();foreach($x in $items){$names += [string]$x.Current.Name}
          $names|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-tab-items.txt') -Encoding UTF8
          foreach($expected in @('PING','RF / RJ45','NETWORK SCAN','MONITORING','HƯỚNG DẪN')){Assert-True ($names -contains $expected) "Tab present: $expected"}
          foreach($x in $items){if($x.Current.Name -in @('PING','NETWORK SCAN','MONITORING','HƯỚNG DẪN')){try{$pat=$x.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern);$pat.Select();Start-Sleep -Milliseconds 100}catch{Write-Host ("Tab automation failed: "+$x.Current.Name+" :: "+$_.Exception.Message);[void]$fail.Add("Tab selectable: $($x.Current.Name)")}}}
          Assert-True (-not $p.HasExited) 'GUI survives tab navigation'
        }
      } finally {
        if(-not $p.HasExited){
          $closed=$false
          if($null -ne $rootEl){
            try{$wp=$rootEl.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern);$wp.Close();$closed=$true}catch{}
          }
          if(-not $closed){try{[void]$p.CloseMainWindow()}catch{}}
          if(-not $p.WaitForExit(5000)){try{$p.Kill()}catch{};[void]$fail.Add('Graceful GUI shutdown')}
        }
        try{$p.Dispose()}catch{}
      }
    }
  }
  $logs=Join-Path $sandbox 'logs';$latest=Get-ChildItem -LiteralPath $logs -Filter 'startup-*.log' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
  if($latest){$txt=[IO.File]::ReadAllText($latest.FullName);Assert-True ($txt -notmatch 'FATAL:|PARSE ERROR') 'Startup log has no fatal/parser error';Copy-Item $latest.FullName (Join-Path $artifactDir 'startup-e2e.log') -Force}
  if($fail.Count){Write-Host ('FAILED: '+($fail -join ', ')) -ForegroundColor Red;exit 1}
  Write-Host $(if($DiagnosticOnly){'DIAGNOSTIC E2E PASSED'}else{'ALL WINDOWS GUI E2E SMOKE TESTS PASSED'}) -ForegroundColor Green
  exit 0
} finally {
  Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}