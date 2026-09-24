[CmdletBinding()]
param([string]$Root='', [switch]$BaselineRed)
$ErrorActionPreference='Stop'
if(-not $Root){$Root=Split-Path -Parent $PSScriptRoot}
$artifact=Join-Path $Root 'ci-artifacts'
[void](New-Item -ItemType Directory -Path $artifact -Force)
$checks=New-Object System.Collections.Generic.List[object]
$exitCode=1;$testForm=$null;$fonts=New-Object System.Collections.Generic.List[object]
function Check([string]$name,[bool]$ok){
    [void]$checks.Add([pscustomobject]@{name=$name;pass=$ok})
    Write-Host ((@('FAIL','PASS')[[int]$ok])+' '+$name)
}
# Logging, persistence and target-grid side effects are outside these accounting unit tests.
function Write-RuntimeLog {param($area,$message)}
function Save-MonitoringHistory {}
function Refresh-MonitorTimelineGrid {}
function Get-TargetGridRow {param($target) return $null}
function Get-MonitorClock {return $script:clock}
function Update-MonitorGridRow {param($target)}
function Refresh-MonitorGrid {}
function Add-MonitoringEvent {param($target,$name,$fromState,$toState,$latencyMs,$detail,$observedAt)}
function Fresh {
    $script:MonitoringStats=@{};$script:MonitoringConfig=@{};$script:TargetRows=@{}
    $script:PingTargetBusy=@{};$script:PingLatestRequest=@{};$script:PingRequests=@{}
    $script:MonitoringEpoch=[guid]::NewGuid().ToString('N')
    $script:MonitoringEvents=New-Object System.Collections.Generic.List[object];$script:MonitoringMaxEvents=500
    $script:MonitoringSessionStartedAt=[datetime]'2026-01-01T00:00:00'
    $script:clock=[pscustomobject]@{At=[datetime]'2026-01-01T00:00:00';Mono=100.0}
    foreach($target in @('192.0.2.1','192.0.2.2','192.0.2.3')){
        $script:MonitoringConfig[$target]=[pscustomobject]@{Target=$target;Name=$target;Enabled=$true;IntervalSec=5;Alert=$false}
        $script:MonitoringStats[$target]=New-MonitorStat -target $target -name $target
    }
}
function Tick([double]$seconds=5){$script:clock.Mono+=$seconds;$script:clock.At=$script:clock.At.AddSeconds($seconds)}
function Sample([bool]$ok,[object]$ms=0,[string]$status='', [string]$target='192.0.2.1'){
    if(-not $status){$status=if($ok){'ONLINE'}else{'OFFLINE'}}
    Apply-MonitorPingResult ([pscustomobject]@{Target=$target;Success=$ok;Status=$status;Time=$ms;Detail=if($status -eq 'ERROR'){'local exception'}elseif($ok){'Success'}else{'TimedOut'};TTL=64;ObservedAt=$script:clock.At.ToString('o');ObservedMono=$script:clock.Mono})
}
try {
    Check 'runtime_windows_ps51' ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5)
    $tokens=$null;$errors=$null
    $script:mainAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'RF-Network-Tool-Portable.ps1'),[ref]$tokens,[ref]$errors)
    Check 'main_parser' (-not $errors)
    if($errors){throw ($errors|Out-String)}
    # Extract complete function definitions to preserve parameters; dot-source in this script's scope.
    $names=@('New-MonitorStat','Format-MonitorDuration','Get-MonitorLossPercent','Get-MonitorAverageMs','Apply-MonitorPingResult')
    if(-not $BaselineRed){$names+=@('Get-MonitorInterval','Get-MonitorHealth','Add-MonitorElapsed','Set-MonitorMeasurementError','Get-MonitorRequestStamp','Test-MonitorRequest','Get-MonitorDisplayedUptime','Get-MonitorDisplayedDowntime','Set-MonitorEnabledState','Reset-MonitorStats','Finalize-PingRequest','Fail-PendingPingRequests','Set-PingTargetEngineError','Get-DiscoveryTerminalOutcome','Initialize-MonitorColumn','Get-MonitorGridRow','Refresh-MonitorSummary','Invoke-MonitorScheduler')}
    foreach($name in $names){
        $nodes=@($script:mainAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object {$_.Name -eq $name})
        if($nodes.Count -ne 1){throw "Missing production function $name"}
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    Fresh
    Check 'duration_36h' ((Format-MonitorDuration 129600) -eq '1d 12:00:00')
    Sample $true 10;Tick;Sample $false '-' 'ERROR'
    $st=$script:MonitoringStats['192.0.2.1']
    Check 'measurement_error_not_network_loss' ($st.TotalCount -eq 1 -and $st.FailureCount -eq 0 -and $st.OutageCount -eq 0 -and $st.State -eq 'ONLINE')
    if(-not $BaselineRed){
        Check 'engine_health_separate' ((Get-MonitorHealth $st $script:MonitoringConfig['192.0.2.1']) -eq 'ENGINE ERROR' -and $st.MeasurementErrorCount -eq 1)
        $frozen=Get-MonitorDisplayedUptime $st;Tick 100
        Check 'engine_error_freezes_clock' ((Get-MonitorDisplayedUptime $st) -eq $frozen)
        Fresh;Sample $true 10;Tick;Sample $true 20;Tick;Sample $false;Tick;Sample $true 30
        $st=$script:MonitoringStats['192.0.2.1']
        Check 'sequence_exact_math' ($st.TotalCount -eq 4 -and $st.SuccessCount -eq 3 -and $st.MinMs -eq 10 -and $st.MaxMs -eq 30 -and (Get-MonitorAverageMs $st) -eq 20 -and (Get-MonitorLossPercent $st) -eq 25 -and $st.OutageCount -eq 1)
        Check 'sequence_accounting' ($st.UptimeSec -eq 10 -and $st.DowntimeSec -eq 5)
        $accounted=$st.AccountingMono;$storedUp=$st.UptimeSec;Tick 2
        [void](Get-MonitorDisplayedUptime $st);[void](Get-MonitorDisplayedDowntime $st)
        Check 'display_projection_does_not_mutate_accounting' ($st.AccountingMono -eq $accounted -and $st.UptimeSec -eq $storedUp)
        Fresh;Sample $true 0;Sample $true 77 '' '192.0.2.2';Sample $true 9 '' '192.0.2.3'
        Check 'zero_and_target_isolation' ($script:MonitoringStats['192.0.2.1'].SumMs -eq 0 -and $script:MonitoringStats['192.0.2.2'].SumMs -eq 77 -and $script:MonitoringStats['192.0.2.3'].TotalCount -eq 1)
        $st=$script:MonitoringStats['192.0.2.1'];Tick 5;$script:clock.At=$script:clock.At.AddDays(-3)
        Check 'clock_jump_not_duration' ((Get-MonitorDisplayedUptime $st) -eq 5)
        Tick 100
        Check 'stale_health' ((Get-MonitorHealth $st $script:MonitoringConfig['192.0.2.1']) -eq 'STALE')
        Check 'stale_time_bounded' ((Get-MonitorDisplayedUptime $st) -le 16.2001)
        Fresh;Sample $true 1;Tick 2;Set-MonitorEnabledState '192.0.2.1' $false
        $st=$script:MonitoringStats['192.0.2.1'];$paused=Get-MonitorDisplayedUptime $st;Tick 60
        Check 'pause_freezes_and_preserves_last_sample' ((Get-MonitorDisplayedUptime $st) -eq $paused -and $null -ne $st.LastResultAt -and (Get-MonitorHealth $st $script:MonitoringConfig['192.0.2.1']) -eq 'PAUSED')
        Set-MonitorEnabledState '192.0.2.1' $true;Sample $true 2
        Check 'resume_excludes_pause' ($st.UptimeSec -eq $paused)
        Fresh;$targets=@([pscustomobject]@{Target='192.0.2.1'})
        $meta=[pscustomobject]@{Kind='MONITOR';Targets=$targets;MonitorStamp=(Get-MonitorRequestStamp $targets)}
        Check 'current_request_accepted' (Test-MonitorRequest $meta '192.0.2.1')
        Reset-MonitorStats
        Check 'reset_epoch_rejects_old' (-not (Test-MonitorRequest $meta '192.0.2.1'))
        $script:PingTargetBusy['192.0.2.1']='old';$script:PingLatestRequest['192.0.2.1']='old';$script:PingRequests['old']=$meta
        [void](Finalize-PingRequest -requestId 'old' -meta $meta -kind 'MONITOR' -completedTargets @{} -workerError 'old failure')
        Check 'old_missing_result_does_not_poison_new_epoch' ($script:MonitoringStats['192.0.2.1'].MeasurementErrorCount -eq 0)
        $meta.MonitorStamp=Get-MonitorRequestStamp $targets
        Set-MonitorEnabledState '192.0.2.1' $false;Set-MonitorEnabledState '192.0.2.1' $true
        Check 'pause_resume_rejects_old_generation' (-not (Test-MonitorRequest $meta '192.0.2.1'))
        Fresh;Sample $true 5;Tick
        $meta=[pscustomobject]@{Kind='MONITOR';Targets=$targets;MonitorStamp=(Get-MonitorRequestStamp $targets)};$script:PingRequests['current']=$meta
        Fail-PendingPingRequests 'stopped'
        Check 'worker_stop_health' ((Get-MonitorHealth $script:MonitoringStats['192.0.2.1'] $script:MonitoringConfig['192.0.2.1']) -eq 'ENGINE ERROR')
        foreach($case in @(@(86399,'23:59:59'),@(86400,'1d 00:00:00'),@(126000,'1d 11:00:00'),@(129600,'1d 12:00:00'),@(169200,'1d 23:00:00'),@(172800,'2d 00:00:00'),@(216000,'2d 12:00:00'))){Check ('duration_'+$case[0]) ((Format-MonitorDuration $case[0]) -eq $case[1])}
        Fresh;Sample $true 12
        $st=$script:MonitoringStats['192.0.2.1'];$count=$st.TotalCount
        Sample $true 90
        Check 'duplicate_timestamp_not_counted' ($st.TotalCount -eq $count)
        Tick;Sample $true ([double]::NaN)
        Check 'invalid_sample_not_counted' ($st.TotalCount -eq $count -and $st.MeasurementErrorCount -eq 1)
        $priorCulture=[Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach($culture in @('en-US','fr-FR','vi-VN')){
                [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
                Fresh;Tick 0.25;Sample $true 1.5;Tick 5;Sample $true 2.5
                $st=$script:MonitoringStats['192.0.2.1']
                Check ('invariant_observation_'+$culture) ($st.SuccessCount -eq 2 -and $st.SumMs -eq 4 -and $st.LastSampleMono -eq 105.25 -and $st.MeasurementErrorCount -eq 0)
            }
        } finally {[Threading.Thread]::CurrentThread.CurrentCulture=$priorCulture}
        Fresh;Sample $true 4;Tick
        Set-MonitorMeasurementError -target '192.0.2.1' -message 'not applied' -WhatIf
        Check 'measurement_error_whatif_no_mutation' ($script:MonitoringStats['192.0.2.1'].MeasurementErrorCount -eq 0 -and $script:MonitoringStats['192.0.2.1'].CollectorHealth -eq 'OK')
        $ok=[pscustomobject]@{schemaVersion=1;sessionId='s';runId='r';status='SUCCESS';completedWindow=$true;durationSec=45;windowElapsedMs=45001;error=''}
        Check 'discovery_complete' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -eq 'SUCCESS')
        $ok.schemaVersion=2
        Check 'discovery_unknown_schema_rejected' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -like 'ERROR:*')
        $ok.schemaVersion=1
        $cancelled=[pscustomobject]@{schemaVersion=1;sessionId='s';runId='r';status='CANCELLED';completedWindow=$false}
        Check 'discovery_cancel_distinct' ((Get-DiscoveryTerminalOutcome $cancelled 3 's' 'r' 45) -eq 'CANCELLED')
        Check 'discovery_cancel_contradiction' ((Get-DiscoveryTerminalOutcome $cancelled 0 's' 'r' 45) -like 'ERROR:*')
        Check 'discovery_no_result' ((Get-DiscoveryTerminalOutcome $null 0 's' 'r' 45) -like 'ERROR:*')
        Check 'discovery_nonzero' ((Get-DiscoveryTerminalOutcome $ok 1 's' 'r' 45) -like 'ERROR:*')
        Check 'discovery_wrong_run' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'other' 45) -like 'ERROR:*')
        $ok.windowElapsedMs=6300
        Check 'discovery_early_window' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -like 'ERROR:*')
        $ok.windowElapsedMs=45001;$ok.completedWindow='true'
        Check 'discovery_string_bool_rejected' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -like 'ERROR:*')
        $ok.completedWindow=$true;$ok.error='failure'
        Check 'discovery_contradiction' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -like 'ERROR:*')
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $testForm=New-Object Windows.Forms.Form;$testForm.ClientSize=New-Object Drawing.Size(1108,700)
        $script:lblMonitorSummary=New-Object Windows.Forms.Label
        $grid=New-Object Windows.Forms.DataGridView;$grid.Dock='Fill';$grid.RowHeadersVisible=$false;$grid.AllowUserToAddRows=$false
        $testForm.Controls.Add($grid)
        foreach($scale in @(1,1.25,1.5,2)){
            $font=New-Object Drawing.Font('Segoe UI',([single](9*$scale)));[void]$fonts.Add($font);$grid.Font=$font;$grid.Columns.Clear()
            Initialize-MonitorColumn $grid
            $testForm.CreateControl();$grid.CreateControl();$grid.PerformLayout()
            $headersOk=$true
            foreach($col in $grid.Columns){$width=[Windows.Forms.TextRenderer]::MeasureText([string]$col.HeaderText,$grid.Font).Width+24;if($col.Width -lt $width){$headersOk=$false}}
            Check ('real_grid_headers_font_scale_'+$scale) ($headersOk -and $grid.Columns['MonLastSample'].HeaderText -ne $grid.Columns['MonChanged'].HeaderText)
            Check ('real_grid_scroll_policy_'+$scale) ($grid.ScrollBars -eq 'Both' -and $grid.Columns['MonTarget'].Frozen)
            Check ('real_grid_engine_error_fits_'+$scale) ($grid.Columns['MonState'].Width -ge ([Windows.Forms.TextRenderer]::MeasureText('ENGINE ERROR',$grid.Font).Width+20))
        }
        Fresh;Sample $true 3
        Refresh-MonitorSummary
        Check 'summary_current_online' ($lblMonitorSummary.Text -like '*Online 1*')
        Set-MonitorMeasurementError '192.0.2.1' 'failure';Refresh-MonitorSummary
        Check 'summary_excludes_engine_error' ($lblMonitorSummary.Text -like '*Online 0*' -and $lblMonitorSummary.ForeColor -eq [Drawing.Color]::DarkOrange)
        Fresh;Sample $true 5;Tick
        function Enqueue-PingRequest {throw 'Fixture local startup failure'}
        $script:MonitoringSchedulerBusy=$false;$script:MonitoringLastUiRefresh=$null
        Invoke-MonitorScheduler
        Check 'queue_failure_is_collector_error' ($script:MonitoringStats['192.0.2.1'].TotalCount -eq 1 -and $script:MonitoringStats['192.0.2.1'].FailureCount -eq 0 -and (Get-MonitorHealth $script:MonitoringStats['192.0.2.1'] $script:MonitoringConfig['192.0.2.1']) -eq 'ENGINE ERROR')
        # Execute actual adapter getter against a fixed adapter boundary; it must not write input/status.
        $node=@($script:mainAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object {$_.Name -eq 'Get-SelectedScanAdapterInfo'})[0]
        . ([scriptblock]::Create($node.Extent.Text))
        function Get-AdapterIPv4Info {param($adapter) return [pscustomobject]@{IP='192.0.2.1';Prefix=24;Gateway='192.0.2.254';InterfaceIndex=1}}
        function Format-Mac {param($value) return $value}
        $adapter=[pscustomobject]@{Name='Fixture';Speed=100000000;NetworkInterfaceType='Ethernet'}
        $adapter|Add-Member -MemberType ScriptMethod -Name GetPhysicalAddress -Value {return '001122334455'}
        $cmbScanAdapter=[pscustomobject]@{SelectedIndex=0;Tag=@($adapter)};$txtCidr=[pscustomobject]@{Text='198.51.100.0/28'};$lblScanStatus=[pscustomobject]@{Text='Previous result'}
        [void](Get-SelectedScanAdapterInfo)
        Check 'details_adapter_getter_no_ui_side_effects' ($txtCidr.Text -eq '198.51.100.0/28' -and $lblScanStatus.Text -eq 'Previous result')
        # Exercise the literal physical-workflow validator with isolated synthetic evidence.
        # This is not a physical GUI/LAN run; no physical result is inferred from these fixtures.
        $workflowText=[IO.File]::ReadAllText((Join-Path $Root '.github/workflows/ui-e2e-selfhosted.yml'))
        $stageLines=New-Object System.Collections.Generic.List[string];$inStage=$false;$inRun=$false
        foreach($line in ($workflowText -split "`r?`n")){
            if($line -eq '      - name: Stage safe evidence and assert required physical gates'){$inStage=$true;continue}
            if($inStage -and $line -match '^      - '){break}
            if($inStage -and $line -eq '        run: |'){$inRun=$true;continue}
            if($inRun -and $line.StartsWith('          ')){[void]$stageLines.Add($line.Substring(10))}
        }
        if($stageLines.Count -lt 20){throw 'Physical evidence validator extraction failed'}
        $stage=[scriptblock]::Create(($stageLines.ToArray() -join "`n"))
        $gateRoot=Join-Path $env:TEMP ('RFT-measurement-validator-'+[guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $gateRoot 'real-machine-results'),(Join-Path $gateRoot 'ci-artifacts') -Force)
            $gateRevision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $gateNames=@('measurement_correctness','interactive_gui_e2e','deep_ui_e2e','route_scope_planner','route_scope_live','real_lan_fast_balanced','machine_cleanliness_baseline','machine_cleanliness_post')
            $gateSummary=[ordered]@{sourceRevision=$gateRevision;mode='Full';pass=18;fail=0;skip=0;results=@($gateNames|ForEach-Object{[pscustomobject]@{name=$_;status='PASS'}})}
            $gateSummary|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $gateRoot 'real-machine-results/summary.json') -Encoding UTF8
            @{status='PASS';stage='completed';workerCompleted=$true;workerSucceeded=$true;lastPhase='Completed';lastError=''}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $gateRoot 'ci-artifacts/deep-ui-e2e.json') -Encoding UTF8
            'fixture tabs'|Set-Content -LiteralPath (Join-Path $gateRoot 'ci-artifacts/ui-tab-items.txt')
            '{}'|Set-Content -LiteralPath (Join-Path $gateRoot 'ci-artifacts/route-aware-live-summary.json')
            $verifiedChecks=$checks.ToArray()
            foreach($case in @('valid','wrong-revision','empty-checks','contradictory-status','failed-detail')){
                $gateMeasurement=[ordered]@{status='PASS';fail=0;sourceRevision=$gateRevision;checks=$verifiedChecks}
                if($case -eq 'wrong-revision'){$gateMeasurement.sourceRevision='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}
                if($case -eq 'empty-checks'){$gateMeasurement.checks=@()}
                if($case -eq 'contradictory-status'){$gateMeasurement.status='FAIL'}
                if($case -eq 'failed-detail'){$gateMeasurement.checks=@($verifiedChecks)+@([pscustomobject]@{name='fixture-failure';pass=$false})}
                $gateMeasurement|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $gateRoot 'ci-artifacts/measurement-correctness.json') -Encoding UTF8
                $accepted=$true;$gateError=''
                Push-Location $gateRoot
                try {
                    & {function git {param($verb,$arg) $global:LASTEXITCODE=0;return 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'};& $stage 6>$null}
                } catch {$accepted=$false;$gateError=$_.Exception.Message}
                finally {Pop-Location}
                Check ('physical_validator_fixture_'+$case) ($accepted -eq ($case -eq 'valid'))
                if($case -eq 'valid' -and -not $accepted){Write-Host $gateError}
            }
        } finally {Remove-Item -LiteralPath $gateRoot -Recurse -Force}
    }
    $failed=@($checks.ToArray()|Where-Object {-not $_.pass})
    if($BaselineRed){
        # These are real assertions failing on the shipped v1.5.2 functions, not an intentional exit mock.
        if($failed.Count -ne 2 -or 'duration_36h' -notin $failed.name -or 'measurement_error_not_network_loss' -notin $failed.name){throw 'Baseline did not reproduce exactly the two expected defects'}
        $exitCode=0
    } elseif($failed.Count -eq 0){$exitCode=0}
} catch {
    Check 'unhandled_test_exception' $false
    Write-Host ($_|Out-String)
} finally {
    $report=[ordered]@{schemaVersion=1;status=if($exitCode -eq 0){if($BaselineRed){'EXPECTED_RED'}else{'PASS'}}else{'FAIL'};runtime=[string]$PSVersionTable.PSVersion;sourceRevision=[string]$env:GITHUB_SHA;checks=$checks.ToArray();fail=@($checks.ToArray()|Where-Object {-not $_.pass}).Count}
    $name=if($BaselineRed){'measurement-baseline-red.json'}else{'measurement-correctness.json'}
    $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $artifact $name) -Encoding UTF8
    if($testForm){$testForm.Dispose()};foreach($font in $fonts){$font.Dispose()}
}
exit $exitCode
