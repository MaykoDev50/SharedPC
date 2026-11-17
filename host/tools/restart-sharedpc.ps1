# Restart the SharedPC virtual machine (clean shutdown, then start again in the background)
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Add-Type -AssemblyName System.Windows.Forms
$vbm = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
function Running { ((& $vbm list runningvms) -join "`n") -match '"SharedPC"' }
Write-Host 'Shutting down the shared computer...'
if (Running) {
    & $vbm controlvm SharedPC acpipowerbutton 2>&1 | Out-Null
    for ($i = 0; $i -lt 36 -and (Running); $i++) { Start-Sleep -Seconds 5 }
    if (Running) { & $vbm controlvm SharedPC poweroff 2>&1 | Out-Null; Start-Sleep -Seconds 5 }
}
# Remote Desktop refuses 127.0.0.1, so make sure the RDP port-forward is on 127.0.0.2
& $vbm modifyvm SharedPC --natpf1 delete rdp 2>&1 | Out-Null
& $vbm modifyvm SharedPC --natpf1 'rdp,tcp,127.0.0.2,13389,,3389' 2>&1 | Out-Null
Write-Host 'Starting it again...'
& $vbm startvm SharedPC --type headless 2>&1 | Out-Null
[System.Windows.Forms.MessageBox]::Show("המחשב המשותף מופעל מחדש.`nהוא יהיה מוכן בעוד כ-3 דקות.", 'SharedPC') | Out-Null
