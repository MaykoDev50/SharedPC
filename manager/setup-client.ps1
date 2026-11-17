# Runs once inside a new virtual computer (as SYSTEM, from SetupComplete.cmd).
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Start-Transcript -Path 'C:\Setup-Client\setup.log' -Append | Out-Null
$cfg = Get-Content 'C:\Setup-Client\client.json' -Raw | ConvertFrom-Json

# Remote Desktop on, with Network Level Authentication, ONE person at a time
$ts = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty $ts -Name fDenyTSConnections -Value 0
Set-ItemProperty $ts -Name fSingleSessionPerUser -Value 1
Set-ItemProperty "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
New-Item $pol -Force | Out-Null
Set-ItemProperty $pol -Name MaxInstanceCount -Value 1 -Type DWord
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

# the person's account
$sec = ConvertTo-SecureString ([string]$cfg.password) -AsPlainText -Force
New-LocalUser -Name $cfg.user -Password $sec -FullName $cfg.user -PasswordNeverExpires -AccountNeverExpires | Out-Null
Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $cfg.user          # Remote Desktop Users
if ($cfg.admin) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $cfg.user }

# protection against password guessing from the internet
Rename-LocalUser -Name 'Administrator' -NewName $cfg.adminName -ErrorAction SilentlyContinue   # bots always try "Administrator"
& net.exe accounts /lockoutthreshold:10 /lockoutwindow:15 /lockoutduration:15 | Out-Null

# feel like a normal PC
foreach ($svc in 'AudioEndpointBuilder', 'Audiosrv') { Set-Service $svc -StartupType Automatic; Start-Service $svc -ErrorAction SilentlyContinue }
New-Item 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1
Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null

# Google Chrome
$msi = Join-Path $env:TEMP 'chrome.msi'
for ($i = 0; $i -lt 30; $i++) {
    & curl.exe -L -s --fail -o $msi 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    if ($LASTEXITCODE -eq 0) { Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait; break }
    Start-Sleep -Seconds 10
}

# remove secrets
Remove-Item 'C:\Setup-Client\client.json' -Force
Remove-Item 'C:\Windows\Panther\unattend.xml' -Force -ErrorAction SilentlyContinue
Stop-Transcript | Out-Null
