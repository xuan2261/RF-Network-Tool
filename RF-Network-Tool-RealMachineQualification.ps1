[CmdletBinding()]
param(
    [ValidateSet('Safe','Gui','Full')][string]$Mode='Safe',
    [int]$InterfaceIndex=0,\n    [string]$ExpectedSourceRevision='',
    [string]$OutputRoot='',
    [switch]$AllowModuleInstall,
    [switch]$NoZip
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path $root 'real-machine-results'}
$stamp=(Get-Date).ToString('yyyyMMdd-HHmmss')
$runDir=Join-Path $OutputRoot ("RFT-real-machine-$stamp")
$stepsDir=Join-Path $runDir 'steps'
New-Item -ItemType Directory -Path $stepsDir -Force|Out-Null
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results=New-Object System.Collections.Generic.List[object]
$transcript=Join-Path $runDir 'qualification-transcript.txt'
$transcriptStarted=$false

function Add-Result([string]$name,[string]$status,[string]$detail,[long]$elapsedMs=0){
    [void]$results.Add([pscustomobject]@{name=$name;status=$status;detail=$detail;elapsedMs=$elapsedMs})
    $color=if($status -eq 'PASS'){'Green'}elseif($status -eq 'SKIP'){'Yellow'}else{'Red'}
    Write-Host ("{0,-5} {1} :: {2}" -f $status,$name,$detail) -ForegroundColor $color
}
function Mask-IPv4([string]$ip){
    if($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$'){return $ip}
    $p=$ip.Split('.');return "$($p[0]).$($p[1]).$($p[2]).x"
}
function Mask-NetworkEvidence([string]$text){
    if($null -eq $text){return ''}
    $text=[regex]::Replace($text,'(?i)\b(?:[0-9A-F]{2}[-:]){5}[0-9A-F]{2}\b','<MAC>')
    $text=[regex]::Replace($text,'(?<!\d)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?!\d)',{
        param($m)
        $parts=$m.Value.Split('.')
        try{$nums=@($parts|ForEach-Object {[int]$_})}catch{return $m.Value}
        if(@($nums|Where-Object {$_ -lt 0 -or $_ -gt 255}).Count){return $m.Value}
        if($m.Value -in @('127.0.0.1','0.0.0.0','255.255.255.255')){return $m.Value}
        return "$($parts[0]).$($parts[1]).$($parts[2]).x"
    })
    return $text
}
function Get-SourceRevisionEvidence{
    $revision='';$evidence='unknown'
    try{
        $envSha=([string]$env:GITHUB_SHA).Trim()
        if($envSha -match '^[0-9a-fA-F]{40}
    if($null -eq $text){return ''}
    foreach($v in @(
        @([string]$env:USERPROFILE,'<USERPROFILE>'),
        @([string]$env:USERNAME,'<USERNAME>'),
        @([string]$env:COMPUTERNAME,'<COMPUTER>')
    )){
        if(-not [string]::IsNullOrWhiteSpace($v[0])){$text=$text.Replace($v[0],$v[1])}
    }
    return $text
}
function Get-CleanWindowsPowerShellModulePath{
    $paths=New-Object System.Collections.Generic.List[string]
    try{
        $docs=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if($docs){[void]$paths.Add((Join-Path $docs 'WindowsPowerShell\Modules'))}
    }catch{}
    if($env:ProgramFiles){[void]$paths.Add((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))}
    [void]$paths.Add((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'))
    return (($paths.ToArray()|Where-Object {$_}|Select-Object -Unique) -join ';')
}
function Read-TextFileWithRetry([string]$path,[int]$timeoutMs=10000){
    $sw=[Diagnostics.Stopwatch]::StartNew();$last=$null
    while($sw.ElapsedMilliseconds -lt $timeoutMs){
        try{return [IO.File]::ReadAllText($path)}catch{
            $last=$_
            if($_.Exception.InnerException -isnot [IO.IOException] -and $_.Exception -isnot [IO.IOException]){throw}
            Start-Sleep -Milliseconds 100
        }
    }
    if($last){throw $last}
    throw "Timed out reading $path"
}
function Start-CleanWindowsPowerShell([string]$argumentLine,[string]$stdoutPath='',[string]$stderrPath=''){
    $oldModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Process')
    try{
        $env:PSModulePath=Get-CleanWindowsPowerShellModulePath
        $params=@{FilePath=$psExe;ArgumentList=$argumentLine;WindowStyle='Hidden';PassThru=$true}
        if($stdoutPath){$params.RedirectStandardOutput=$stdoutPath}
        if($stderrPath){$params.RedirectStandardError=$stderrPath}
        return Start-Process @params
    }finally{
        if($null -eq $oldModulePath){Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue}
        else{$env:PSModulePath=$oldModulePath}
    }
}
function Test-PSScriptAnalyzerClean{
    $verify=Join-Path $runDir 'verify-psscriptanalyzer.ps1'
    @'
$m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
if($m){exit 0}
exit 1
'@ | Set-Content -LiteralPath $verify -Encoding UTF8
    $p=$null
    try{
        $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$verify`"")
        if(-not $p.WaitForExit(30000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            return $false
        }
        $p.Refresh();return ([int]$p.ExitCode -eq 0)
    }catch{return $false}
    finally{if($p){try{$p.Dispose()}catch{}}}
}
function Invoke-Step([string]$name,[string]$script,[string]$arguments='',[int]$timeoutSec=180,[int[]]$skipExitCodes=@()){
    if(-not(Test-Path -LiteralPath $script)){Add-Result $name 'FAIL' ("Missing: $script");return}
    $stdout=Join-Path $stepsDir ($name+'.stdout.txt')
    $stderr=Join-Path $stepsDir ($name+'.stderr.txt')
    $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if($arguments){$argLine+=" $arguments"}
    $sw=[Diagnostics.Stopwatch]::StartNew();$p=$null
    try{
        $p=Start-CleanWindowsPowerShell $argLine $stdout $stderr
        if(-not $p.WaitForExit($timeoutSec*1000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            try{$p.Dispose()}catch{};$p=$null
            $sw.Stop();Add-Result $name 'FAIL' ("timeout "+$timeoutSec+"s") $sw.ElapsedMilliseconds;return
        }
        $p.Refresh();$rc=[int]$p.ExitCode
        try{$p.Dispose()}catch{};$p=$null
        $sw.Stop()
        $stdoutText=if(Test-Path -LiteralPath $stdout){Read-TextFileWithRetry $stdout 10000}else{''}
        $selfReportedFail=($stdoutText -match '(?m)^FAIL(?:ED)?:?\s')
        if($skipExitCodes -contains $rc){Add-Result $name 'SKIP' ("exit $rc - not applicable") $sw.ElapsedMilliseconds}
        elseif($rc -eq 0 -and -not $selfReportedFail){Add-Result $name 'PASS' 'exit 0' $sw.ElapsedMilliseconds}
        elseif($selfReportedFail){Add-Result $name 'FAIL' ("child reported FAIL (exit $rc)") $sw.ElapsedMilliseconds}
        else{Add-Result $name 'FAIL' ("exit $rc") $sw.ElapsedMilliseconds}
    }catch{
        $sw.Stop()
        if($p){try{$p.Dispose()}catch{};$p=$null}
        $orchestratorError=Join-Path $stepsDir ($name+'.orchestrator-error.txt')
        try{($_|Out-String)|Set-Content -LiteralPath $orchestratorError -Encoding UTF8}catch{}
        Add-Result $name 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds
    }finally{if($p){try{$p.Dispose()}catch{}}}
}
function Ensure-PSScriptAnalyzer{
    if(Test-PSScriptAnalyzerClean){return $true}
    if(-not $AllowModuleInstall){return $false}
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $installer=Join-Path $runDir 'install-psscriptanalyzer.ps1'
    $stdout=Join-Path $stepsDir 'psscriptanalyzer_install.stdout.txt'
    $stderr=Join-Path $stepsDir 'psscriptanalyzer_install.stderr.txt'
    @'
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$oldPolicy=$null
try{
    try{
        $repo=Get-PSRepository -Name PSGallery -ErrorAction Stop
        $oldPolicy=[string]$repo.InstallationPolicy
        if($oldPolicy -ne 'Trusted'){Set-PSRepository -Name PSGallery -InstallationPolicy Trusted}
    }catch{}
    $nuget=Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $nuget -or $nuget.Version -lt [version]'2.8.5.201'){
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }
    $psg=Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $psg -or $psg.Version -lt [version]'2.2.5'){
        Install-Module -Name PowerShellGet -MinimumVersion 2.2.5 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        exit 42
    }
    Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
    $m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
    if(-not $m){throw 'PSScriptAnalyzer 1.25.0 was not found after installation.'}
    exit 0
}finally{
    if($oldPolicy -and $oldPolicy -ne 'Trusted'){try{Set-PSRepository -Name PSGallery -InstallationPolicy $oldPolicy}catch{}}
}
'@ | Set-Content -LiteralPath $installer -Encoding UTF8
    try{
        $attempt=0
        do{
            $attempt++
            if(Test-Path $stdout){Remove-Item $stdout -Force -ErrorAction SilentlyContinue}
            if(Test-Path $stderr){Remove-Item $stderr -Force -ErrorAction SilentlyContinue}
            $p=$null
            try{
                $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`"") $stdout $stderr
                if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};throw 'PSScriptAnalyzer installer timed out.'}
                $p.Refresh();$rc=[int]$p.ExitCode
            }finally{if($p){try{$p.Dispose()}catch{}}}
            if($rc -eq 42 -and $attempt -lt 3){continue}
            if($rc -ne 0){throw ("PSScriptAnalyzer installer exit "+$rc)}
            break
        }while($attempt -lt 3)
        $sw.Stop()
        if(Test-PSScriptAnalyzerClean){Add-Result 'psscriptanalyzer_install' 'PASS' 'PSScriptAnalyzer 1.25.0 available via clean Windows PowerShell module path' $sw.ElapsedMilliseconds;return $true}
        $diag=Join-Path $stepsDir 'psscriptanalyzer_install_diagnostics.txt'
        try{
            @(
                ('CleanPSModulePath='+(Get-CleanWindowsPowerShellModulePath)),
                ('MyDocuments='+[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)),
                ('ProgramFiles='+$env:ProgramFiles),
                ('SystemRoot='+$env:SystemRoot)
            )|Set-Content -LiteralPath $diag -Encoding UTF8
        }catch{}
        Add-Result 'psscriptanalyzer_install' 'FAIL' 'Installer completed but PSScriptAnalyzer 1.25.0 is unavailable.' $sw.ElapsedMilliseconds
        return $false
    }catch{
        $sw.Stop();Add-Result 'psscriptanalyzer_install' 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds;return $false
    }
}
function Write-MachineInfo{
    try{
        $os=Get-CimInstance Win32_OperatingSystem
        $adapters=@()
        foreach($a in @(Get-NetAdapter -ErrorAction SilentlyContinue|Sort-Object ifIndex)){
            $ips=@()
            foreach($ip in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)){
                if($ip.IPAddress){$ips += [pscustomobject]@{address=(Mask-IPv4 ([string]$ip.IPAddress));prefixLength=[int]$ip.PrefixLength;state=[string]$ip.AddressState}}
            }
            $adapters += [pscustomobject]@{ifIndex=[int]$a.ifIndex;name=[string]$a.Name;description=[string]$a.InterfaceDescription;status=[string]$a.Status;hardwareInterface=[bool]$a.HardwareInterface;ipv4=$ips}
        }
        $snap=[ordered]@{
            schemaVersion=2;capturedAt=(Get-Date).ToString('o');mode=$Mode
            os=[ordered]@{caption=[string]$os.Caption;version=[string]$os.Version;build=[string]$os.BuildNumber;architecture=[string]$os.OSArchitecture}
            powershell=[ordered]@{version=[string]$PSVersionTable.PSVersion;edition=[string]$PSVersionTable.PSEdition;apartment=[string][Threading.Thread]::CurrentThread.ApartmentState}
            process=[ordered]@{userInteractive=[Environment]::UserInteractive;sessionId=[int](Get-Process -Id $PID).SessionId;is64Bit=[Environment]::Is64BitProcess}
            adapters=$adapters
            privacy='Username/computer/profile omitted; bundle IPv4/MAC redacted.'
        }
        [IO.File]::WriteAllText((Join-Path $runDir 'machine-info.json'),($snap|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        Add-Result 'machine_snapshot' 'PASS' ("$($os.Caption) build $($os.BuildNumber); PS $($PSVersionTable.PSVersion)")
    }catch{Add-Result 'machine_snapshot' 'FAIL' $_.Exception.Message}
}
function Parser-Sweep{
    $files=@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $tests=Join-Path $root 'tests'
    if(Test-Path $tests){$files += @(Get-ChildItem -LiteralPath $tests -Filter '*.ps1' -File -ErrorAction SilentlyContinue)}
    $errs=New-Object System.Collections.Generic.List[string]
    foreach($f in $files){
        $tok=$null;$e=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tok,[ref]$e)
        foreach($x in @($e)){[void]$errs.Add(("{0}:{1}:{2} {3}" -f $f.Name,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message))}
    }
    if($errs.Count){$errs.ToArray()|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'FAIL' ("$($errs.Count) errors")}
    else{"Parsed $($files.Count) PowerShell files; errors=0"|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'PASS' ("$($files.Count) PowerShell files")}
}
function Finalize-Evidence{
    try{if($transcriptStarted){Stop-Transcript|Out-Null;$script:transcriptStarted=$false}}catch{}
    $summary=[ordered]@{
        schemaVersion=2;generatedAt=(Get-Date).ToString('o');mode=$Mode\n        sourceRevision=[string](Get-SourceRevisionEvidence).revision;sourceRevisionEvidence=[string](Get-SourceRevisionEvidence).evidence
        results=$results.ToArray()
        pass=@($results.ToArray()|Where-Object status -eq 'PASS').Count
        fail=@($results.ToArray()|Where-Object status -eq 'FAIL').Count
        skip=@($results.ToArray()|Where-Object status -eq 'SKIP').Count
    }
    [IO.File]::WriteAllText((Join-Path $runDir 'summary.json'),($summary|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    @("RF Network Tool Real-Machine Qualification","Mode: $Mode","PASS: $($summary.pass)","FAIL: $($summary.fail)","SKIP: $($summary.skip)","") + @($results.ToArray()|ForEach-Object{"$($_.status)	$($_.name)	$($_.detail)	$($_.elapsedMs)ms"}) | Set-Content (Join-Path $runDir 'SUMMARY.txt') -Encoding UTF8
    foreach($f in @(Get-ChildItem -LiteralPath $runDir -File -Recurse -ErrorAction SilentlyContinue)){
        if($f.Extension -in @('.txt','.log','.json','.md')){
            try{$raw=[IO.File]::ReadAllText($f.FullName);$safe=Sanitize-Text $raw;if($safe -ne $raw){[IO.File]::WriteAllText($f.FullName,$safe,(New-Object Text.UTF8Encoding($true)))}}catch{}
        }
    }
    if(-not $NoZip){
        New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
        $zip=Join-Path $OutputRoot ("RF-Network-Tool-REAL-MACHINE-LOGS-$stamp.zip")
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
        $hash=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($zip))"|Set-Content ($zip+'.sha256.txt') -Encoding ASCII
        Write-Host ''
        Write-Host 'UPLOAD THIS ZIP:' $zip -ForegroundColor Cyan
        Write-Host 'SHA256:' $hash -ForegroundColor Cyan
    }
}

try{
    try{Start-Transcript -LiteralPath $transcript -Force|Out-Null;$transcriptStarted=$true}catch{}
    Write-Host "Mode=$Mode InterfaceIndex=$InterfaceIndex Root=$root"
    Write-MachineInfo
    Parser-Sweep
    $tests=Join-Path $root 'tests'
    if(-not(Test-Path $tests)){Add-Result 'full_project_tests_present' 'FAIL' 'Use the FULL PROJECT package.'}
    else{
        Add-Result 'full_project_tests_present' 'PASS' 'tests directory available'
        Invoke-Step 'windows_integration' (Join-Path $tests 'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1') '' 180
        if(Ensure-PSScriptAnalyzer){Invoke-Step 'powershell_lint' (Join-Path $tests 'WINDOWS_LINT_GATE_v1_4_2.ps1') '' 180}
        else{Add-Result 'powershell_lint' 'SKIP' 'PSScriptAnalyzer 1.25.0 unavailable; GUI/FULL mode can install it.'}
        Invoke-Step 'chaos_recovery' (Join-Path $tests 'WINDOWS_CHAOS_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'synthetic_performance' (Join-Path $tests 'WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'launcher_diagnostic_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-DiagnosticOnly -TimeoutSec 20' 90
        if($Mode -in @('Gui','Full')){
            Invoke-Step 'interactive_preflight' (Join-Path $tests 'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1') '' 60
            Invoke-Step 'interactive_gui_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-TimeoutSec 30' 120
        }else{Add-Result 'interactive_gui_e2e' 'SKIP' 'SAFE mode'}
        if($Mode -eq 'Full'){
            $lanArgs='-Profiles FAST,BALANCED';if($InterfaceIndex -gt 0){$lanArgs+=" -InterfaceIndex $InterfaceIndex"}
            Invoke-Step 'real_lan_fast_balanced' (Join-Path $tests 'WINDOWS_REAL_LAN_TEST_v1_4_2.ps1') $lanArgs 360 @(3)
        }else{Add-Result 'real_lan_fast_balanced' 'SKIP' ("$Mode mode")}
    }
    if(Test-Path (Join-Path $root 'ci-artifacts')){Copy-Item (Join-Path $root 'ci-artifacts') (Join-Path $runDir 'ci-artifacts') -Recurse -Force}
    if(Test-Path (Join-Path $root 'logs')){Copy-Item (Join-Path $root 'logs') (Join-Path $runDir 'app-logs') -Recurse -Force}
}catch{Add-Result 'orchestrator' 'FAIL' $_.Exception.Message}
finally{Finalize-Evidence}
if(@($results.ToArray()|Where-Object status -eq 'FAIL').Count){exit 1}
exit 0
){$revision=$envSha.ToLowerInvariant();$evidence='GITHUB_SHA'}
    }catch{}
    if(-not $revision){
        try{
            if(Test-Path -LiteralPath (Join-Path $root '.git')){
                $git=Get-Command git.exe -ErrorAction SilentlyContinue
                if($git){
                    $out=& $git.Source -C $root rev-parse HEAD 2>$null
                    $candidate=([string]$out).Trim()
                    if($LASTEXITCODE -eq 0 -and $candidate -match '^[0-9a-fA-F]{40}
    if($null -eq $text){return ''}
    foreach($v in @(
        @([string]$env:USERPROFILE,'<USERPROFILE>'),
        @([string]$env:USERNAME,'<USERNAME>'),
        @([string]$env:COMPUTERNAME,'<COMPUTER>')
    )){
        if(-not [string]::IsNullOrWhiteSpace($v[0])){$text=$text.Replace($v[0],$v[1])}
    }
    return $text
}
function Get-CleanWindowsPowerShellModulePath{
    $paths=New-Object System.Collections.Generic.List[string]
    try{
        $docs=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if($docs){[void]$paths.Add((Join-Path $docs 'WindowsPowerShell\Modules'))}
    }catch{}
    if($env:ProgramFiles){[void]$paths.Add((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))}
    [void]$paths.Add((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'))
    return (($paths.ToArray()|Where-Object {$_}|Select-Object -Unique) -join ';')
}
function Read-TextFileWithRetry([string]$path,[int]$timeoutMs=10000){
    $sw=[Diagnostics.Stopwatch]::StartNew();$last=$null
    while($sw.ElapsedMilliseconds -lt $timeoutMs){
        try{return [IO.File]::ReadAllText($path)}catch{
            $last=$_
            if($_.Exception.InnerException -isnot [IO.IOException] -and $_.Exception -isnot [IO.IOException]){throw}
            Start-Sleep -Milliseconds 100
        }
    }
    if($last){throw $last}
    throw "Timed out reading $path"
}
function Start-CleanWindowsPowerShell([string]$argumentLine,[string]$stdoutPath='',[string]$stderrPath=''){
    $oldModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Process')
    try{
        $env:PSModulePath=Get-CleanWindowsPowerShellModulePath
        $params=@{FilePath=$psExe;ArgumentList=$argumentLine;WindowStyle='Hidden';PassThru=$true}
        if($stdoutPath){$params.RedirectStandardOutput=$stdoutPath}
        if($stderrPath){$params.RedirectStandardError=$stderrPath}
        return Start-Process @params
    }finally{
        if($null -eq $oldModulePath){Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue}
        else{$env:PSModulePath=$oldModulePath}
    }
}
function Test-PSScriptAnalyzerClean{
    $verify=Join-Path $runDir 'verify-psscriptanalyzer.ps1'
    @'
$m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
if($m){exit 0}
exit 1
'@ | Set-Content -LiteralPath $verify -Encoding UTF8
    $p=$null
    try{
        $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$verify`"")
        if(-not $p.WaitForExit(30000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            return $false
        }
        $p.Refresh();return ([int]$p.ExitCode -eq 0)
    }catch{return $false}
    finally{if($p){try{$p.Dispose()}catch{}}}
}
function Invoke-Step([string]$name,[string]$script,[string]$arguments='',[int]$timeoutSec=180,[int[]]$skipExitCodes=@()){
    if(-not(Test-Path -LiteralPath $script)){Add-Result $name 'FAIL' ("Missing: $script");return}
    $stdout=Join-Path $stepsDir ($name+'.stdout.txt')
    $stderr=Join-Path $stepsDir ($name+'.stderr.txt')
    $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if($arguments){$argLine+=" $arguments"}
    $sw=[Diagnostics.Stopwatch]::StartNew();$p=$null
    try{
        $p=Start-CleanWindowsPowerShell $argLine $stdout $stderr
        if(-not $p.WaitForExit($timeoutSec*1000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            try{$p.Dispose()}catch{};$p=$null
            $sw.Stop();Add-Result $name 'FAIL' ("timeout "+$timeoutSec+"s") $sw.ElapsedMilliseconds;return
        }
        $p.Refresh();$rc=[int]$p.ExitCode
        try{$p.Dispose()}catch{};$p=$null
        $sw.Stop()
        $stdoutText=if(Test-Path -LiteralPath $stdout){Read-TextFileWithRetry $stdout 10000}else{''}
        $selfReportedFail=($stdoutText -match '(?m)^FAIL(?:ED)?:?\s')
        if($skipExitCodes -contains $rc){Add-Result $name 'SKIP' ("exit $rc - not applicable") $sw.ElapsedMilliseconds}
        elseif($rc -eq 0 -and -not $selfReportedFail){Add-Result $name 'PASS' 'exit 0' $sw.ElapsedMilliseconds}
        elseif($selfReportedFail){Add-Result $name 'FAIL' ("child reported FAIL (exit $rc)") $sw.ElapsedMilliseconds}
        else{Add-Result $name 'FAIL' ("exit $rc") $sw.ElapsedMilliseconds}
    }catch{
        $sw.Stop()
        if($p){try{$p.Dispose()}catch{};$p=$null}
        $orchestratorError=Join-Path $stepsDir ($name+'.orchestrator-error.txt')
        try{($_|Out-String)|Set-Content -LiteralPath $orchestratorError -Encoding UTF8}catch{}
        Add-Result $name 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds
    }finally{if($p){try{$p.Dispose()}catch{}}}
}
function Ensure-PSScriptAnalyzer{
    if(Test-PSScriptAnalyzerClean){return $true}
    if(-not $AllowModuleInstall){return $false}
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $installer=Join-Path $runDir 'install-psscriptanalyzer.ps1'
    $stdout=Join-Path $stepsDir 'psscriptanalyzer_install.stdout.txt'
    $stderr=Join-Path $stepsDir 'psscriptanalyzer_install.stderr.txt'
    @'
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$oldPolicy=$null
try{
    try{
        $repo=Get-PSRepository -Name PSGallery -ErrorAction Stop
        $oldPolicy=[string]$repo.InstallationPolicy
        if($oldPolicy -ne 'Trusted'){Set-PSRepository -Name PSGallery -InstallationPolicy Trusted}
    }catch{}
    $nuget=Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $nuget -or $nuget.Version -lt [version]'2.8.5.201'){
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }
    $psg=Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $psg -or $psg.Version -lt [version]'2.2.5'){
        Install-Module -Name PowerShellGet -MinimumVersion 2.2.5 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        exit 42
    }
    Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
    $m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
    if(-not $m){throw 'PSScriptAnalyzer 1.25.0 was not found after installation.'}
    exit 0
}finally{
    if($oldPolicy -and $oldPolicy -ne 'Trusted'){try{Set-PSRepository -Name PSGallery -InstallationPolicy $oldPolicy}catch{}}
}
'@ | Set-Content -LiteralPath $installer -Encoding UTF8
    try{
        $attempt=0
        do{
            $attempt++
            if(Test-Path $stdout){Remove-Item $stdout -Force -ErrorAction SilentlyContinue}
            if(Test-Path $stderr){Remove-Item $stderr -Force -ErrorAction SilentlyContinue}
            $p=$null
            try{
                $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`"") $stdout $stderr
                if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};throw 'PSScriptAnalyzer installer timed out.'}
                $p.Refresh();$rc=[int]$p.ExitCode
            }finally{if($p){try{$p.Dispose()}catch{}}}
            if($rc -eq 42 -and $attempt -lt 3){continue}
            if($rc -ne 0){throw ("PSScriptAnalyzer installer exit "+$rc)}
            break
        }while($attempt -lt 3)
        $sw.Stop()
        if(Test-PSScriptAnalyzerClean){Add-Result 'psscriptanalyzer_install' 'PASS' 'PSScriptAnalyzer 1.25.0 available via clean Windows PowerShell module path' $sw.ElapsedMilliseconds;return $true}
        $diag=Join-Path $stepsDir 'psscriptanalyzer_install_diagnostics.txt'
        try{
            @(
                ('CleanPSModulePath='+(Get-CleanWindowsPowerShellModulePath)),
                ('MyDocuments='+[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)),
                ('ProgramFiles='+$env:ProgramFiles),
                ('SystemRoot='+$env:SystemRoot)
            )|Set-Content -LiteralPath $diag -Encoding UTF8
        }catch{}
        Add-Result 'psscriptanalyzer_install' 'FAIL' 'Installer completed but PSScriptAnalyzer 1.25.0 is unavailable.' $sw.ElapsedMilliseconds
        return $false
    }catch{
        $sw.Stop();Add-Result 'psscriptanalyzer_install' 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds;return $false
    }
}
function Write-MachineInfo{
    try{
        $os=Get-CimInstance Win32_OperatingSystem
        $adapters=@()
        foreach($a in @(Get-NetAdapter -ErrorAction SilentlyContinue|Sort-Object ifIndex)){
            $ips=@()
            foreach($ip in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)){
                if($ip.IPAddress){$ips += [pscustomobject]@{address=(Mask-IPv4 ([string]$ip.IPAddress));prefixLength=[int]$ip.PrefixLength;state=[string]$ip.AddressState}}
            }
            $adapters += [pscustomobject]@{ifIndex=[int]$a.ifIndex;name=[string]$a.Name;description=[string]$a.InterfaceDescription;status=[string]$a.Status;hardwareInterface=[bool]$a.HardwareInterface;ipv4=$ips}
        }
        $snap=[ordered]@{
            schemaVersion=2;capturedAt=(Get-Date).ToString('o');mode=$Mode
            os=[ordered]@{caption=[string]$os.Caption;version=[string]$os.Version;build=[string]$os.BuildNumber;architecture=[string]$os.OSArchitecture}
            powershell=[ordered]@{version=[string]$PSVersionTable.PSVersion;edition=[string]$PSVersionTable.PSEdition;apartment=[string][Threading.Thread]::CurrentThread.ApartmentState}
            process=[ordered]@{userInteractive=[Environment]::UserInteractive;sessionId=[int](Get-Process -Id $PID).SessionId;is64Bit=[Environment]::Is64BitProcess}
            adapters=$adapters
            privacy='Username/computer/profile/MAC omitted; IPv4 host octet masked.'
        }
        [IO.File]::WriteAllText((Join-Path $runDir 'machine-info.json'),($snap|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        Add-Result 'machine_snapshot' 'PASS' ("$($os.Caption) build $($os.BuildNumber); PS $($PSVersionTable.PSVersion)")
    }catch{Add-Result 'machine_snapshot' 'FAIL' $_.Exception.Message}
}
function Parser-Sweep{
    $files=@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $tests=Join-Path $root 'tests'
    if(Test-Path $tests){$files += @(Get-ChildItem -LiteralPath $tests -Filter '*.ps1' -File -ErrorAction SilentlyContinue)}
    $errs=New-Object System.Collections.Generic.List[string]
    foreach($f in $files){
        $tok=$null;$e=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tok,[ref]$e)
        foreach($x in @($e)){[void]$errs.Add(("{0}:{1}:{2} {3}" -f $f.Name,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message))}
    }
    if($errs.Count){$errs.ToArray()|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'FAIL' ("$($errs.Count) errors")}
    else{"Parsed $($files.Count) PowerShell files; errors=0"|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'PASS' ("$($files.Count) PowerShell files")}
}
function Finalize-Evidence{
    try{if($transcriptStarted){Stop-Transcript|Out-Null;$script:transcriptStarted=$false}}catch{}
    $summary=[ordered]@{
        schemaVersion=2;generatedAt=(Get-Date).ToString('o');mode=$Mode
        results=$results.ToArray()
        pass=@($results.ToArray()|Where-Object status -eq 'PASS').Count
        fail=@($results.ToArray()|Where-Object status -eq 'FAIL').Count
        skip=@($results.ToArray()|Where-Object status -eq 'SKIP').Count
    }
    [IO.File]::WriteAllText((Join-Path $runDir 'summary.json'),($summary|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    @("RF Network Tool Real-Machine Qualification","Mode: $Mode","PASS: $($summary.pass)","FAIL: $($summary.fail)","SKIP: $($summary.skip)","") + @($results.ToArray()|ForEach-Object{"$($_.status)	$($_.name)	$($_.detail)	$($_.elapsedMs)ms"}) | Set-Content (Join-Path $runDir 'SUMMARY.txt') -Encoding UTF8
    foreach($f in @(Get-ChildItem -LiteralPath $runDir -File -Recurse -ErrorAction SilentlyContinue)){
        if($f.Extension -in @('.txt','.log','.json','.md')){
            try{$raw=[IO.File]::ReadAllText($f.FullName);$safe=Sanitize-Text $raw;if($safe -ne $raw){[IO.File]::WriteAllText($f.FullName,$safe,(New-Object Text.UTF8Encoding($true)))}}catch{}
        }
    }
    if(-not $NoZip){
        New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
        $zip=Join-Path $OutputRoot ("RF-Network-Tool-REAL-MACHINE-LOGS-$stamp.zip")
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
        $hash=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($zip))"|Set-Content ($zip+'.sha256.txt') -Encoding ASCII
        Write-Host ''
        Write-Host 'UPLOAD THIS ZIP:' $zip -ForegroundColor Cyan
        Write-Host 'SHA256:' $hash -ForegroundColor Cyan
    }
}

try{
    try{Start-Transcript -LiteralPath $transcript -Force|Out-Null;$transcriptStarted=$true}catch{}
    Write-Host "Mode=$Mode InterfaceIndex=$InterfaceIndex Root=$root"
    Write-MachineInfo
    Parser-Sweep
    $tests=Join-Path $root 'tests'
    if(-not(Test-Path $tests)){Add-Result 'full_project_tests_present' 'FAIL' 'Use the FULL PROJECT package.'}
    else{
        Add-Result 'full_project_tests_present' 'PASS' 'tests directory available'
        Invoke-Step 'windows_integration' (Join-Path $tests 'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1') '' 180
        if(Ensure-PSScriptAnalyzer){Invoke-Step 'powershell_lint' (Join-Path $tests 'WINDOWS_LINT_GATE_v1_4_2.ps1') '' 180}
        else{Add-Result 'powershell_lint' 'SKIP' 'PSScriptAnalyzer 1.25.0 unavailable; GUI/FULL mode can install it.'}
        Invoke-Step 'chaos_recovery' (Join-Path $tests 'WINDOWS_CHAOS_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'synthetic_performance' (Join-Path $tests 'WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'launcher_diagnostic_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-DiagnosticOnly -TimeoutSec 20' 90
        if($Mode -in @('Gui','Full')){
            Invoke-Step 'interactive_preflight' (Join-Path $tests 'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1') '' 60
            Invoke-Step 'interactive_gui_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-TimeoutSec 30' 120
        }else{Add-Result 'interactive_gui_e2e' 'SKIP' 'SAFE mode'}
        if($Mode -eq 'Full'){
            $lanArgs='-Profiles FAST,BALANCED';if($InterfaceIndex -gt 0){$lanArgs+=" -InterfaceIndex $InterfaceIndex"}
            Invoke-Step 'real_lan_fast_balanced' (Join-Path $tests 'WINDOWS_REAL_LAN_TEST_v1_4_2.ps1') $lanArgs 360 @(3)
        }else{Add-Result 'real_lan_fast_balanced' 'SKIP' ("$Mode mode")}
    }
    if(Test-Path (Join-Path $root 'ci-artifacts')){Copy-Item (Join-Path $root 'ci-artifacts') (Join-Path $runDir 'ci-artifacts') -Recurse -Force}
    if(Test-Path (Join-Path $root 'logs')){Copy-Item (Join-Path $root 'logs') (Join-Path $runDir 'app-logs') -Recurse -Force}
}catch{Add-Result 'orchestrator' 'FAIL' $_.Exception.Message}
finally{Finalize-Evidence}
if(@($results.ToArray()|Where-Object status -eq 'FAIL').Count){exit 1}
exit 0
){$revision=$candidate.ToLowerInvariant();$evidence='git-rev-parse'}
                }
            }
        }catch{}
    }
    if(-not $revision){
        try{
            $leaf=Split-Path -Leaf $root
            if($leaf -match '([0-9a-fA-F]{40})
    if($null -eq $text){return ''}
    foreach($v in @(
        @([string]$env:USERPROFILE,'<USERPROFILE>'),
        @([string]$env:USERNAME,'<USERNAME>'),
        @([string]$env:COMPUTERNAME,'<COMPUTER>')
    )){
        if(-not [string]::IsNullOrWhiteSpace($v[0])){$text=$text.Replace($v[0],$v[1])}
    }
    return $text
}
function Get-CleanWindowsPowerShellModulePath{
    $paths=New-Object System.Collections.Generic.List[string]
    try{
        $docs=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if($docs){[void]$paths.Add((Join-Path $docs 'WindowsPowerShell\Modules'))}
    }catch{}
    if($env:ProgramFiles){[void]$paths.Add((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))}
    [void]$paths.Add((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'))
    return (($paths.ToArray()|Where-Object {$_}|Select-Object -Unique) -join ';')
}
function Read-TextFileWithRetry([string]$path,[int]$timeoutMs=10000){
    $sw=[Diagnostics.Stopwatch]::StartNew();$last=$null
    while($sw.ElapsedMilliseconds -lt $timeoutMs){
        try{return [IO.File]::ReadAllText($path)}catch{
            $last=$_
            if($_.Exception.InnerException -isnot [IO.IOException] -and $_.Exception -isnot [IO.IOException]){throw}
            Start-Sleep -Milliseconds 100
        }
    }
    if($last){throw $last}
    throw "Timed out reading $path"
}
function Start-CleanWindowsPowerShell([string]$argumentLine,[string]$stdoutPath='',[string]$stderrPath=''){
    $oldModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Process')
    try{
        $env:PSModulePath=Get-CleanWindowsPowerShellModulePath
        $params=@{FilePath=$psExe;ArgumentList=$argumentLine;WindowStyle='Hidden';PassThru=$true}
        if($stdoutPath){$params.RedirectStandardOutput=$stdoutPath}
        if($stderrPath){$params.RedirectStandardError=$stderrPath}
        return Start-Process @params
    }finally{
        if($null -eq $oldModulePath){Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue}
        else{$env:PSModulePath=$oldModulePath}
    }
}
function Test-PSScriptAnalyzerClean{
    $verify=Join-Path $runDir 'verify-psscriptanalyzer.ps1'
    @'
$m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
if($m){exit 0}
exit 1
'@ | Set-Content -LiteralPath $verify -Encoding UTF8
    $p=$null
    try{
        $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$verify`"")
        if(-not $p.WaitForExit(30000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            return $false
        }
        $p.Refresh();return ([int]$p.ExitCode -eq 0)
    }catch{return $false}
    finally{if($p){try{$p.Dispose()}catch{}}}
}
function Invoke-Step([string]$name,[string]$script,[string]$arguments='',[int]$timeoutSec=180,[int[]]$skipExitCodes=@()){
    if(-not(Test-Path -LiteralPath $script)){Add-Result $name 'FAIL' ("Missing: $script");return}
    $stdout=Join-Path $stepsDir ($name+'.stdout.txt')
    $stderr=Join-Path $stepsDir ($name+'.stderr.txt')
    $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if($arguments){$argLine+=" $arguments"}
    $sw=[Diagnostics.Stopwatch]::StartNew();$p=$null
    try{
        $p=Start-CleanWindowsPowerShell $argLine $stdout $stderr
        if(-not $p.WaitForExit($timeoutSec*1000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            try{$p.Dispose()}catch{};$p=$null
            $sw.Stop();Add-Result $name 'FAIL' ("timeout "+$timeoutSec+"s") $sw.ElapsedMilliseconds;return
        }
        $p.Refresh();$rc=[int]$p.ExitCode
        try{$p.Dispose()}catch{};$p=$null
        $sw.Stop()
        $stdoutText=if(Test-Path -LiteralPath $stdout){Read-TextFileWithRetry $stdout 10000}else{''}
        $selfReportedFail=($stdoutText -match '(?m)^FAIL(?:ED)?:?\s')
        if($skipExitCodes -contains $rc){Add-Result $name 'SKIP' ("exit $rc - not applicable") $sw.ElapsedMilliseconds}
        elseif($rc -eq 0 -and -not $selfReportedFail){Add-Result $name 'PASS' 'exit 0' $sw.ElapsedMilliseconds}
        elseif($selfReportedFail){Add-Result $name 'FAIL' ("child reported FAIL (exit $rc)") $sw.ElapsedMilliseconds}
        else{Add-Result $name 'FAIL' ("exit $rc") $sw.ElapsedMilliseconds}
    }catch{
        $sw.Stop()
        if($p){try{$p.Dispose()}catch{};$p=$null}
        $orchestratorError=Join-Path $stepsDir ($name+'.orchestrator-error.txt')
        try{($_|Out-String)|Set-Content -LiteralPath $orchestratorError -Encoding UTF8}catch{}
        Add-Result $name 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds
    }finally{if($p){try{$p.Dispose()}catch{}}}
}
function Ensure-PSScriptAnalyzer{
    if(Test-PSScriptAnalyzerClean){return $true}
    if(-not $AllowModuleInstall){return $false}
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $installer=Join-Path $runDir 'install-psscriptanalyzer.ps1'
    $stdout=Join-Path $stepsDir 'psscriptanalyzer_install.stdout.txt'
    $stderr=Join-Path $stepsDir 'psscriptanalyzer_install.stderr.txt'
    @'
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$oldPolicy=$null
try{
    try{
        $repo=Get-PSRepository -Name PSGallery -ErrorAction Stop
        $oldPolicy=[string]$repo.InstallationPolicy
        if($oldPolicy -ne 'Trusted'){Set-PSRepository -Name PSGallery -InstallationPolicy Trusted}
    }catch{}
    $nuget=Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $nuget -or $nuget.Version -lt [version]'2.8.5.201'){
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }
    $psg=Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $psg -or $psg.Version -lt [version]'2.2.5'){
        Install-Module -Name PowerShellGet -MinimumVersion 2.2.5 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        exit 42
    }
    Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
    $m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
    if(-not $m){throw 'PSScriptAnalyzer 1.25.0 was not found after installation.'}
    exit 0
}finally{
    if($oldPolicy -and $oldPolicy -ne 'Trusted'){try{Set-PSRepository -Name PSGallery -InstallationPolicy $oldPolicy}catch{}}
}
'@ | Set-Content -LiteralPath $installer -Encoding UTF8
    try{
        $attempt=0
        do{
            $attempt++
            if(Test-Path $stdout){Remove-Item $stdout -Force -ErrorAction SilentlyContinue}
            if(Test-Path $stderr){Remove-Item $stderr -Force -ErrorAction SilentlyContinue}
            $p=$null
            try{
                $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`"") $stdout $stderr
                if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};throw 'PSScriptAnalyzer installer timed out.'}
                $p.Refresh();$rc=[int]$p.ExitCode
            }finally{if($p){try{$p.Dispose()}catch{}}}
            if($rc -eq 42 -and $attempt -lt 3){continue}
            if($rc -ne 0){throw ("PSScriptAnalyzer installer exit "+$rc)}
            break
        }while($attempt -lt 3)
        $sw.Stop()
        if(Test-PSScriptAnalyzerClean){Add-Result 'psscriptanalyzer_install' 'PASS' 'PSScriptAnalyzer 1.25.0 available via clean Windows PowerShell module path' $sw.ElapsedMilliseconds;return $true}
        $diag=Join-Path $stepsDir 'psscriptanalyzer_install_diagnostics.txt'
        try{
            @(
                ('CleanPSModulePath='+(Get-CleanWindowsPowerShellModulePath)),
                ('MyDocuments='+[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)),
                ('ProgramFiles='+$env:ProgramFiles),
                ('SystemRoot='+$env:SystemRoot)
            )|Set-Content -LiteralPath $diag -Encoding UTF8
        }catch{}
        Add-Result 'psscriptanalyzer_install' 'FAIL' 'Installer completed but PSScriptAnalyzer 1.25.0 is unavailable.' $sw.ElapsedMilliseconds
        return $false
    }catch{
        $sw.Stop();Add-Result 'psscriptanalyzer_install' 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds;return $false
    }
}
function Write-MachineInfo{
    try{
        $os=Get-CimInstance Win32_OperatingSystem
        $adapters=@()
        foreach($a in @(Get-NetAdapter -ErrorAction SilentlyContinue|Sort-Object ifIndex)){
            $ips=@()
            foreach($ip in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)){
                if($ip.IPAddress){$ips += [pscustomobject]@{address=(Mask-IPv4 ([string]$ip.IPAddress));prefixLength=[int]$ip.PrefixLength;state=[string]$ip.AddressState}}
            }
            $adapters += [pscustomobject]@{ifIndex=[int]$a.ifIndex;name=[string]$a.Name;description=[string]$a.InterfaceDescription;status=[string]$a.Status;hardwareInterface=[bool]$a.HardwareInterface;ipv4=$ips}
        }
        $snap=[ordered]@{
            schemaVersion=2;capturedAt=(Get-Date).ToString('o');mode=$Mode
            os=[ordered]@{caption=[string]$os.Caption;version=[string]$os.Version;build=[string]$os.BuildNumber;architecture=[string]$os.OSArchitecture}
            powershell=[ordered]@{version=[string]$PSVersionTable.PSVersion;edition=[string]$PSVersionTable.PSEdition;apartment=[string][Threading.Thread]::CurrentThread.ApartmentState}
            process=[ordered]@{userInteractive=[Environment]::UserInteractive;sessionId=[int](Get-Process -Id $PID).SessionId;is64Bit=[Environment]::Is64BitProcess}
            adapters=$adapters
            privacy='Username/computer/profile/MAC omitted; IPv4 host octet masked.'
        }
        [IO.File]::WriteAllText((Join-Path $runDir 'machine-info.json'),($snap|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        Add-Result 'machine_snapshot' 'PASS' ("$($os.Caption) build $($os.BuildNumber); PS $($PSVersionTable.PSVersion)")
    }catch{Add-Result 'machine_snapshot' 'FAIL' $_.Exception.Message}
}
function Parser-Sweep{
    $files=@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $tests=Join-Path $root 'tests'
    if(Test-Path $tests){$files += @(Get-ChildItem -LiteralPath $tests -Filter '*.ps1' -File -ErrorAction SilentlyContinue)}
    $errs=New-Object System.Collections.Generic.List[string]
    foreach($f in $files){
        $tok=$null;$e=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tok,[ref]$e)
        foreach($x in @($e)){[void]$errs.Add(("{0}:{1}:{2} {3}" -f $f.Name,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message))}
    }
    if($errs.Count){$errs.ToArray()|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'FAIL' ("$($errs.Count) errors")}
    else{"Parsed $($files.Count) PowerShell files; errors=0"|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'PASS' ("$($files.Count) PowerShell files")}
}
function Finalize-Evidence{
    try{if($transcriptStarted){Stop-Transcript|Out-Null;$script:transcriptStarted=$false}}catch{}
    $summary=[ordered]@{
        schemaVersion=2;generatedAt=(Get-Date).ToString('o');mode=$Mode
        results=$results.ToArray()
        pass=@($results.ToArray()|Where-Object status -eq 'PASS').Count
        fail=@($results.ToArray()|Where-Object status -eq 'FAIL').Count
        skip=@($results.ToArray()|Where-Object status -eq 'SKIP').Count
    }
    [IO.File]::WriteAllText((Join-Path $runDir 'summary.json'),($summary|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    @("RF Network Tool Real-Machine Qualification","Mode: $Mode","PASS: $($summary.pass)","FAIL: $($summary.fail)","SKIP: $($summary.skip)","") + @($results.ToArray()|ForEach-Object{"$($_.status)	$($_.name)	$($_.detail)	$($_.elapsedMs)ms"}) | Set-Content (Join-Path $runDir 'SUMMARY.txt') -Encoding UTF8
    foreach($f in @(Get-ChildItem -LiteralPath $runDir -File -Recurse -ErrorAction SilentlyContinue)){
        if($f.Extension -in @('.txt','.log','.json','.md')){
            try{$raw=[IO.File]::ReadAllText($f.FullName);$safe=Sanitize-Text $raw;if($safe -ne $raw){[IO.File]::WriteAllText($f.FullName,$safe,(New-Object Text.UTF8Encoding($true)))}}catch{}
        }
    }
    if(-not $NoZip){
        New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
        $zip=Join-Path $OutputRoot ("RF-Network-Tool-REAL-MACHINE-LOGS-$stamp.zip")
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
        $hash=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($zip))"|Set-Content ($zip+'.sha256.txt') -Encoding ASCII
        Write-Host ''
        Write-Host 'UPLOAD THIS ZIP:' $zip -ForegroundColor Cyan
        Write-Host 'SHA256:' $hash -ForegroundColor Cyan
    }
}

try{
    try{Start-Transcript -LiteralPath $transcript -Force|Out-Null;$transcriptStarted=$true}catch{}
    Write-Host "Mode=$Mode InterfaceIndex=$InterfaceIndex Root=$root"
    Write-MachineInfo
    Parser-Sweep
    $tests=Join-Path $root 'tests'
    if(-not(Test-Path $tests)){Add-Result 'full_project_tests_present' 'FAIL' 'Use the FULL PROJECT package.'}
    else{
        Add-Result 'full_project_tests_present' 'PASS' 'tests directory available'
        Invoke-Step 'windows_integration' (Join-Path $tests 'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1') '' 180
        if(Ensure-PSScriptAnalyzer){Invoke-Step 'powershell_lint' (Join-Path $tests 'WINDOWS_LINT_GATE_v1_4_2.ps1') '' 180}
        else{Add-Result 'powershell_lint' 'SKIP' 'PSScriptAnalyzer 1.25.0 unavailable; GUI/FULL mode can install it.'}
        Invoke-Step 'chaos_recovery' (Join-Path $tests 'WINDOWS_CHAOS_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'synthetic_performance' (Join-Path $tests 'WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'launcher_diagnostic_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-DiagnosticOnly -TimeoutSec 20' 90
        if($Mode -in @('Gui','Full')){
            Invoke-Step 'interactive_preflight' (Join-Path $tests 'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1') '' 60
            Invoke-Step 'interactive_gui_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-TimeoutSec 30' 120
        }else{Add-Result 'interactive_gui_e2e' 'SKIP' 'SAFE mode'}
        if($Mode -eq 'Full'){
            $lanArgs='-Profiles FAST,BALANCED';if($InterfaceIndex -gt 0){$lanArgs+=" -InterfaceIndex $InterfaceIndex"}
            Invoke-Step 'real_lan_fast_balanced' (Join-Path $tests 'WINDOWS_REAL_LAN_TEST_v1_4_2.ps1') $lanArgs 360 @(3)
        }else{Add-Result 'real_lan_fast_balanced' 'SKIP' ("$Mode mode")}
    }
    if(Test-Path (Join-Path $root 'ci-artifacts')){Copy-Item (Join-Path $root 'ci-artifacts') (Join-Path $runDir 'ci-artifacts') -Recurse -Force}
    if(Test-Path (Join-Path $root 'logs')){Copy-Item (Join-Path $root 'logs') (Join-Path $runDir 'app-logs') -Recurse -Force}
}catch{Add-Result 'orchestrator' 'FAIL' $_.Exception.Message}
finally{Finalize-Evidence}
if(@($results.ToArray()|Where-Object status -eq 'FAIL').Count){exit 1}
exit 0
){$revision=$Matches[1].ToLowerInvariant();$evidence='root-folder-suffix'}
        }catch{}
    }
    return [pscustomobject]@{revision=$revision;evidence=$evidence}
}
function Record-SourceRevision{
    $src=Get-SourceRevisionEvidence
    if(-not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)){
        $expected=$ExpectedSourceRevision.Trim().ToLowerInvariant()
        if($expected -notmatch '^[0-9a-f]{40}
    if($null -eq $text){return ''}
    foreach($v in @(
        @([string]$env:USERPROFILE,'<USERPROFILE>'),
        @([string]$env:USERNAME,'<USERNAME>'),
        @([string]$env:COMPUTERNAME,'<COMPUTER>')
    )){
        if(-not [string]::IsNullOrWhiteSpace($v[0])){$text=$text.Replace($v[0],$v[1])}
    }
    return $text
}
function Get-CleanWindowsPowerShellModulePath{
    $paths=New-Object System.Collections.Generic.List[string]
    try{
        $docs=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if($docs){[void]$paths.Add((Join-Path $docs 'WindowsPowerShell\Modules'))}
    }catch{}
    if($env:ProgramFiles){[void]$paths.Add((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))}
    [void]$paths.Add((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'))
    return (($paths.ToArray()|Where-Object {$_}|Select-Object -Unique) -join ';')
}
function Read-TextFileWithRetry([string]$path,[int]$timeoutMs=10000){
    $sw=[Diagnostics.Stopwatch]::StartNew();$last=$null
    while($sw.ElapsedMilliseconds -lt $timeoutMs){
        try{return [IO.File]::ReadAllText($path)}catch{
            $last=$_
            if($_.Exception.InnerException -isnot [IO.IOException] -and $_.Exception -isnot [IO.IOException]){throw}
            Start-Sleep -Milliseconds 100
        }
    }
    if($last){throw $last}
    throw "Timed out reading $path"
}
function Start-CleanWindowsPowerShell([string]$argumentLine,[string]$stdoutPath='',[string]$stderrPath=''){
    $oldModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Process')
    try{
        $env:PSModulePath=Get-CleanWindowsPowerShellModulePath
        $params=@{FilePath=$psExe;ArgumentList=$argumentLine;WindowStyle='Hidden';PassThru=$true}
        if($stdoutPath){$params.RedirectStandardOutput=$stdoutPath}
        if($stderrPath){$params.RedirectStandardError=$stderrPath}
        return Start-Process @params
    }finally{
        if($null -eq $oldModulePath){Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue}
        else{$env:PSModulePath=$oldModulePath}
    }
}
function Test-PSScriptAnalyzerClean{
    $verify=Join-Path $runDir 'verify-psscriptanalyzer.ps1'
    @'
$m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
if($m){exit 0}
exit 1
'@ | Set-Content -LiteralPath $verify -Encoding UTF8
    $p=$null
    try{
        $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$verify`"")
        if(-not $p.WaitForExit(30000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            return $false
        }
        $p.Refresh();return ([int]$p.ExitCode -eq 0)
    }catch{return $false}
    finally{if($p){try{$p.Dispose()}catch{}}}
}
function Invoke-Step([string]$name,[string]$script,[string]$arguments='',[int]$timeoutSec=180,[int[]]$skipExitCodes=@()){
    if(-not(Test-Path -LiteralPath $script)){Add-Result $name 'FAIL' ("Missing: $script");return}
    $stdout=Join-Path $stepsDir ($name+'.stdout.txt')
    $stderr=Join-Path $stepsDir ($name+'.stderr.txt')
    $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if($arguments){$argLine+=" $arguments"}
    $sw=[Diagnostics.Stopwatch]::StartNew();$p=$null
    try{
        $p=Start-CleanWindowsPowerShell $argLine $stdout $stderr
        if(-not $p.WaitForExit($timeoutSec*1000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            try{$p.Dispose()}catch{};$p=$null
            $sw.Stop();Add-Result $name 'FAIL' ("timeout "+$timeoutSec+"s") $sw.ElapsedMilliseconds;return
        }
        $p.Refresh();$rc=[int]$p.ExitCode
        try{$p.Dispose()}catch{};$p=$null
        $sw.Stop()
        $stdoutText=if(Test-Path -LiteralPath $stdout){Read-TextFileWithRetry $stdout 10000}else{''}
        $selfReportedFail=($stdoutText -match '(?m)^FAIL(?:ED)?:?\s')
        if($skipExitCodes -contains $rc){Add-Result $name 'SKIP' ("exit $rc - not applicable") $sw.ElapsedMilliseconds}
        elseif($rc -eq 0 -and -not $selfReportedFail){Add-Result $name 'PASS' 'exit 0' $sw.ElapsedMilliseconds}
        elseif($selfReportedFail){Add-Result $name 'FAIL' ("child reported FAIL (exit $rc)") $sw.ElapsedMilliseconds}
        else{Add-Result $name 'FAIL' ("exit $rc") $sw.ElapsedMilliseconds}
    }catch{
        $sw.Stop()
        if($p){try{$p.Dispose()}catch{};$p=$null}
        $orchestratorError=Join-Path $stepsDir ($name+'.orchestrator-error.txt')
        try{($_|Out-String)|Set-Content -LiteralPath $orchestratorError -Encoding UTF8}catch{}
        Add-Result $name 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds
    }finally{if($p){try{$p.Dispose()}catch{}}}
}
function Ensure-PSScriptAnalyzer{
    if(Test-PSScriptAnalyzerClean){return $true}
    if(-not $AllowModuleInstall){return $false}
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $installer=Join-Path $runDir 'install-psscriptanalyzer.ps1'
    $stdout=Join-Path $stepsDir 'psscriptanalyzer_install.stdout.txt'
    $stderr=Join-Path $stepsDir 'psscriptanalyzer_install.stderr.txt'
    @'
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$oldPolicy=$null
try{
    try{
        $repo=Get-PSRepository -Name PSGallery -ErrorAction Stop
        $oldPolicy=[string]$repo.InstallationPolicy
        if($oldPolicy -ne 'Trusted'){Set-PSRepository -Name PSGallery -InstallationPolicy Trusted}
    }catch{}
    $nuget=Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $nuget -or $nuget.Version -lt [version]'2.8.5.201'){
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }
    $psg=Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $psg -or $psg.Version -lt [version]'2.2.5'){
        Install-Module -Name PowerShellGet -MinimumVersion 2.2.5 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        exit 42
    }
    Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
    $m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
    if(-not $m){throw 'PSScriptAnalyzer 1.25.0 was not found after installation.'}
    exit 0
}finally{
    if($oldPolicy -and $oldPolicy -ne 'Trusted'){try{Set-PSRepository -Name PSGallery -InstallationPolicy $oldPolicy}catch{}}
}
'@ | Set-Content -LiteralPath $installer -Encoding UTF8
    try{
        $attempt=0
        do{
            $attempt++
            if(Test-Path $stdout){Remove-Item $stdout -Force -ErrorAction SilentlyContinue}
            if(Test-Path $stderr){Remove-Item $stderr -Force -ErrorAction SilentlyContinue}
            $p=$null
            try{
                $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`"") $stdout $stderr
                if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};throw 'PSScriptAnalyzer installer timed out.'}
                $p.Refresh();$rc=[int]$p.ExitCode
            }finally{if($p){try{$p.Dispose()}catch{}}}
            if($rc -eq 42 -and $attempt -lt 3){continue}
            if($rc -ne 0){throw ("PSScriptAnalyzer installer exit "+$rc)}
            break
        }while($attempt -lt 3)
        $sw.Stop()
        if(Test-PSScriptAnalyzerClean){Add-Result 'psscriptanalyzer_install' 'PASS' 'PSScriptAnalyzer 1.25.0 available via clean Windows PowerShell module path' $sw.ElapsedMilliseconds;return $true}
        $diag=Join-Path $stepsDir 'psscriptanalyzer_install_diagnostics.txt'
        try{
            @(
                ('CleanPSModulePath='+(Get-CleanWindowsPowerShellModulePath)),
                ('MyDocuments='+[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)),
                ('ProgramFiles='+$env:ProgramFiles),
                ('SystemRoot='+$env:SystemRoot)
            )|Set-Content -LiteralPath $diag -Encoding UTF8
        }catch{}
        Add-Result 'psscriptanalyzer_install' 'FAIL' 'Installer completed but PSScriptAnalyzer 1.25.0 is unavailable.' $sw.ElapsedMilliseconds
        return $false
    }catch{
        $sw.Stop();Add-Result 'psscriptanalyzer_install' 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds;return $false
    }
}
function Write-MachineInfo{
    try{
        $os=Get-CimInstance Win32_OperatingSystem
        $adapters=@()
        foreach($a in @(Get-NetAdapter -ErrorAction SilentlyContinue|Sort-Object ifIndex)){
            $ips=@()
            foreach($ip in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)){
                if($ip.IPAddress){$ips += [pscustomobject]@{address=(Mask-IPv4 ([string]$ip.IPAddress));prefixLength=[int]$ip.PrefixLength;state=[string]$ip.AddressState}}
            }
            $adapters += [pscustomobject]@{ifIndex=[int]$a.ifIndex;name=[string]$a.Name;description=[string]$a.InterfaceDescription;status=[string]$a.Status;hardwareInterface=[bool]$a.HardwareInterface;ipv4=$ips}
        }
        $snap=[ordered]@{
            schemaVersion=2;capturedAt=(Get-Date).ToString('o');mode=$Mode
            os=[ordered]@{caption=[string]$os.Caption;version=[string]$os.Version;build=[string]$os.BuildNumber;architecture=[string]$os.OSArchitecture}
            powershell=[ordered]@{version=[string]$PSVersionTable.PSVersion;edition=[string]$PSVersionTable.PSEdition;apartment=[string][Threading.Thread]::CurrentThread.ApartmentState}
            process=[ordered]@{userInteractive=[Environment]::UserInteractive;sessionId=[int](Get-Process -Id $PID).SessionId;is64Bit=[Environment]::Is64BitProcess}
            adapters=$adapters
            privacy='Username/computer/profile/MAC omitted; IPv4 host octet masked.'
        }
        [IO.File]::WriteAllText((Join-Path $runDir 'machine-info.json'),($snap|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        Add-Result 'machine_snapshot' 'PASS' ("$($os.Caption) build $($os.BuildNumber); PS $($PSVersionTable.PSVersion)")
    }catch{Add-Result 'machine_snapshot' 'FAIL' $_.Exception.Message}
}
function Parser-Sweep{
    $files=@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $tests=Join-Path $root 'tests'
    if(Test-Path $tests){$files += @(Get-ChildItem -LiteralPath $tests -Filter '*.ps1' -File -ErrorAction SilentlyContinue)}
    $errs=New-Object System.Collections.Generic.List[string]
    foreach($f in $files){
        $tok=$null;$e=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tok,[ref]$e)
        foreach($x in @($e)){[void]$errs.Add(("{0}:{1}:{2} {3}" -f $f.Name,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message))}
    }
    if($errs.Count){$errs.ToArray()|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'FAIL' ("$($errs.Count) errors")}
    else{"Parsed $($files.Count) PowerShell files; errors=0"|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'PASS' ("$($files.Count) PowerShell files")}
}
function Finalize-Evidence{
    try{if($transcriptStarted){Stop-Transcript|Out-Null;$script:transcriptStarted=$false}}catch{}
    $summary=[ordered]@{
        schemaVersion=2;generatedAt=(Get-Date).ToString('o');mode=$Mode
        results=$results.ToArray()
        pass=@($results.ToArray()|Where-Object status -eq 'PASS').Count
        fail=@($results.ToArray()|Where-Object status -eq 'FAIL').Count
        skip=@($results.ToArray()|Where-Object status -eq 'SKIP').Count
    }
    [IO.File]::WriteAllText((Join-Path $runDir 'summary.json'),($summary|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    @("RF Network Tool Real-Machine Qualification","Mode: $Mode","PASS: $($summary.pass)","FAIL: $($summary.fail)","SKIP: $($summary.skip)","") + @($results.ToArray()|ForEach-Object{"$($_.status)	$($_.name)	$($_.detail)	$($_.elapsedMs)ms"}) | Set-Content (Join-Path $runDir 'SUMMARY.txt') -Encoding UTF8
    foreach($f in @(Get-ChildItem -LiteralPath $runDir -File -Recurse -ErrorAction SilentlyContinue)){
        if($f.Extension -in @('.txt','.log','.json','.md')){
            try{$raw=[IO.File]::ReadAllText($f.FullName);$safe=Sanitize-Text $raw;if($safe -ne $raw){[IO.File]::WriteAllText($f.FullName,$safe,(New-Object Text.UTF8Encoding($true)))}}catch{}
        }
    }
    if(-not $NoZip){
        New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
        $zip=Join-Path $OutputRoot ("RF-Network-Tool-REAL-MACHINE-LOGS-$stamp.zip")
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
        $hash=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($zip))"|Set-Content ($zip+'.sha256.txt') -Encoding ASCII
        Write-Host ''
        Write-Host 'UPLOAD THIS ZIP:' $zip -ForegroundColor Cyan
        Write-Host 'SHA256:' $hash -ForegroundColor Cyan
    }
}

try{
    try{Start-Transcript -LiteralPath $transcript -Force|Out-Null;$transcriptStarted=$true}catch{}
    Write-Host "Mode=$Mode InterfaceIndex=$InterfaceIndex Root=$root"
    Write-MachineInfo
    Parser-Sweep
    $tests=Join-Path $root 'tests'
    if(-not(Test-Path $tests)){Add-Result 'full_project_tests_present' 'FAIL' 'Use the FULL PROJECT package.'}
    else{
        Add-Result 'full_project_tests_present' 'PASS' 'tests directory available'
        Invoke-Step 'windows_integration' (Join-Path $tests 'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1') '' 180
        if(Ensure-PSScriptAnalyzer){Invoke-Step 'powershell_lint' (Join-Path $tests 'WINDOWS_LINT_GATE_v1_4_2.ps1') '' 180}
        else{Add-Result 'powershell_lint' 'SKIP' 'PSScriptAnalyzer 1.25.0 unavailable; GUI/FULL mode can install it.'}
        Invoke-Step 'chaos_recovery' (Join-Path $tests 'WINDOWS_CHAOS_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'synthetic_performance' (Join-Path $tests 'WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'launcher_diagnostic_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-DiagnosticOnly -TimeoutSec 20' 90
        if($Mode -in @('Gui','Full')){
            Invoke-Step 'interactive_preflight' (Join-Path $tests 'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1') '' 60
            Invoke-Step 'interactive_gui_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-TimeoutSec 30' 120
        }else{Add-Result 'interactive_gui_e2e' 'SKIP' 'SAFE mode'}
        if($Mode -eq 'Full'){
            $lanArgs='-Profiles FAST,BALANCED';if($InterfaceIndex -gt 0){$lanArgs+=" -InterfaceIndex $InterfaceIndex"}
            Invoke-Step 'real_lan_fast_balanced' (Join-Path $tests 'WINDOWS_REAL_LAN_TEST_v1_4_2.ps1') $lanArgs 360 @(3)
        }else{Add-Result 'real_lan_fast_balanced' 'SKIP' ("$Mode mode")}
    }
    if(Test-Path (Join-Path $root 'ci-artifacts')){Copy-Item (Join-Path $root 'ci-artifacts') (Join-Path $runDir 'ci-artifacts') -Recurse -Force}
    if(Test-Path (Join-Path $root 'logs')){Copy-Item (Join-Path $root 'logs') (Join-Path $runDir 'app-logs') -Recurse -Force}
}catch{Add-Result 'orchestrator' 'FAIL' $_.Exception.Message}
finally{Finalize-Evidence}
if(@($results.ToArray()|Where-Object status -eq 'FAIL').Count){exit 1}
exit 0
){Add-Result 'source_revision' 'FAIL' 'ExpectedSourceRevision must be an exact 40-character SHA.';return}
        if(-not $src.revision){Add-Result 'source_revision' 'FAIL' 'Could not determine source revision for exact-head qualification.';return}
        if($src.revision -ne $expected){Add-Result 'source_revision' 'FAIL' ("revision mismatch actual="+$src.revision+" expected="+$expected);return}
        Add-Result 'source_revision' 'PASS' ($src.revision+" via "+$src.evidence);return
    }
    if($src.revision){Add-Result 'source_revision' 'PASS' ($src.revision+" via "+$src.evidence)}
    else{Add-Result 'source_revision' 'SKIP' 'source revision unavailable; pass ExpectedSourceRevision for exact-head qualification'}
}
function Sanitize-Text([string]$text){
    if($null -eq $text){return ''}
    foreach($v in @(
        @([string]$env:USERPROFILE,'<USERPROFILE>'),
        @([string]$env:USERNAME,'<USERNAME>'),
        @([string]$env:COMPUTERNAME,'<COMPUTER>')
    )){
        if(-not [string]::IsNullOrWhiteSpace($v[0])){$text=$text.Replace($v[0],$v[1])}
    }
    return $text
}
function Get-CleanWindowsPowerShellModulePath{
    $paths=New-Object System.Collections.Generic.List[string]
    try{
        $docs=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if($docs){[void]$paths.Add((Join-Path $docs 'WindowsPowerShell\Modules'))}
    }catch{}
    if($env:ProgramFiles){[void]$paths.Add((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))}
    [void]$paths.Add((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'))
    return (($paths.ToArray()|Where-Object {$_}|Select-Object -Unique) -join ';')
}
function Read-TextFileWithRetry([string]$path,[int]$timeoutMs=10000){
    $sw=[Diagnostics.Stopwatch]::StartNew();$last=$null
    while($sw.ElapsedMilliseconds -lt $timeoutMs){
        try{return [IO.File]::ReadAllText($path)}catch{
            $last=$_
            if($_.Exception.InnerException -isnot [IO.IOException] -and $_.Exception -isnot [IO.IOException]){throw}
            Start-Sleep -Milliseconds 100
        }
    }
    if($last){throw $last}
    throw "Timed out reading $path"
}
function Start-CleanWindowsPowerShell([string]$argumentLine,[string]$stdoutPath='',[string]$stderrPath=''){
    $oldModulePath=[Environment]::GetEnvironmentVariable('PSModulePath','Process')
    try{
        $env:PSModulePath=Get-CleanWindowsPowerShellModulePath
        $params=@{FilePath=$psExe;ArgumentList=$argumentLine;WindowStyle='Hidden';PassThru=$true}
        if($stdoutPath){$params.RedirectStandardOutput=$stdoutPath}
        if($stderrPath){$params.RedirectStandardError=$stderrPath}
        return Start-Process @params
    }finally{
        if($null -eq $oldModulePath){Remove-Item Env:PSModulePath -ErrorAction SilentlyContinue}
        else{$env:PSModulePath=$oldModulePath}
    }
}
function Test-PSScriptAnalyzerClean{
    $verify=Join-Path $runDir 'verify-psscriptanalyzer.ps1'
    @'
$m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
if($m){exit 0}
exit 1
'@ | Set-Content -LiteralPath $verify -Encoding UTF8
    $p=$null
    try{
        $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$verify`"")
        if(-not $p.WaitForExit(30000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            return $false
        }
        $p.Refresh();return ([int]$p.ExitCode -eq 0)
    }catch{return $false}
    finally{if($p){try{$p.Dispose()}catch{}}}
}
function Invoke-Step([string]$name,[string]$script,[string]$arguments='',[int]$timeoutSec=180,[int[]]$skipExitCodes=@()){
    if(-not(Test-Path -LiteralPath $script)){Add-Result $name 'FAIL' ("Missing: $script");return}
    $stdout=Join-Path $stepsDir ($name+'.stdout.txt')
    $stderr=Join-Path $stepsDir ($name+'.stderr.txt')
    $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if($arguments){$argLine+=" $arguments"}
    $sw=[Diagnostics.Stopwatch]::StartNew();$p=$null
    try{
        $p=Start-CleanWindowsPowerShell $argLine $stdout $stderr
        if(-not $p.WaitForExit($timeoutSec*1000)){
            try{$p.Kill()}catch{}
            try{[void]$p.WaitForExit(5000)}catch{}
            try{$p.Dispose()}catch{};$p=$null
            $sw.Stop();Add-Result $name 'FAIL' ("timeout "+$timeoutSec+"s") $sw.ElapsedMilliseconds;return
        }
        $p.Refresh();$rc=[int]$p.ExitCode
        try{$p.Dispose()}catch{};$p=$null
        $sw.Stop()
        $stdoutText=if(Test-Path -LiteralPath $stdout){Read-TextFileWithRetry $stdout 10000}else{''}
        $selfReportedFail=($stdoutText -match '(?m)^FAIL(?:ED)?:?\s')
        if($skipExitCodes -contains $rc){Add-Result $name 'SKIP' ("exit $rc - not applicable") $sw.ElapsedMilliseconds}
        elseif($rc -eq 0 -and -not $selfReportedFail){Add-Result $name 'PASS' 'exit 0' $sw.ElapsedMilliseconds}
        elseif($selfReportedFail){Add-Result $name 'FAIL' ("child reported FAIL (exit $rc)") $sw.ElapsedMilliseconds}
        else{Add-Result $name 'FAIL' ("exit $rc") $sw.ElapsedMilliseconds}
    }catch{
        $sw.Stop()
        if($p){try{$p.Dispose()}catch{};$p=$null}
        $orchestratorError=Join-Path $stepsDir ($name+'.orchestrator-error.txt')
        try{($_|Out-String)|Set-Content -LiteralPath $orchestratorError -Encoding UTF8}catch{}
        Add-Result $name 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds
    }finally{if($p){try{$p.Dispose()}catch{}}}
}
function Ensure-PSScriptAnalyzer{
    if(Test-PSScriptAnalyzerClean){return $true}
    if(-not $AllowModuleInstall){return $false}
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $installer=Join-Path $runDir 'install-psscriptanalyzer.ps1'
    $stdout=Join-Path $stepsDir 'psscriptanalyzer_install.stdout.txt'
    $stderr=Join-Path $stepsDir 'psscriptanalyzer_install.stderr.txt'
    @'
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$oldPolicy=$null
try{
    try{
        $repo=Get-PSRepository -Name PSGallery -ErrorAction Stop
        $oldPolicy=[string]$repo.InstallationPolicy
        if($oldPolicy -ne 'Trusted'){Set-PSRepository -Name PSGallery -InstallationPolicy Trusted}
    }catch{}
    $nuget=Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $nuget -or $nuget.Version -lt [version]'2.8.5.201'){
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }
    $psg=Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $psg -or $psg.Version -lt [version]'2.2.5'){
        Install-Module -Name PowerShellGet -MinimumVersion 2.2.5 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        exit 42
    }
    Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
    $m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
    if(-not $m){throw 'PSScriptAnalyzer 1.25.0 was not found after installation.'}
    exit 0
}finally{
    if($oldPolicy -and $oldPolicy -ne 'Trusted'){try{Set-PSRepository -Name PSGallery -InstallationPolicy $oldPolicy}catch{}}
}
'@ | Set-Content -LiteralPath $installer -Encoding UTF8
    try{
        $attempt=0
        do{
            $attempt++
            if(Test-Path $stdout){Remove-Item $stdout -Force -ErrorAction SilentlyContinue}
            if(Test-Path $stderr){Remove-Item $stderr -Force -ErrorAction SilentlyContinue}
            $p=$null
            try{
                $p=Start-CleanWindowsPowerShell ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`"") $stdout $stderr
                if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};throw 'PSScriptAnalyzer installer timed out.'}
                $p.Refresh();$rc=[int]$p.ExitCode
            }finally{if($p){try{$p.Dispose()}catch{}}}
            if($rc -eq 42 -and $attempt -lt 3){continue}
            if($rc -ne 0){throw ("PSScriptAnalyzer installer exit "+$rc)}
            break
        }while($attempt -lt 3)
        $sw.Stop()
        if(Test-PSScriptAnalyzerClean){Add-Result 'psscriptanalyzer_install' 'PASS' 'PSScriptAnalyzer 1.25.0 available via clean Windows PowerShell module path' $sw.ElapsedMilliseconds;return $true}
        $diag=Join-Path $stepsDir 'psscriptanalyzer_install_diagnostics.txt'
        try{
            @(
                ('CleanPSModulePath='+(Get-CleanWindowsPowerShellModulePath)),
                ('MyDocuments='+[Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)),
                ('ProgramFiles='+$env:ProgramFiles),
                ('SystemRoot='+$env:SystemRoot)
            )|Set-Content -LiteralPath $diag -Encoding UTF8
        }catch{}
        Add-Result 'psscriptanalyzer_install' 'FAIL' 'Installer completed but PSScriptAnalyzer 1.25.0 is unavailable.' $sw.ElapsedMilliseconds
        return $false
    }catch{
        $sw.Stop();Add-Result 'psscriptanalyzer_install' 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds;return $false
    }
}
function Write-MachineInfo{
    try{
        $os=Get-CimInstance Win32_OperatingSystem
        $adapters=@()
        foreach($a in @(Get-NetAdapter -ErrorAction SilentlyContinue|Sort-Object ifIndex)){
            $ips=@()
            foreach($ip in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)){
                if($ip.IPAddress){$ips += [pscustomobject]@{address=(Mask-IPv4 ([string]$ip.IPAddress));prefixLength=[int]$ip.PrefixLength;state=[string]$ip.AddressState}}
            }
            $adapters += [pscustomobject]@{ifIndex=[int]$a.ifIndex;name=[string]$a.Name;description=[string]$a.InterfaceDescription;status=[string]$a.Status;hardwareInterface=[bool]$a.HardwareInterface;ipv4=$ips}
        }
        $snap=[ordered]@{
            schemaVersion=2;capturedAt=(Get-Date).ToString('o');mode=$Mode
            os=[ordered]@{caption=[string]$os.Caption;version=[string]$os.Version;build=[string]$os.BuildNumber;architecture=[string]$os.OSArchitecture}
            powershell=[ordered]@{version=[string]$PSVersionTable.PSVersion;edition=[string]$PSVersionTable.PSEdition;apartment=[string][Threading.Thread]::CurrentThread.ApartmentState}
            process=[ordered]@{userInteractive=[Environment]::UserInteractive;sessionId=[int](Get-Process -Id $PID).SessionId;is64Bit=[Environment]::Is64BitProcess}
            adapters=$adapters
            privacy='Username/computer/profile/MAC omitted; IPv4 host octet masked.'
        }
        [IO.File]::WriteAllText((Join-Path $runDir 'machine-info.json'),($snap|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        Add-Result 'machine_snapshot' 'PASS' ("$($os.Caption) build $($os.BuildNumber); PS $($PSVersionTable.PSVersion)")
    }catch{Add-Result 'machine_snapshot' 'FAIL' $_.Exception.Message}
}
function Parser-Sweep{
    $files=@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $tests=Join-Path $root 'tests'
    if(Test-Path $tests){$files += @(Get-ChildItem -LiteralPath $tests -Filter '*.ps1' -File -ErrorAction SilentlyContinue)}
    $errs=New-Object System.Collections.Generic.List[string]
    foreach($f in $files){
        $tok=$null;$e=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tok,[ref]$e)
        foreach($x in @($e)){[void]$errs.Add(("{0}:{1}:{2} {3}" -f $f.Name,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message))}
    }
    if($errs.Count){$errs.ToArray()|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'FAIL' ("$($errs.Count) errors")}
    else{"Parsed $($files.Count) PowerShell files; errors=0"|Set-Content (Join-Path $runDir 'parser-sweep.txt') -Encoding UTF8;Add-Result 'parser_sweep' 'PASS' ("$($files.Count) PowerShell files")}
}
function Finalize-Evidence{
    try{if($transcriptStarted){Stop-Transcript|Out-Null;$script:transcriptStarted=$false}}catch{}
    $summary=[ordered]@{
        schemaVersion=2;generatedAt=(Get-Date).ToString('o');mode=$Mode
        results=$results.ToArray()
        pass=@($results.ToArray()|Where-Object status -eq 'PASS').Count
        fail=@($results.ToArray()|Where-Object status -eq 'FAIL').Count
        skip=@($results.ToArray()|Where-Object status -eq 'SKIP').Count
    }
    [IO.File]::WriteAllText((Join-Path $runDir 'summary.json'),($summary|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    @("RF Network Tool Real-Machine Qualification","Mode: $Mode","PASS: $($summary.pass)","FAIL: $($summary.fail)","SKIP: $($summary.skip)","") + @($results.ToArray()|ForEach-Object{"$($_.status)	$($_.name)	$($_.detail)	$($_.elapsedMs)ms"}) | Set-Content (Join-Path $runDir 'SUMMARY.txt') -Encoding UTF8
    foreach($f in @(Get-ChildItem -LiteralPath $runDir -File -Recurse -ErrorAction SilentlyContinue)){
        if($f.Extension -in @('.txt','.log','.json','.md')){
            try{$raw=[IO.File]::ReadAllText($f.FullName);$safe=Sanitize-Text $raw;if($safe -ne $raw){[IO.File]::WriteAllText($f.FullName,$safe,(New-Object Text.UTF8Encoding($true)))}}catch{}
        }
    }
    if(-not $NoZip){
        New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
        $zip=Join-Path $OutputRoot ("RF-Network-Tool-REAL-MACHINE-LOGS-$stamp.zip")
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
        $hash=(Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($zip))"|Set-Content ($zip+'.sha256.txt') -Encoding ASCII
        Write-Host ''
        Write-Host 'UPLOAD THIS ZIP:' $zip -ForegroundColor Cyan
        Write-Host 'SHA256:' $hash -ForegroundColor Cyan
    }
}

try{
    try{Start-Transcript -LiteralPath $transcript -Force|Out-Null;$transcriptStarted=$true}catch{}
    Write-Host "Mode=$Mode InterfaceIndex=$InterfaceIndex Root=$root"
    Write-MachineInfo
    Parser-Sweep
    $tests=Join-Path $root 'tests'
    if(-not(Test-Path $tests)){Add-Result 'full_project_tests_present' 'FAIL' 'Use the FULL PROJECT package.'}
    else{
        Add-Result 'full_project_tests_present' 'PASS' 'tests directory available'
        Invoke-Step 'windows_integration' (Join-Path $tests 'WINDOWS_INTEGRATION_TEST_v1_4_2.ps1') '' 180
        if(Ensure-PSScriptAnalyzer){Invoke-Step 'powershell_lint' (Join-Path $tests 'WINDOWS_LINT_GATE_v1_4_2.ps1') '' 180}
        else{Add-Result 'powershell_lint' 'SKIP' 'PSScriptAnalyzer 1.25.0 unavailable; GUI/FULL mode can install it.'}
        Invoke-Step 'chaos_recovery' (Join-Path $tests 'WINDOWS_CHAOS_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'synthetic_performance' (Join-Path $tests 'WINDOWS_PERFORMANCE_TEST_v1_4_2.ps1') '' 180
        Invoke-Step 'launcher_diagnostic_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-DiagnosticOnly -TimeoutSec 20' 90
        if($Mode -in @('Gui','Full')){
            Invoke-Step 'interactive_preflight' (Join-Path $tests 'WINDOWS_INTERACTIVE_PREFLIGHT_v1_4_2.ps1') '' 60
            Invoke-Step 'interactive_gui_e2e' (Join-Path $tests 'WINDOWS_LAUNCHER_E2E_v1_4_2.ps1') '-TimeoutSec 30' 120
        }else{Add-Result 'interactive_gui_e2e' 'SKIP' 'SAFE mode'}
        if($Mode -eq 'Full'){
            $lanArgs='-Profiles FAST,BALANCED';if($InterfaceIndex -gt 0){$lanArgs+=" -InterfaceIndex $InterfaceIndex"}
            Invoke-Step 'real_lan_fast_balanced' (Join-Path $tests 'WINDOWS_REAL_LAN_TEST_v1_4_2.ps1') $lanArgs 360 @(3)
        }else{Add-Result 'real_lan_fast_balanced' 'SKIP' ("$Mode mode")}
    }
    if(Test-Path (Join-Path $root 'ci-artifacts')){Copy-Item (Join-Path $root 'ci-artifacts') (Join-Path $runDir 'ci-artifacts') -Recurse -Force}
    if(Test-Path (Join-Path $root 'logs')){Copy-Item (Join-Path $root 'logs') (Join-Path $runDir 'app-logs') -Recurse -Force}
}catch{Add-Result 'orchestrator' 'FAIL' $_.Exception.Message}
finally{Finalize-Evidence}
if(@($results.ToArray()|Where-Object status -eq 'FAIL').Count){exit 1}
exit 0
