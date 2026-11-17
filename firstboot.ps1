# SharedPC first boot (runs once as SYSTEM from SetupComplete.cmd inside the new VM)
$ErrorActionPreference = 'Continue'
$Inst = 'C:\SharedPC-Install'
Start-Transcript -Path (Join-Path $Inst 'firstboot.log') -Append | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$cfg = Get-Content (Join-Path $Inst 'firstboot.json') -Raw | ConvertFrom-Json

# wait for the network
for ($i = 0; $i -lt 60; $i++) {
    if (Test-NetConnection -ComputerName 'raw.githubusercontent.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { break }
    Start-Sleep -Seconds 5
}

# 1. SharedPC portal + shared folder + remote desktop
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Inst 'setup.ps1') -Unattended -InviteCode $cfg.InviteCode

# 2. Tailscale (installed now, login handled by a background task so Windows can finish starting)
$exe = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $exe)) {
    $msi = Join-Path $env:TEMP 'tailscale.msi'
    for ($i = 0; $i -lt 5 -and -not (Test-Path $msi); $i++) {
        try { Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi -UseBasicParsing }
        catch { Remove-Item $msi -ErrorAction SilentlyContinue; Start-Sleep -Seconds 10 }
    }
    if (Test-Path $msi) { Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn TS_UNATTENDEDMODE=always" -Wait }
}
Copy-Item (Join-Path $Inst 'tslogin.ps1') 'C:\SharedPC\tslogin.ps1' -Force
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\SharedPC\tslogin.ps1'
$trg = New-ScheduledTaskTrigger -AtStartup
$prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'SharedPC Tailscale Login' -Action $act -Trigger $trg -Principal $prn -Force | Out-Null
Start-ScheduledTask -TaskName 'SharedPC Tailscale Login'

# 3. remove the answer file (it contained the Administrator password)
Remove-Item 'C:\Windows\Panther\unattend.xml' -Force -ErrorAction SilentlyContinue
Set-Content 'C:\SharedPC\firstboot-done.txt' (Get-Date).ToString('s')
Stop-Transcript | Out-Null
