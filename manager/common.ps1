# Shared helpers for SharedPC-Manager and create-vm
$script:VBM     = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
$script:VmsFile = 'C:\SharedPC-Host\vms.json'

function VBox {
    $ErrorActionPreference = 'Continue'
    $out = & $script:VBM @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args[0]) failed: $($out.Trim())" }
    $out
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
