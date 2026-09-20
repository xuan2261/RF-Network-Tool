[CmdletBinding()]
param(
    [ValidateSet('Safe','Gui','Full')][string]$Mode='Safe',
    [int]$InterfaceIndex=0,
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
function Invoke-Step([string]$name,[string]$script,[string]$arguments='',[int]$timeoutSec=180,[int[]]$skipExitCodes=@()){
    if(-not(Test-Path -LiteralPath $script)){Add-Result $name 'FAIL' ("Missing: $script");return}
    $stdout=Join-Path $stepsDir ($name+'.stdout.txt')
    $stderr=Join-Path $stepsDir ($name+'.stderr.txt')
    $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if($arguments){$argLine+=" $arguments"}
    $sw=[Diagnostics.Stopwatch]::StartNew();$p=$null
    try{
        $p=Start-Process -FilePath $psExe -ArgumentList $argLine -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
        if(-not $p.WaitForExit($timeoutSec*1000)){
            try{$p.Kill()}catch{}
            $sw.Stop();Add-Result $name 'FAIL' ("timeout "+$timeoutSec+"s") $sw.ElapsedMilliseconds;return
        }
        $p.Refresh();$rc=[int]$p.ExitCode;$sw.Stop()
        if($rc -eq 0){Add-Result $name 'PASS' 'exit 0' $sw.ElapsedMilliseconds}
        elseif($skipExitCodes -contains $rc){Add-Result $name 'SKIP' ("exit $rc - not applicable") $sw.ElapsedMilliseconds}
        else{Add-Result $name 'FAIL' ("exit $rc") $sw.ElapsedMilliseconds}
    }catch{
        $sw.Stop();($_|Out-String)|Set-Content -LiteralPath $stderr -Encoding UTF8
        Add-Result $name 'FAIL' $_.Exception.Message $sw.ElapsedMilliseconds
    }finally{if($p){try{$p.Dispose()}catch{}}}
}
function Ensure-PSScriptAnalyzer{
    $m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
    if($m){return $true}
    if(-not $AllowModuleInstall){return $false}
    $sw=[Diagnostics.Stopwatch]::StartNew()
    try{
        [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        $m=Get-Module -ListAvailable PSScriptAnalyzer | Where-Object {$_.Version -eq [version]'1.25.0'} | Select-Object -First 1
        $sw.Stop()
        if($m){Add-Result 'psscriptanalyzer_install' 'PASS' '1.25.0 available' $sw.ElapsedMilliseconds;return $true}
        Add-Result 'psscriptanalyzer_install' 'FAIL' '1.25.0 still unavailable' $sw.ElapsedMilliseconds;return $false
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
