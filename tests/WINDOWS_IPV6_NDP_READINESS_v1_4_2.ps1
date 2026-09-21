[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$fail=New-Object System.Collections.Generic.List[string]

function Assert-True([bool]$condition,[string]$name){
    if($condition){Write-Host ('PASS '+$name) -ForegroundColor Green}
    else{Write-Host ('FAIL '+$name) -ForegroundColor Red;[void]$fail.Add($name)}
}

$ipCmd=Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue
$neighborCmd=Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue
Assert-True ($null -ne $ipCmd) 'Get-NetIPAddress is available'
Assert-True ($null -ne $neighborCmd) 'Get-NetNeighbor is available'
if($fail.Count){exit 1}

try{
    $addresses=@(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop | Select-Object -First 256)
    Assert-True ($addresses.Count -le 256) 'IPv6 address inventory is bounded'
    foreach($entry in $addresses){
        $raw=[string]$entry.IPAddress
        $base=($raw -split '%',2)[0]
        $parsed=$null
        $ok=[Net.IPAddress]::TryParse($base,[ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6
        Assert-True $ok ('IPv6 address parses: '+$raw)
        if($entry.PSObject.Properties['PrefixLength']){
            $prefix=[int]$entry.PrefixLength
            Assert-True ($prefix -ge 0 -and $prefix -le 128) ('IPv6 prefix bounded: '+$prefix)
        }
    }

    $neighbors=@(Get-NetNeighbor -AddressFamily IPv6 -ErrorAction Stop | Select-Object -First 256)
    Assert-True ($neighbors.Count -le 256) 'IPv6 NDP neighbor inventory is bounded'
    foreach($entry in $neighbors){
        $raw=[string]$entry.IPAddress
        if([string]::IsNullOrWhiteSpace($raw)){continue}
        $base=($raw -split '%',2)[0]
        $parsed=$null
        $ok=[Net.IPAddress]::TryParse($base,[ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6
        Assert-True $ok ('NDP neighbor IPv6 parses: '+$raw)
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$entry.State)) ('NDP neighbor has state: '+$raw)
    }

    Write-Host ("IPv6 addresses observed={0}; IPv6 NDP entries observed={1}" -f $addresses.Count,$neighbors.Count)
}catch{
    Write-Host ('FAIL IPv6/NDP inventory: '+$_.Exception.Message) -ForegroundColor Red
    [void]$fail.Add('IPv6/NDP inventory executes')
}

if($fail.Count){Write-Host ('FAILED: '+($fail -join ', ')) -ForegroundColor Red;exit 1}
Write-Host 'ALL WINDOWS IPV6/NDP READINESS TESTS PASSED' -ForegroundColor Green
exit 0
