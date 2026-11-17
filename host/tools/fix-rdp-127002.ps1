# One-time fix: Remote Desktop refuses to connect to 127.0.0.1, so move the VM's RDP port-forward to 127.0.0.2
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Add-Type -AssemblyName System.Windows.Forms
$vbm = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
$running = (& $vbm list runningvms) -join "`n"
if ($running -match '"SharedPC"') {
    & $vbm controlvm SharedPC natpf1 delete rdp 2>&1 | Out-Null
    & $vbm controlvm SharedPC natpf1 'rdp,tcp,127.0.0.2,13389,,3389' 2>&1 | Out-Null
} else {
    & $vbm modifyvm SharedPC --natpf1 delete rdp 2>&1 | Out-Null
    & $vbm modifyvm SharedPC --natpf1 'rdp,tcp,127.0.0.2,13389,,3389' 2>&1 | Out-Null
    & $vbm startvm SharedPC --type headless 2>&1 | Out-Null
}
$rules = (& $vbm showvminfo SharedPC --machinereadable) -match '^Forwarding' -join "`n"
[System.Windows.Forms.MessageBox]::Show("בוצע. עכשיו פתח שוב את SharedPC-Connect.`n`n$rules", 'SharedPC') | Out-Null
