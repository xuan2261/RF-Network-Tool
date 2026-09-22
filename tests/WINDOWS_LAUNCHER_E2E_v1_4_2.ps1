param([switch]$DiagnosticOnly,[switch]$AccessibilitySelfTest,[int]$TimeoutSec=15)
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$artifactDir=Join-Path $sourceRoot 'ci-artifacts';New-Item -ItemType Directory -Path $artifactDir -Force|Out-Null
$versionFile=Join-Path $sourceRoot 'VERSION'
if(-not(Test-Path -LiteralPath $versionFile)){throw 'VERSION is missing'}
$appVersion=([IO.File]::ReadAllText($versionFile)).Trim()
if($appVersion -notmatch '^\d+\.\d+\.\d+$'){throw "Invalid VERSION: $appVersion"}
$escapedVersion=[regex]::Escape($appVersion)
$fail=New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$c,[string]$n){if($c){Write-Host "PASS $n" -ForegroundColor Green}else{Write-Host "FAIL $n" -ForegroundColor Red;[void]$fail.Add($n)}}
function Normalize-UiName([string]$value){if($null -eq $value){return ''};return (($value -replace '&','' -replace '\s+',' ').Trim())}
function Initialize-MsaaInterop{
  Add-Type -AssemblyName Accessibility
  if(-not ('RftMsaaBridge' -as [type])){
    Add-Type -ReferencedAssemblies @('Accessibility.dll') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Accessibility;
public static class RftMsaaBridge {
    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(
        IntPtr hwnd, uint objectId, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out object accessible);

    [DllImport("oleacc.dll")]
    private static extern int AccessibleChildren(
        IAccessible paccContainer, int iChildStart, int cChildren,
        [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2), In, Out] object[] children,
        out int obtained);

    private static IAccessible GetClientAccessible(IntPtr hwnd) {
        Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        object value;
        int hr = AccessibleObjectFromWindow(hwnd, 0xFFFFFFFCu, ref iid, out value);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        IAccessible accessible = value as IAccessible;
        if (accessible == null) throw new InvalidOperationException("AccessibleObjectFromWindow did not return IAccessible.");
        return accessible;
    }

    private static object[] GetChildren(IAccessible parent) {
        int count = parent.accChildCount;
        if (count <= 0) return new object[0];
        object[] children = new object[count];
        int obtained;
        int hr = AccessibleChildren(parent, 0, count, children, out obtained);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        if (obtained == count) return children;
        object[] trimmed = new object[Math.Max(0, obtained)];
        if (obtained > 0) Array.Copy(children, trimmed, obtained);
        return trimmed;
    }

    private static string ChildName(IAccessible parent, object child) {
        try {
            IAccessible childAccessible = child as IAccessible;
            if (childAccessible != null) return childAccessible.get_accName(0) ?? String.Empty;
            int childId = Convert.ToInt32(child);
            return parent.get_accName(childId) ?? String.Empty;
        } catch {
            return String.Empty;
        }
    }

    public static string[] GetChildNames(IntPtr hwnd) {
        IAccessible parent = GetClientAccessible(hwnd);
        List<string> names = new List<string>();
        foreach (object child in GetChildren(parent)) {
            string name = ChildName(parent, child);
            if (!String.IsNullOrWhiteSpace(name)) names.Add(name);
        }
        return names.ToArray();
    }

    public static bool InvokeChildByName(IntPtr hwnd, string desiredName) {
        const int SELFLAG_TAKESELECTION = 0x2;
        IAccessible parent = GetClientAccessible(hwnd);
        foreach (object child in GetChildren(parent)) {
            string name = ChildName(parent, child);
            if (!String.Equals(name, desiredName, StringComparison.OrdinalIgnoreCase)) continue;
            IAccessible childAccessible = child as IAccessible;
            if (childAccessible != null) {
                try { childAccessible.accDoDefaultAction(0); } catch { }
                try { childAccessible.accSelect(SELFLAG_TAKESELECTION, 0); } catch { }
            } else {
                int childId = Convert.ToInt32(child);
                try { parent.accDoDefaultAction(childId); } catch { }
                try { parent.accSelect(SELFLAG_TAKESELECTION, childId); } catch { }
            }
            return true;
        }
        return false;
    }
}
'@
  }
}
function Get-MsaaTabModel([IntPtr]$handle){
  if($handle -eq [IntPtr]::Zero){return $null}
  Initialize-MsaaInterop
  $children=New-Object System.Collections.Generic.List[object]
  foreach($rawName in @([RftMsaaBridge]::GetChildNames($handle))){
    $name=Normalize-UiName ([string]$rawName)
    if($name -and -not @($children|Where-Object {$_.Name -eq $name}).Count){
      [void]$children.Add([pscustomobject]@{Name=$name})
    }
  }
  return [pscustomobject]@{Handle=$handle;Children=@($children.ToArray())}
}
function Get-VisibleExpectedPaneNames([object]$rootElement,[string[]]$expectedTabs){
  $found=New-Object System.Collections.Generic.List[string]
  $paneCond=New-Object System.Windows.Automation.PropertyCondition -ArgumentList @([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Pane)
  $panes=$rootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,$paneCond)
  foreach($pane in $panes){
    $paneName=try{Normalize-UiName ([string]$pane.Current.Name)}catch{''}
    $paneOffscreen=try{[bool]$pane.Current.IsOffscreen}catch{$true}
    if($paneName -and -not $paneOffscreen -and $paneName -in $expectedTabs -and -not $found.Contains($paneName)){[void]$found.Add($paneName)}
  }
  return @($found.ToArray())
}
function Invoke-MsaaTabSelfTest{
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $expected=@('PING','RF / RJ45','NETWORK SCAN','MONITORING','HƯỚNG DẪN')
  $form=New-Object System.Windows.Forms.Form
  $tabs=New-Object System.Windows.Forms.TabControl
  $form.ShowInTaskbar=$false
  $form.StartPosition=[System.Windows.Forms.FormStartPosition]::Manual
  $form.Location=New-Object System.Drawing.Point -ArgumentList @(-30000,-30000)
  $tabs.Dock=[System.Windows.Forms.DockStyle]::Fill
  foreach($label in $expected){[void]$tabs.TabPages.Add((New-Object System.Windows.Forms.TabPage -ArgumentList $label))}
  [void]$form.Controls.Add($tabs)
  $model=$null
  try{
    $form.Show();[System.Windows.Forms.Application]::DoEvents()
    $model=Get-MsaaTabModel ([IntPtr]$tabs.Handle)
    Assert-True ($null -ne $model) 'MSAA tab self-test obtains IAccessible'
    $names=@();if($model){$names=@($model.Children|ForEach-Object {$_.Name})}
    foreach($label in $expected){Assert-True ($names -contains (Normalize-UiName $label)) ("MSAA tab self-test name: "+$label)}
    if($model -and $model.Children.Count -ge 2){
      $invoked=[RftMsaaBridge]::InvokeChildByName([IntPtr]$tabs.Handle,[string]$expected[1])
      [System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100
      Assert-True ($invoked -and $tabs.SelectedIndex -eq 1) 'MSAA accDoDefaultAction switches page tab'
    }else{Assert-True $false 'MSAA accDoDefaultAction switches page tab'}
  }finally{
    try{$form.Close()}catch{};try{$form.Dispose()}catch{}
  }
  if($fail.Count){Write-Host ('FAILED: '+($fail -join ', ')) -ForegroundColor Red;exit 1}
  Write-Host 'MSAA TAB ACCESSIBILITY SELF-TEST PASSED' -ForegroundColor Green
  exit 0
}
if($AccessibilitySelfTest){Invoke-MsaaTabSelfTest}
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
          $expectedLabels=@('PING','RF / RJ45','NETWORK SCAN','MONITORING','HƯỚNG DẪN')
          $expectedTabs=@($expectedLabels|ForEach-Object {Normalize-UiName $_})
          $cond=New-Object System.Windows.Automation.PropertyCondition -ArgumentList @([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::TabItem)
          $tabWait=[Diagnostics.Stopwatch]::StartNew();$items=$null
          while($tabWait.Elapsed.TotalSeconds -lt [Math]::Max(5,$TimeoutSec)){
            $items=$rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants,$cond)
            if($items.Count -ge 5){break}
            Start-Sleep -Milliseconds 200
          }
          $names=New-Object System.Collections.Generic.List[string]
          foreach($x in $items){$n=Normalize-UiName ([string]$x.Current.Name);if($n -and -not $names.Contains($n)){[void]$names.Add($n)}}
          $tabProvider='UIAutomation.TabItem'
          $navigationExercised=$false
          if($items.Count -ge 5){
            foreach($x in $items){
              $normalizedName=Normalize-UiName ([string]$x.Current.Name)
              if($normalizedName -in $expectedTabs){
                try{$pat=$x.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern);$pat.Select();Start-Sleep -Milliseconds 150}
                catch{Write-Host ("Tab automation failed: "+$normalizedName+" :: "+$_.Exception.Message);[void]$fail.Add("Tab selectable: $normalizedName")}
              }
            }
            $navigationExercised=$true
          }else{
            $msaaSucceeded=$false;$msaaModel=$null
            try{
              $allNative=$rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
              $nativeTab=$null
              foreach($candidate in $allNative){
                $cls=try{[string]$candidate.Current.ClassName}catch{''}
                $hwnd=try{[int]$candidate.Current.NativeWindowHandle}catch{0}
                if($hwnd -ne 0 -and $cls -like '*SysTabControl32*'){$nativeTab=$candidate;break}
              }
              if($null -ne $nativeTab){
                $msaaModel=Get-MsaaTabModel ([IntPtr][int]$nativeTab.Current.NativeWindowHandle)
                $msaaNames=@();if($msaaModel){$msaaNames=@($msaaModel.Children|ForEach-Object {$_.Name})}
                $missingMsaa=@($expectedTabs|Where-Object {$_ -notin $msaaNames})
                if($msaaModel -and $missingMsaa.Count -eq 0){
                  $visited=New-Object System.Collections.Generic.List[string]
                  foreach($expectedTab in $expectedTabs){
                    $child=$msaaModel.Children|Where-Object {$_.Name -eq $expectedTab}|Select-Object -First 1
                    if($child -and [RftMsaaBridge]::InvokeChildByName([IntPtr]$msaaModel.Handle,[string]$expectedTab)){
                      Start-Sleep -Milliseconds 200
                      foreach($visibleName in @(Get-VisibleExpectedPaneNames $rootEl $expectedTabs)){
                        if(-not $visited.Contains($visibleName)){[void]$visited.Add($visibleName)}
                      }
                    }
                  }
                  foreach($n in $msaaNames){if(-not $names.Contains($n)){[void]$names.Add($n)}}
                  $navigationExercised=($visited.Count -ge $expectedTabs.Count)
                  if($navigationExercised){$tabProvider='MSAA.SysTabControl32';$msaaSucceeded=$true}
                }
              }
            }catch{Write-Host ("MSAA tab fallback unavailable: "+$_.Exception.Message)}
            if(-not $msaaSucceeded){
              $tabProvider='CtrlTab+UIAutomation.Pane fallback'
              try{
                Add-Type -AssemblyName System.Windows.Forms
                Add-Type -AssemblyName Microsoft.VisualBasic
                try{[Microsoft.VisualBasic.Interaction]::AppActivate([int]$p.Id)}catch{}
                try{$rootEl.SetFocus()}catch{}
                Start-Sleep -Milliseconds 200
                $fallbackNames=New-Object System.Collections.Generic.List[string]
                for($cycle=0;$cycle -lt 5;$cycle++){
                  foreach($paneName in @(Get-VisibleExpectedPaneNames $rootEl $expectedTabs)){
                    if(-not $fallbackNames.Contains($paneName)){[void]$fallbackNames.Add($paneName)}
                  }
                  if($cycle -lt 4){[System.Windows.Forms.SendKeys]::SendWait('^{TAB}');Start-Sleep -Milliseconds 300}
                }
                foreach($n in $fallbackNames){if(-not $names.Contains($n)){[void]$names.Add($n)}}
                $navigationExercised=($fallbackNames.Count -ge $expectedTabs.Count)
              }catch{
                Write-Host ("Tab fallback failed: "+$_.Exception.Message)
                [void]$fail.Add('Tab keyboard fallback')
              }
            }
          }
          $names.ToArray()|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-tab-items.txt') -Encoding UTF8
          $tabProvider|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-tab-provider.txt') -Encoding UTF8
          if($names.Count -lt 5){
            try{
              $all=$rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
              $dump=New-Object System.Collections.Generic.List[string]
              foreach($el in $all){
                if($dump.Count -ge 400){break}
                $type=try{[string]$el.Current.ControlType.ProgrammaticName}catch{''}
                $name=try{Normalize-UiName ([string]$el.Current.Name)}catch{''}
                $aid=try{[string]$el.Current.AutomationId}catch{''}
                $cls=try{[string]$el.Current.ClassName}catch{''}
                [void]$dump.Add(("type={0}	name={1}	automationId={2}	class={3}" -f $type,$name,$aid,$cls))
              }
              $dump.ToArray()|Set-Content -LiteralPath (Join-Path $artifactDir 'ui-tree-dump.txt') -Encoding UTF8
            }catch{}
          }
          foreach($expected in $expectedLabels){
            $normalizedExpected=Normalize-UiName $expected
            Assert-True ($names.Contains($normalizedExpected)) "Tab present: $expected"
          }
          Assert-True ($navigationExercised -and -not $p.HasExited) 'GUI survives tab navigation'
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