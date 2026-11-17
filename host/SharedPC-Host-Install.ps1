# SharedPC - automatic installer for the HOST computer (Windows 10/11 Pro)
# Does everything: Hyper-V, downloads Windows Server 2022 (evaluation), builds the VM,
# installs the SharedPC portal inside it, connects it to Tailscale.
# Safe to run again: every step checks what is already done and continues from there.

param([switch]$Resume)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- relaunch as Administrator ---
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Resume) { $a += ' -Resume' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}

Add-Type -AssemblyName System.Windows.Forms
$HostDir    = 'C:\SharedPC-Host'
$StatusLog  = Join-Path $PSScriptRoot 'status.log'      # next to this script (Downloads)
$StateFile  = Join-Path $HostDir 'state.json'
$SecretFile = Join-Path $HostDir 'passwords.txt'
$Iso        = Join-Path $HostDir 'WindowsServer2022.iso'
$Vhd        = Join-Path $HostDir 'SharedPC.vhdx'
$VMName     = 'SharedPC'
$RepoRaw    = 'https://raw.githubusercontent.com/MaykoDev50/SharedPC/main'
$ResumeTask = 'SharedPC Installer (resume after restart)'
$IsoUrls    = @(
    'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US',
    'https://software-download.microsoft.com/download/sg/20348.169.210806-2348.fe_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso',
    'https://go.microsoft.com/fwlink/p/?linkid=2195686&clcid=0x409&culture=en-us&country=us'
)
New-Item -ItemType Directory -Path $HostDir -Force | Out-Null

function Log([string]$m) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $m
    Write-Host $line
    Add-Content -Path $StatusLog -Value $line -Encoding UTF8
    Add-Content -Path (Join-Path $HostDir 'install.log') -Value $line -Encoding UTF8
}
function Popup([string]$text, [string]$buttons = 'OK') {
    [System.Windows.Forms.MessageBox]::Show($text, 'SharedPC', $buttons, 'Information', 'Button1',
        [System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign)
}
function Fail([string]$why, [string]$hebrew) {
    Log "FAILED: $why"
    Popup "ההתקנה נעצרה:`n`n$hebrew`n`nפרטים: $why" | Out-Null
    exit 1
}
function Load-State {
    if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
}
function Save-State($s) { $s | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8 }
function Set-StateValue($s, [string]$k, $v) {
    if ($s.PSObject.Properties[$k]) { $s.$k = $v } else { $s | Add-Member -NotePropertyName $k -NotePropertyValue $v }
    Save-State $s
}
function New-RandomPassword {
    $u = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $l = 'abcdefghijkmnpqrstuvwxyz'; $d = '23456789'
    $chars = @()
    1..4 | ForEach-Object { $chars += $u[(Get-Random -Max $u.Length)]; $chars += $l[(Get-Random -Max $l.Length)]; $chars += $d[(Get-Random -Max $d.Length)] }
    (($chars | Sort-Object { Get-Random }) -join '') + '!'
}
function Remove-ResumeTask { Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue }
function Register-ResumeTask {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resume"
    $trg  = New-ScheduledTaskTrigger -AtLogOn -User $user
    $prn  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $ResumeTask -Action $act -Trigger $trg -Principal $prn -Force | Out-Null
}

Log '=============== SharedPC host installer started ==============='
$state = Load-State

# ---------- 1. check this computer ----------
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ramGB  = [math]::Round($cs.TotalPhysicalMemory / 1GB)
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB)
Log "Computer: $($os.Caption) (build $($os.BuildNumber)), RAM ${ramGB}GB, free on C: ${freeGB}GB, CPU: $($cpu.Name.Trim()), cores: $($cpu.NumberOfLogicalProcessors)"
Log "Virtualization in BIOS: $($cpu.VirtualizationFirmwareEnabled), hypervisor running: $($cs.HypervisorPresent)"

if ($os.Caption -match 'Home') {
    Fail 'Windows Home edition has no Hyper-V' 'ל-Windows Home אין Hyper-V. צריך Windows Pro (אפשר לשדרג בהגדרות ← הפעלה).'
}
if ($ramGB -lt 7)  { Fail "Only ${ramGB}GB RAM" 'צריך לפחות 8GB זיכרון במחשב.' }
$needGB = 35; if (Test-Path $Iso) { $needGB = 25 }
if (-not (Test-Path $Vhd) -and $freeGB -lt $needGB) { Fail "Only ${freeGB}GB free on C:" "צריך לפחות $needGB GB פנויים בכונן C." }
if (-not $cpu.VirtualizationFirmwareEnabled -and -not $cs.HypervisorPresent) {
    Fail 'Virtualization is disabled in BIOS/UEFI' 'הווירטואליזציה כבויה ב-BIOS. צריך להיכנס ל-BIOS ולהפעיל Intel VT-x / AMD SVM, ואז להריץ שוב.'
}

# ---------- 2. Hyper-V ----------
$needReboot = $false
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hv.State -ne 'Enabled') {
    Log 'Enabling Hyper-V...'
    $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
    $needReboot = $true
    Log "Hyper-V enabled (restart needed: $($r.RestartNeeded))"
} elseif (-not (Get-Command New-VM -ErrorAction SilentlyContinue) -or
          (Get-Service vmms -ErrorAction SilentlyContinue).Status -ne 'Running') {
    $needReboot = $true
    Log 'Hyper-V is enabled but not active yet - restart needed'
} else {
    Log 'Hyper-V is ready'
}

# ---------- 3. download Windows Server 2022 (evaluation) ----------
function Test-Iso([string]$path) {
    if (-not (Test-Path $path) -or (Get-Item $path).Length -lt 3GB) { return $false }
    try {
        $img = Mount-DiskImage -ImagePath $path -PassThru
        $dl  = ($img | Get-Volume).DriveLetter
        $ok  = (Test-Path "${dl}:\sources\install.wim") -or (Test-Path "${dl}:\sources\install.esd")
        Dismount-DiskImage -ImagePath $path | Out-Null
        return $ok
    } catch { try { Dismount-DiskImage -ImagePath $path | Out-Null } catch {}; return $false }
}

if (-not $state.PSObject.Properties['IsoOk']) {
    if (Test-Iso $Iso) { Set-StateValue $state 'IsoOk' $true }
}
if (-not $state.PSObject.Properties['IsoOk']) {
    foreach ($u in $IsoUrls) {
        Log "Downloading Windows Server 2022 (about 4.7GB) from $u"
        $part = "$Iso.part"
        & curl.exe -L --fail --retry 10 --retry-delay 5 -C - -o $part $u
        if ($LASTEXITCODE -eq 0 -and (Test-Path $part) -and (Get-Item $part).Length -gt 3GB) {
            Move-Item $part $Iso -Force
            if (Test-Iso $Iso) { Set-StateValue $state 'IsoOk' $true; Log 'Download complete and verified'; break }
            Log 'Downloaded file is not a valid Windows ISO'; Remove-Item $Iso -Force
        } else {
            Log "Download failed (curl exit $LASTEXITCODE)"
            Remove-Item $part -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $state.PSObject.Properties['IsoOk']) {
        Fail 'Could not download the Windows Server ISO' 'לא הצלחתי להוריד את Windows Server. בדוק את החיבור לאינטרנט והרץ שוב.'
    }
} else { Log 'Windows Server ISO already downloaded' }

# ---------- restart if Hyper-V needs it ----------
if ($needReboot) {
    Register-ResumeTask
    Log 'WAITING FOR RESTART: Hyper-V needs a restart. The installer will continue automatically after login.'
    $ans = Popup "Hyper-V הותקן, וצריך להפעיל מחדש את המחשב.`n`nאחרי ההפעלה מחדש וההתחברות, ההתקנה תמשיך לבד.`n`nלהפעיל מחדש עכשיו?" 'YesNo'
    if ($ans -eq 'Yes') { Restart-Computer -Force }
    exit 0
}
Remove-ResumeTask
Import-Module Hyper-V

# ---------- 4. build the virtual disk (Windows applied directly, no setup screens) ----------
if (-not $state.PSObject.Properties['AdminPassword']) { Set-StateValue $state 'AdminPassword' (New-RandomPassword) }
if (-not $state.PSObject.Properties['InviteCode']) {
    Set-StateValue $state 'InviteCode' (-join ((50..57) + (65..72) + (74..78) + (80..90) | Get-Random -Count 8 | ForEach-Object { [char]$_ }))
}
$AdminPw = [string]$state.AdminPassword

if (-not $state.PSObject.Properties['DiskReady']) {
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { Fail 'A VM named SharedPC already exists' 'כבר קיימת מכונה וירטואלית בשם SharedPC. מחק אותה ב-Hyper-V Manager והרץ שוב.' }
    if (Test-Path $Vhd) { Dismount-VHD -Path $Vhd -ErrorAction SilentlyContinue; Remove-Item $Vhd -Force }

    Log 'Creating virtual disk (127GB, grows as needed)...'
    New-VHD -Path $Vhd -SizeBytes 127GB -Dynamic | Out-Null
    $disk = Mount-VHD -Path $Vhd -Passthru | Get-Disk
    $n = $disk.Number
    Initialize-Disk -Number $n -PartitionStyle GPT
    # system partition is created as basic-data first so it can get a drive letter; switched to EFI type afterwards
    $sys = New-Partition -DiskNumber $n -Size 300MB -AssignDriveLetter
    Format-Volume -Partition $sys -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    New-Partition -DiskNumber $n -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
    $win = New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $S = (Get-Partition -DiskNumber $n -PartitionNumber $sys.PartitionNumber).DriveLetter
    $W = (Get-Partition -DiskNumber $n -PartitionNumber $win.PartitionNumber).DriveLetter

    $img = Mount-DiskImage -ImagePath $Iso -PassThru
    $I   = ($img | Get-Volume).DriveLetter
    $wim = if (Test-Path "${I}:\sources\install.wim") { "${I}:\sources\install.wim" } else { "${I}:\sources\install.esd" }
    $images = Get-WindowsImage -ImagePath $wim
    $pick = $images | Where-Object { $_.ImageName -match 'Standard' -and $_.ImageName -match 'Desktop' } | Select-Object -First 1
    if (-not $pick) { $pick = $images | Where-Object { $_.ImageName -match 'Desktop' } | Select-Object -First 1 }
    Log "Installing '$($pick.ImageName)' onto the virtual disk (takes 5-15 minutes)..."
    Expand-WindowsImage -ImagePath $wim -Index $pick.ImageIndex -ApplyPath "${W}:\" | Out-Null
    Dismount-DiskImage -ImagePath $Iso | Out-Null

    Log 'Making the disk bootable...'
    & bcdboot.exe "${W}:\Windows" /s "${S}:" /f UEFI | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "bcdboot failed ($LASTEXITCODE)" 'שגיאה בהכנת הדיסק לאתחול.' }

    # first-boot answers: computer name, time zone, Hebrew keyboard, Administrator password, skip all screens
    $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>SHAREDPC</ComputerName>
      <TimeZone>Israel Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409;040d:0000040d</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>he-IL</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword><Value>$AdminPw</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
    New-Item -ItemType Directory -Path "${W}:\Windows\Panther" -Force | Out-Null
    Set-Content -Path "${W}:\Windows\Panther\unattend.xml" -Value $unattend -Encoding UTF8

    # turn the system partition into a real EFI partition and hide it
    Remove-PartitionAccessPath -DiskNumber $n -PartitionNumber $sys.PartitionNumber -AccessPath "${S}:\"
    Set-Partition -DiskNumber $n -PartitionNumber $sys.PartitionNumber -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Dismount-VHD -Path $Vhd
    Set-StateValue $state 'DiskReady' $true
    Log 'Virtual disk ready'
} else { Log 'Virtual disk already built' }

# ---------- 5. create and start the VM ----------
if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    $switch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if (-not $switch) { Fail 'Hyper-V Default Switch not found' 'לא נמצא החיבור "Default Switch" של Hyper-V.' }
    $memGB = if ($ramGB -ge 16) { 8 } elseif ($ramGB -ge 12) { 6 } else { 4 }
    $cpus  = [math]::Max(2, [math]::Min(4, [int]($cpu.NumberOfLogicalProcessors / 2)))
    Log "Creating VM '$VMName' with ${memGB}GB RAM and $cpus processors..."
    New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ([int64]$memGB * 1GB) -VHDPath $Vhd -SwitchName 'Default Switch' | Out-Null
    Set-VMProcessor -VMName $VMName -Count $cpus
    Set-VMMemory    -VMName $VMName -DynamicMemoryEnabled $false
    Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 0 -AutomaticStopAction Save `
           -AutomaticCheckpointsEnabled $false -CheckpointType Standard
    Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface' -ErrorAction SilentlyContinue
}
if ((Get-VM -Name $VMName).State -ne 'Running') { Log 'Starting VM...'; Start-VM -Name $VMName }

$cred = New-Object PSCredential('Administrator', (ConvertTo-SecureString $AdminPw -AsPlainText -Force))
Log 'Waiting for Windows inside the VM to finish first boot (5-15 minutes)...'
$deadline = (Get-Date).AddMinutes(40); $ready = $false
while ((Get-Date) -lt $deadline) {
    try { Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock { $true } -ErrorAction Stop | Out-Null; $ready = $true; break }
    catch { Start-Sleep -Seconds 20 }
}
if (-not $ready) { Fail 'VM did not become reachable within 40 minutes' 'Windows בתוך המכונה לא עלה בזמן. אפשר להריץ שוב את ההתקנה, היא תמשיך מאותה נקודה.' }
Log 'Windows inside the VM is up'

# ---------- 6. install the SharedPC portal inside the VM ----------
$s = New-PSSession -VMName $VMName -Credential $cred
if (-not $state.PSObject.Properties['GuestReady']) {
    Log 'Downloading the newest SharedPC files from GitHub...'
    $gdir = Join-Path $HostDir 'guest'
    New-Item -ItemType Directory -Path $gdir -Force | Out-Null
    foreach ($f in 'setup.ps1', 'portal.ps1', 'update.ps1', 'version.txt', 'files.txt', 'install.bat') {
        & curl.exe -L --fail -s -o (Join-Path $gdir $f) "$RepoRaw/$f"
        if ($LASTEXITCODE -ne 0) { Fail "Could not download $f from GitHub" 'לא הצלחתי להוריד את קבצי המערכת מ-GitHub.' }
    }
    Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Path 'C:\SharedPC-Install' -Force | Out-Null }
    Copy-Item -Path (Join-Path $gdir '*') -Destination 'C:\SharedPC-Install' -ToSession $s -Force

    Log 'Running SharedPC setup inside the VM...'
    $out = Invoke-Command -Session $s -ArgumentList ([string]$state.InviteCode) -ScriptBlock {
        param($code)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\SharedPC-Install\setup.ps1' -Unattended -InviteCode $code 2>&1 | Out-String
    }
    Add-Content -Path (Join-Path $HostDir 'install.log') -Value $out -Encoding UTF8
    $ok = Invoke-Command -Session $s -ScriptBlock {
        try { (Invoke-WebRequest 'http://localhost:8080/' -UseBasicParsing -TimeoutSec 15).StatusCode -eq 200 } catch { $false }
    }
    if (-not $ok) { Fail 'Portal inside the VM is not answering' 'הפורטל בתוך המכונה לא עונה. הפרטים ב-C:\SharedPC-Host\install.log' }
    Set-StateValue $state 'GuestReady' $true
    Log 'SharedPC portal is running inside the VM'
} else { Log 'SharedPC already installed inside the VM' }

# ---------- 7. Tailscale inside the VM (access from anywhere) ----------
$tsIp = Invoke-Command -Session $s -ScriptBlock {
    $exe = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path $exe) { (& $exe ip -4 2>$null | Select-Object -First 1) } else { $null }
}
if (-not $tsIp) {
    Log 'Installing Tailscale inside the VM...'
    Invoke-Command -Session $s -ScriptBlock {
        $exe = 'C:\Program Files\Tailscale\tailscale.exe'
        if (-not (Test-Path $exe)) {
            $msi = Join-Path $env:TEMP 'tailscale.msi'
            & curl.exe -L --fail -s -o $msi 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
            Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn TS_UNATTENDEDMODE=always" -Wait
            Start-Sleep -Seconds 10
        }
    }
    $url = Invoke-Command -Session $s -ScriptBlock {
        $exe = 'C:\Program Files\Tailscale\tailscale.exe'
        $o = 'C:\SharedPC\tailscale-up.txt'
        Start-Process $exe -ArgumentList 'up', '--unattended', '--hostname=sharedpc' -WindowStyle Hidden `
            -RedirectStandardError $o -RedirectStandardOutput "$o.out"
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            $txt = (Get-Content $o, "$o.out" -Raw -ErrorAction SilentlyContinue) -join ' '
            if ($txt -match '(https://login\.tailscale\.com/\S+)') { return $Matches[1] }
            if (& $exe ip -4 2>$null) { return 'already' }
        }
        return $null
    }
    if ($url -and $url -ne 'already') {
        Log 'WAITING FOR YOU: log in to Tailscale in the browser window that just opened'
        Start-Process $url
        Popup "נפתח דף התחברות של Tailscale בדפדפן.`n`nהתחבר עם החשבון שלך (למשל Google) ואשר את המחשב 'sharedpc'.`nההתקנה תמשיך לבד ברגע שתסיים." | Out-Null
    }
    $deadline = (Get-Date).AddMinutes(15)
    while (-not $tsIp -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $tsIp = Invoke-Command -Session $s -ScriptBlock { & 'C:\Program Files\Tailscale\tailscale.exe' ip -4 2>$null | Select-Object -First 1 }
    }
    if ($tsIp) { Log "Tailscale connected: $tsIp" } else { Log 'Tailscale login not completed - the portal still works from this computer' }
} else { Log "Tailscale already connected: $tsIp" }
Remove-PSSession $s

# ---------- 8. done ----------
$lanIp = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
$portal = if ($tsIp) { "http://${tsIp}:8080" } else { "http://${lanIp}:8080" }

@"
SharedPC - פרטים חשובים (שמור את הקובץ הזה)
=============================================
פורטל (מכל מקום, דרך Tailscale):  $(if ($tsIp) { "http://${tsIp}:8080" } else { 'עוד לא מחובר ל-Tailscale' })
פורטל (רק מהמחשב הזה):            http://${lanIp}:8080
קוד הזמנה ליצירת משתמשים:          $($state.InviteCode)

משתמש מנהל של המחשב המשותף (לתחזוקה בלבד):
  שם משתמש: Administrator
  סיסמה:     $AdminPw

ניהול המכונה: Hyper-V Manager ← SharedPC
"@ | Set-Content $SecretFile -Encoding UTF8

Log "ALL DONE. Portal: $portal  |  Invite code and passwords saved in $SecretFile"

if ($true) {
    $ans = Popup "כדי שהמחשב המשותף יהיה זמין כל הזמן, המחשב הזה לא צריך להיכנס למצב שינה כשהוא מחובר לחשמל.`n`nלבטל מצב שינה (בחיבור לחשמל)?" 'YesNo'
    if ($ans -eq 'Yes') { & powercfg.exe /change standby-timeout-ac 0; & powercfg.exe /change hibernate-timeout-ac 0; Log 'Sleep on AC power disabled' }
}
Start-Process $portal
Start-Process notepad.exe $SecretFile
Popup "הכל מוכן! 🎉`n`nהפורטל נפתח בדפדפן: $portal`nקוד ההזמנה והסיסמאות נשמרו בקובץ שנפתח עכשיו.`n`nשלח לחבר את כתובת הפורטל ואת קוד ההזמנה." | Out-Null
