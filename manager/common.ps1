# Shared helpers for SharedPC-Manager and create-vm
$script:VBM     = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
$script:VmsFile = 'C:\SharedPC-Host\vms.json'

function VBox {
    $ErrorActionPreference = 'Continue'
    for ($try = 1; ; $try++) {
        $out = & $script:VBM @args 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return $out }
        # "Failed to create the VirtualBox object": VirtualBox's background service is stuck or was started
        # without admin rights (e.g. right after installing VirtualBox). Restart it - only if no computer runs.
        if ($try -le 4 -and $out -match 'Failed to create the VirtualBox object|VBoxSVC|E_ACCESSDENIED|CO_E_SERVER_EXEC_FAILURE|0x80070005|0x80080005|is not ready') {
            if (-not (Get-Process VBoxHeadless, VirtualBoxVM -ErrorAction SilentlyContinue)) {
                Get-Process VirtualBox, VBoxSVC, VBoxSDS -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds (5 * $try); continue
        }
        throw "VBoxManage $($args[0]) failed: $($out.Trim())"
    }
}

function New-RandomPassword([int]$groups = 4) {
    $u = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $l = 'abcdefghijkmnpqrstuvwxyz'; $d = '23456789'
    $c = @(); 1..$groups | ForEach-Object { $c += $u[(Get-Random -Max $u.Length)]; $c += $l[(Get-Random -Max $l.Length)]; $c += $d[(Get-Random -Max $d.Length)] }
    (($c | Sort-Object { Get-Random }) -join '') + '!'
}

function Use-VmsLock([scriptblock]$do) {
    $m = New-Object System.Threading.Mutex($false, 'Global\SharedPCVms')
    [void]$m.WaitOne()
    try { & $do } finally { $m.ReleaseMutex() }
}
function Read-VmRecords {
    if (-not (Test-Path $script:VmsFile)) { return @() }
    $raw = Get-Content $script:VmsFile -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return @() }
    # (...) | ForEach-Object unrolls the array (PowerShell 5.1 returns a JSON array as ONE object)
    @(($raw | ConvertFrom-Json) | ForEach-Object { $_ })
}
function Write-VmRecords($list) { ConvertTo-Json -InputObject @($list) -Depth 4 | Set-Content $script:VmsFile -Encoding UTF8 }
function Get-VmRecords { Use-VmsLock { Read-VmRecords } }
function Add-VmRecord($rec) { Use-VmsLock { $l = @(Read-VmRecords) + $rec; Write-VmRecords $l } }
function Remove-VmRecord([string]$name) { Use-VmsLock { Write-VmRecords @(Read-VmRecords | Where-Object { $_.name -ne $name }) } }
function Update-VmRecord([string]$name, [hashtable]$set) {
    Use-VmsLock {
        $l = @(Read-VmRecords)
        foreach ($r in $l) {
            if ($r.name -eq $name) {
                foreach ($k in $set.Keys) {
                    if ($r.PSObject.Properties[$k]) { $r.$k = $set[$k] } else { $r | Add-Member -NotePropertyName $k -NotePropertyValue $set[$k] }
                }
            }
        }
        Write-VmRecords $l
    }
}

# true when Remote Desktop on this port really answers (not just the VirtualBox port-forward)
function Test-Rdp([int]$port) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { $c.Close(); return $false }
        $c.EndConnect($iar)
        $s = $c.GetStream(); $s.ReadTimeout = 5000
        [byte[]]$req = 0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00
        $s.Write($req, 0, $req.Length)
        $buf = New-Object byte[] 19
        $n = $s.Read($buf, 0, 19)
        $c.Close()
        return ($n -ge 4 -and $buf[0] -eq 3)
    } catch { return $false }
}

function Get-VmState([string]$vmName) {
    $ErrorActionPreference = 'Continue'
    $info = & $script:VBM showvminfo $vmName --machinereadable 2>$null
    $line = $info | Where-Object { $_ -like 'VMState=*' } | Select-Object -First 1
    if ($line) { ($line -split '=', 2)[1].Trim('"') } else { 'missing' }
}

# ---------- home router: open ports automatically (UPnP) ----------
$script:UpCtl = $null; $script:UpSvc = $null; $script:UpLan = $null
function Get-LanIp {
    (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress
}
function Find-Router {
    if ($script:UpCtl) { return $true }
    $lan = Get-LanIp; if (-not $lan) { return $false }
    $script:UpLan = $lan
    $locs = @{}
    foreach ($st in 'urn:schemas-upnp-org:device:InternetGatewayDevice:1', 'upnp:rootdevice') {
        try {
            $udp = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint([Net.IPAddress]::Parse($lan), 0))
            $udp.Client.ReceiveTimeout = 2500
            $msg = [Text.Encoding]::ASCII.GetBytes("M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: $st`r`n`r`n")
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Parse('239.255.255.250'), 1900)
            [void]$udp.Send($msg, $msg.Length, $ep); [void]$udp.Send($msg, $msg.Length, $ep)
            $end = (Get-Date).AddSeconds(3)
            while ((Get-Date) -lt $end) {
                try {
                    $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                    $resp = [Text.Encoding]::ASCII.GetString($udp.Receive([ref]$from))
                    if ($resp -match '(?im)^location:\s*(\S+)') { $locs[$Matches[1]] = $from.Address.ToString() }
                } catch { break }
            }
            $udp.Close()
        } catch {}
        if ($locs.Count) { break }
    }
    foreach ($loc in $locs.Keys) {
        try {
            $xml = (Invoke-WebRequest $loc -UseBasicParsing -TimeoutSec 5).Content
            foreach ($svc in 'urn:schemas-upnp-org:service:WANIPConnection:1', 'urn:schemas-upnp-org:service:WANIPConnection:2', 'urn:schemas-upnp-org:service:WANPPPConnection:1') {
                $i = $xml.IndexOf($svc); if ($i -lt 0) { continue }
                if ($xml.Substring($i) -match '<controlURL>([^<]+)</controlURL>') {
                    $cu = $Matches[1]; $u = [Uri]$loc
                    $hostPart = if ($locs[$loc] -match '^\d+\.\d+\.\d+\.\d+$') { $locs[$loc] } else { $u.Host }
                    $script:UpCtl = if ($cu -like 'http*') { $cu } else { "http://${hostPart}:$($u.Port)" + $(if ($cu.StartsWith('/')) { '' } else { '/' }) + $cu }
                    $script:UpSvc = $svc
                    return $true
                }
            }
        } catch {}
    }
    $false
}
function Invoke-RouterSoap([string]$action, [string]$argsXml) {
    $body = "<?xml version=`"1.0`"?><s:Envelope xmlns:s=`"http://schemas.xmlsoap.org/soap/envelope/`" s:encodingStyle=`"http://schemas.xmlsoap.org/soap/encoding/`"><s:Body><u:$action xmlns:u=`"$script:UpSvc`">$argsXml</u:$action></s:Body></s:Envelope>"
    Invoke-WebRequest $script:UpCtl -Method Post -Body $body -ContentType 'text/xml; charset="utf-8"' -Headers @{ SOAPACTION = "`"$($script:UpSvc)#$action`"" } -UseBasicParsing -TimeoutSec 8 | Out-Null
}
function Open-RouterPort([int]$port) {
    if (-not (Find-Router)) { return $false }
    $add = "<NewRemoteHost></NewRemoteHost><NewExternalPort>$port</NewExternalPort><NewProtocol>TCP</NewProtocol><NewInternalPort>$port</NewInternalPort><NewInternalClient>$($script:UpLan)</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>SharedPC $port</NewPortMappingDescription><NewLeaseDuration>0</NewLeaseDuration>"
    try { Invoke-RouterSoap 'AddPortMapping' $add; return $true } catch {}
    try {   # already mapped (718): replace it
        Invoke-RouterSoap 'DeletePortMapping' "<NewRemoteHost></NewRemoteHost><NewExternalPort>$port</NewExternalPort><NewProtocol>TCP</NewProtocol>"
        Invoke-RouterSoap 'AddPortMapping' $add; return $true
    } catch { return $false }
}
function Close-RouterPort([int]$port) {
    if (-not (Find-Router)) { return }
    try { Invoke-RouterSoap 'DeletePortMapping' "<NewRemoteHost></NewRemoteHost><NewExternalPort>$port</NewExternalPort><NewProtocol>TCP</NewProtocol>" } catch {}
}
