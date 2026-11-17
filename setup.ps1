# SharedPC setup - run INSIDE the Windows Server 2022 virtual machine.
# Turns the VM into a shared computer: 2 people connected at once, each with their own desktop,
# shared files and programs, plus a web portal for creating users.

param(
    [switch]$Unattended,      # no questions (used by the automatic host installer)
    [string]$InviteCode = '',
    [switch]$NoAdmins
)
$ErrorActionPreference = 'Stop'

# --- relaunch as Administrator if needed ---
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($MyInvocation.UnboundArguments -join ' ')"
    exit
}

$Root     = 'C:\SharedPC'
$Shared   = 'C:\Shared'
$Port     = 8080
$TaskName = 'SharedPC Portal'
function Step([string]$t) { Write-Host "`n==> $t" -ForegroundColor Cyan }

# --- sanity check: Windows client editions allow only ONE remote user at a time ---
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "System: $($os.Caption)" -ForegroundColor Gray
if ($os.ProductType -eq 1 -and -not $Unattended) {
    Write-Warning 'This is a regular Windows (10/11) edition: only ONE person can be connected at a time.'
    Write-Warning 'For 2 people at once, install Windows Server 2022 (Desktop Experience) as described in the guide.'
    if ((Read-Host 'Continue anyway? (y/n)') -ne 'y') { exit }
}

# --- files ---
Step 'Copying portal files'
New-Item -ItemType Directory -Path $Root -Force | Out-Null
Get-ChildItem $PSScriptRoot -File | Unblock-File -ErrorAction SilentlyContinue
foreach ($f in 'portal.ps1', 'update.ps1', 'version.txt') { Copy-Item (Join-Path $PSScriptRoot $f) $Root -Force }

# --- settings ---
Step 'Portal settings'
if ($Unattended) {
    $invite     = $InviteCode
    $makeAdmins = -not $NoAdmins
} else {
    $invite   = Read-Host 'Choose an INVITE CODE (needed to create users). Press Enter for a random one'
    $adminAns = Read-Host 'Should new users be administrators (able to install programs)? [Y/n]'
    $makeAdmins = ($adminAns -notmatch '^[nN]')
}
if (-not $invite) { $invite = -join ((48..57) + (65..90) | Get-Random -Count 8 | ForEach-Object { [char]$_ }) }

[ordered]@{ Port = $Port; InviteCode = $invite; MaxUsers = 5; MakeAdmins = $makeAdmins;
           UpdateRepo = 'MaykoDev50/SharedPC'; UpdateBranch = 'main' } |
    ConvertTo-Json | Set-Content (Join-Path $Root 'config.json') -Encoding UTF8

# --- Remote Desktop ---
Step 'Enabling Remote Desktop'
$ts = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty $ts -Name fDenyTSConnections   -Value 0
Set-ItemProperty $ts -Name fSingleSessionPerUser -Value 1                      # each user gets one session
Set-ItemProperty "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1   # Network Level Authentication
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'                         # "Remote Desktop" rules (any language)

# --- group for portal users ---
if (-not (Get-LocalGroup -Name 'SharedPC-Users' -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name 'SharedPC-Users' -Description 'Users created by the SharedPC portal' | Out-Null
}

# --- shared folder + desktop shortcut for everyone ---
Step "Creating shared folder $Shared"
New-Item -ItemType Directory -Path $Shared -Force | Out-Null
& icacls.exe $Shared /grant '*S-1-5-32-555:(OI)(CI)M' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $env:PUBLIC 'Desktop\Shared.lnk'))
$lnk.TargetPath = $Shared
$lnk.Save()

# --- make the server feel like a normal PC ---
Step 'Desktop tweaks (sound, no Server Manager pop-up)'
foreach ($svc in 'AudioEndpointBuilder', 'Audiosrv') {
    Set-Service $svc -StartupType Automatic
    Start-Service $svc -ErrorAction SilentlyContinue
}
New-Item 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1
Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null

# --- firewall for the portal ---
Step "Opening port $Port for the portal"
Get-NetFirewallRule -DisplayName 'SharedPC Portal' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'SharedPC Portal' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null

# --- run the portal at every startup ---
Step 'Installing the portal as a background task'
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\portal.ps1`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
             -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

# --- auto-update: at startup + every day at 04:00 ---
Step 'Installing automatic updates'
$uAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\update.ps1`""
$uBoot    = New-ScheduledTaskTrigger -AtStartup
$uBoot.Delay = 'PT2M'
$uDaily   = New-ScheduledTaskTrigger -Daily -At '04:00'
$uSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable `
             -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'SharedPC Updater' -Action $uAction -Trigger $uBoot, $uDaily `
    -Principal $principal -Settings $uSettings -Force | Out-Null
Start-ScheduledTask -TaskName 'SharedPC Updater'   # grab the newest version right away

Start-Sleep -Seconds 4
try {
    Invoke-WebRequest "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 10 | Out-Null
    Write-Host 'Portal is running.' -ForegroundColor Green
} catch {
    Write-Warning "Portal did not answer yet. Check $Root\portal.log"
}

# --- summary ---
$tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$tsIp  = if (Test-Path $tsExe) { (& $tsExe ip -4 2>$null | Select-Object -First 1) } else { $null }
$lanIp = Get-NetIPAddress -AddressFamily IPv4 |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '100.*' } |
         Select-Object -ExpandProperty IPAddress -First 1

Write-Host "`n================ DONE ================" -ForegroundColor Green
if ($tsIp) { Write-Host "Portal (from anywhere, via Tailscale):  http://$($tsIp):$Port" -ForegroundColor Yellow }
else       { Write-Host 'Tailscale not found - install it to connect from outside your home (see guide).' -ForegroundColor Yellow }
if ($lanIp) { Write-Host "Portal (same home network only):        http://$($lanIp):$Port" }
Write-Host "Invite code:                            $invite" -ForegroundColor Yellow
Write-Host "New users are administrators:           $makeAdmins"
Write-Host "Shared folder:                          $Shared  (shortcut 'Shared' on every desktop)"
Write-Host "Settings / log:                         $Root\config.json  /  $Root\portal.log"
Write-Host 'Updates:                                automatic (daily 04:00 + every startup)'
Write-Host '======================================'
if (-not $Unattended) { Read-Host "`nPress Enter to close" }
