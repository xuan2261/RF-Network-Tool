from pathlib import Path, PurePosixPath
import base64, hashlib, json, lzma, os, sys, urllib.request, subprocess
root=Path.cwd()
raw=lzma.decompress(base64.b64decode(''.join((root/'.rft-preflight'/('part-%d.b64'%i)).read_text().strip() for i in range(3))))
assert hashlib.sha256(raw).hexdigest()=='96ed2c6ecafc5c6df89842da7d48eb0f5c4c1c5fb0d9eda9dc64eabc53e2f639'
recipe=json.loads(raw)
fixups=json.loads(r'''[{"path":"RF-Network-Tool-DiscoveryWorker.ps1","before":"4380b2353264adee30aa5799d9ff66676b2c10f906eec58071fc54514653bfd0","after":"82bdcfcdef9d832d11293b9b2fdbd5ff536c102fb908cb1d6893c92e8c184bb6","replacements":[["    $tmp=$ResultFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'\n    try {","    $tmp=$ResultFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'\n    $backup=$tmp+'.previous'\n    try {"],["        if(Test-Path -LiteralPath $ResultFile){[IO.File]::Replace($tmp,$ResultFile,$null)}\n        else{[IO.File]::Move($tmp,$ResultFile)}\n    } finally {if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}","        # Use an explicit unique backup path: Windows PowerShell may bind $null as an empty string.\n        if(Test-Path -LiteralPath $ResultFile){[IO.File]::Replace($tmp,$ResultFile,$backup)}\n        else{[IO.File]::Move($tmp,$ResultFile)}\n    } finally {\n        foreach($path in @($tmp,$backup)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}\n    }"]]},{"path":"RF-Network-Tool-Portable.ps1","before":"157f76eaa34ab850574be9548ae07b15fe5b4545de714cf9db54b64f652498b7","after":"973dcae9873284a973b1f69e537a59cfcf1a1dffd67b2a8fbce0fc6c406cded6","replacements":[["    if(-not $result){return 'ERROR: missing terminal evidence'}\n    if([string]$result.sessionId","    if(-not $result){return 'ERROR: missing terminal evidence'}\n    if($result.schemaVersion -isnot [int] -and $result.schemaVersion -isnot [long]){return 'ERROR: invalid terminal schema'}\n    if($result.schemaVersion -ne 1){return 'ERROR: unsupported terminal schema'}\n    if([string]$result.sessionId"],["    if([string]$result.status -eq 'CANCELLED'){return 'CANCELLED'}","    if([string]$result.status -eq 'CANCELLED'){\n        if($exitCode -eq 3 -and $result.completedWindow -is [bool] -and -not $result.completedWindow){return 'CANCELLED'}\n        return 'ERROR: contradictory cancellation evidence'\n    }"],["        if($due.Count -gt 0){[void](Enqueue-PingRequest 'MONITOR' $due.ToArray() 1200 24)}","        if($due.Count -gt 0){\n            try {[void](Enqueue-PingRequest 'MONITOR' $due.ToArray() 1200 24)}\n            catch {\n                $queueError=$_.Exception.Message\n                foreach($entry in $due){Set-MonitorMeasurementError -target ([string]$entry.Target) -message $queueError}\n                Write-RuntimeLog 'MONITOR-QUEUE' $queueError\n            }\n        }"]]},{"path":"tests/WINDOWS_MEASUREMENT_TEST_v1_5_3.ps1","before":"d3a2bd047498e6dc00787c3ec3b40cb843b779dc5cb3fb59405386663ef029cb","after":"026037a85c4c249fb5f376358a0ae66516d78a7950519a6e8915f55a27ee66b4","replacements":[["'Get-MonitorGridRow','Refresh-MonitorSummary')","'Get-MonitorGridRow','Refresh-MonitorSummary','Invoke-MonitorScheduler')"],["        Check 'sequence_accounting' ($st.UptimeSec -eq 10 -and $st.DowntimeSec -eq 5)","        Check 'sequence_accounting' ($st.UptimeSec -eq 10 -and $st.DowntimeSec -eq 5)\n        $accounted=$st.AccountingMono;$storedUp=$st.UptimeSec;Tick 2\n        [void](Get-MonitorDisplayedUptime $st);[void](Get-MonitorDisplayedDowntime $st)\n        Check 'display_projection_does_not_mutate_accounting' ($st.AccountingMono -eq $accounted -and $st.UptimeSec -eq $storedUp)"],["        Check 'discovery_complete' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -eq 'SUCCESS')","        Check 'discovery_complete' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -eq 'SUCCESS')\n        $ok.schemaVersion=2\n        Check 'discovery_unknown_schema_rejected' ((Get-DiscoveryTerminalOutcome $ok 0 's' 'r' 45) -like 'ERROR:*')\n        $ok.schemaVersion=1\n        $cancelled=[pscustomobject]@{schemaVersion=1;sessionId='s';runId='r';status='CANCELLED';completedWindow=$false}\n        Check 'discovery_cancel_distinct' ((Get-DiscoveryTerminalOutcome $cancelled 3 's' 'r' 45) -eq 'CANCELLED')\n        Check 'discovery_cancel_contradiction' ((Get-DiscoveryTerminalOutcome $cancelled 0 's' 'r' 45) -like 'ERROR:*')"],["        Check 'summary_excludes_engine_error' ($lblMonitorSummary.Text -like '*Online 0*' -and $lblMonitorSummary.ForeColor -eq [Drawing.Color]::DarkOrange)","        Check 'summary_excludes_engine_error' ($lblMonitorSummary.Text -like '*Online 0*' -and $lblMonitorSummary.ForeColor -eq [Drawing.Color]::DarkOrange)\n        Fresh;Sample $true 5;Tick\n        function Enqueue-PingRequest {throw 'Fixture local startup failure'}\n        $script:MonitoringSchedulerBusy=$false;$script:MonitoringLastUiRefresh=$null\n        Invoke-MonitorScheduler\n        Check 'queue_failure_is_collector_error' ($script:MonitoringStats['192.0.2.1'].TotalCount -eq 1 -and $script:MonitoringStats['192.0.2.1'].FailureCount -eq 0 -and (Get-MonitorHealth $script:MonitoringStats['192.0.2.1'] $script:MonitoringConfig['192.0.2.1']) -eq 'ENGINE ERROR')"]]},{"path":"tests/WINDOWS_INTEGRATION_TEST_v1_4_2.ps1","before":"ec0dda445509d3f1a10dcc2928b797c768f94a365bfcef57bc68d7f0cd564b7e","after":"bc930c879c4e7bb945bd7be16cde1ff6b18b36c4486b592f5568b4acee310f6a","replacements":[["  Assert-True ([string]$cancelTerminal.status -eq 'CANCELLED' -and -not [bool]$cancelTerminal.completedWindow) 'Discovery cancellation terminal'","  Assert-True ([string]$cancelTerminal.status -eq 'CANCELLED' -and -not [bool]$cancelTerminal.completedWindow -and [string]$cancelTerminal.runId -eq 'cancelled') 'Discovery cancellation terminal'\n  Write-Host ('Discovery overwrite result: exit={0}; status={1}; run={2}' -f $cancelRc,$cancelTerminal.status,$cancelTerminal.runId)\n  Assert-True (@(Get-ChildItem -LiteralPath $tmp -Filter '*.previous').Count -eq 0) 'Discovery terminal replacement leaves no backup file'"]]}]''')
fixmap={item['path']:item for item in fixups}
mode=sys.argv[1]
assert mode in ('prepare','apply','publish')
changes=[]
def diagnose_terminal(data):
    import tempfile
    with tempfile.TemporaryDirectory(prefix='rft-terminal-diagnostic-') as folder:
        source=Path(folder)/'prior-worker.ps1';source.write_bytes(data)
        probe=Path(folder)/'probe.ps1'
        probe.write_text(r'''param([string]$SourceFile)
$ErrorActionPreference='Stop'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($SourceFile,[ref]$t,[ref]$e)
if($e.Count){throw 'Diagnostic source parse failed'}
$node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object {$_.Name -eq 'Write-DiscoveryTerminal'})[0]
. ([scriptblock]::Create($node.Extent.Text))
$ResultFile=Join-Path $PSScriptRoot 'terminal.json'
Write-DiscoveryTerminal @{status='ERROR'}
try {Write-DiscoveryTerminal @{status='CANCELLED'};Write-Host 'DIAGNOSTIC: original terminal overwrite succeeded'}
catch {Write-Host ('DIAGNOSTIC: original terminal overwrite failed: '+$_.Exception.GetBaseException().Message)}
''',encoding='utf-8-sig')
        command=[str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(probe),str(source)]
        result=subprocess.run(command,capture_output=True,timeout=30)
        print(result.stdout.decode('utf-8',errors='replace'))
        if result.returncode:raise RuntimeError(result.stderr.decode('utf-8',errors='replace'))
for item in recipe['files']:
    name=item['path'];rel=PurePosixPath(name)
    assert not rel.is_absolute() and '..' not in rel.parts
    path=root/name
    expected_after=fixmap[name]['after'] if name in fixmap else item['after']
    if mode=='publish':
        data=path.read_bytes();assert hashlib.sha256(data).hexdigest()==expected_after,name
        payload=json.dumps({'encoding':'base64','content':base64.b64encode(data).decode()}).encode()
        req=urllib.request.Request('https://api.github.com/repos/'+os.environ['GITHUB_REPOSITORY']+'/git/blobs',data=payload,method='POST',headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'rft-authorized-preflight'})
        with urllib.request.urlopen(req,timeout=45) as response:blob=json.load(response)
        expected=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
        assert blob['sha']==expected,name
        record={'path':name,'mode':'100644','type':'blob','sha':blob['sha']};changes.append(record)
        print('VERIFIED_BLOB '+json.dumps(record))
        continue
    data=path.read_bytes() if path.exists() else b''
    assert hashlib.sha256(data).hexdigest()==item['before'],'Base mismatch: '+name
    lines=data.decode('utf-8').splitlines(keepends=True)
    for start,end,text in reversed(item['edits']):lines[start:end]=[text]
    data=''.join(lines).encode('utf-8');assert hashlib.sha256(data).hexdigest()==item['after'],'Patch mismatch: '+name
    if mode=='apply' and name=='RF-Network-Tool-DiscoveryWorker.ps1':diagnose_terminal(data)
    if name in fixmap:
        fix=fixmap[name];assert hashlib.sha256(data).hexdigest()==fix['before']
        text=data.decode('utf-8')
        for old,new in fix['replacements']:
            assert text.count(old)==1,(name,'fix anchor mismatch')
            text=text.replace(old,new)
        data=text.encode('utf-8');assert hashlib.sha256(data).hexdigest()==expected_after,(name,'fix hash mismatch')
    if mode=='prepare' and name=='tests/WINDOWS_MEASUREMENT_TEST_v1_5_3.ps1':
        (root/'.rft-preflight/baseline-test.ps1').write_bytes(data)
    elif mode=='apply':
        path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
if mode=='publish':
    dest=root/'ci-artifacts/blob-map.json';dest.parent.mkdir(exist_ok=True)
    dest.write_text(json.dumps({'base':recipe['base'],'files':changes},indent=2))
print('PREFLIGHT_'+mode.upper()+'_DONE')
