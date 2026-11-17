# SharedPC - automatic installer for the HOST computer (works on Windows 10/11 Home, 100% free)
# VirtualBox + Windows Server 2022 (evaluation) + SharedPC portal + Tailscale.
# Safe to run again: every step checks what is already done and continues from there.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- relaunch as Administrator ---
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$HostDir    = 'C:\SharedPC-Host'
$StatusLog  = Join-Path $PSScriptRoot 'status.log'
$StateFile  = Join-Path $HostDir 'state.json'
$SecretFile = Join-Path $HostDir 'passwords.txt'
$Iso        = Join-Path $HostDir 'WindowsServer2022.iso'
$Vhd        = Join-Path $HostDir 'SharedPC.vhd'
$VMName     = 'SharedPC'
$StartTask  = 'SharedPC - start VM at login'
$RepoRaw    = 'https://raw.githubusercontent.com/MaykoDev50/SharedPC/main'
$PortalPort = 18080   # http://localhost:18080 -> portal inside the VM
$RdpPort    = 13389   # localhost:13389      -> remote desktop inside the VM
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
function Load-State { if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} } }
function Set-StateValue($s, [string]$k, $v) {
    if ($s.PSObject.Properties[$k]) { $s.$k = $v } else { $s | Add-Member -NotePropertyName $k -NotePropertyValue $v }
    $s | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}
function Has($s, [string]$k) { [bool]$s.PSObject.Properties[$k] }
function New-RandomPassword {
    $u = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $l = 'abcdefghijkmnpqrstuvwxyz'; $d = '23456789'
    $c = @(); 1..4 | ForEach-Object { $c += $u[(Get-Random -Max $u.Length)]; $c += $l[(Get-Random -Max $l.Length)]; $c += $d[(Get-Random -Max $d.Length)] }
    (($c | Sort-Object { Get-Random }) -join '') + '!'
}
function Download([string]$url, [string]$dest) {
    & curl.exe -L --fail -s --retry 5 --retry-delay 5 -o $dest $url
    return ($LASTEXITCODE -eq 0 -and (Test-Path $dest) -and (Get-Item $dest).Length -gt 0)
}
function VBox { $ErrorActionPreference = 'Continue'; & $script:VBM @args 2>&1 | ForEach-Object { Write-Host $_ }; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed ($LASTEXITCODE)" } }
function Get-SetupStatus {
    try { Invoke-RestMethod "http://127.0.0.1:$PortalPort/setup-status" -TimeoutSec 10 } catch { $null }
}

# any unexpected error: write it to the log and tell the user (instead of the window just closing)
trap {
    Log "CRASH: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Popup "ההתקנה נעצרה בגלל שגיאה לא צפויה.`n`n$($_.Exception.Message)`n`nאפשר להריץ שוב, היא תמשיך מאותה נקודה." | Out-Null
    exit 1
}

Log '=============== SharedPC host installer (VirtualBox) started ==============='
$state = Load-State

# ---------- 1. check this computer ----------
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ramGB  = [math]::Round($cs.TotalPhysicalMemory / 1GB)
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB)
Log "Computer: $($os.Caption) (build $($os.BuildNumber)), RAM ${ramGB}GB, free on C: ${freeGB}GB, CPU: $($cpu.Name.Trim()), threads: $($cpu.NumberOfLogicalProcessors)"
Log "Virtualization in BIOS: $($cpu.VirtualizationFirmwareEnabled), Windows hypervisor running: $($cs.HypervisorPresent)"
Log "PowerShell $($PSVersionTable.PSVersion), 64-bit process: $([Environment]::Is64BitProcess)"
if ($ramGB -lt 7) { Fail "Only ${ramGB}GB RAM" 'צריך לפחות 8GB זיכרון במחשב.' }
if (-not (Test-Path $Vhd) -and $freeGB -lt 35) { Fail "Only ${freeGB}GB free on C:" 'צריך לפחות 35GB פנויים בכונן C.' }
if (-not $cpu.VirtualizationFirmwareEnabled -and -not $cs.HypervisorPresent) {
    Fail 'Virtualization is disabled in BIOS/UEFI' 'הווירטואליזציה כבויה ב-BIOS. צריך להפעיל Intel VT-x / AMD SVM ב-BIOS ולהריץ שוב.'
}
if ($cs.HypervisorPresent) { Log 'Note: a Windows hypervisor is active (WSL/Memory integrity) - VirtualBox still works, a bit slower' }

# ---------- 2. VirtualBox (free) ----------
$script:VBM = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $script:VBM)) {
    Log 'Installing Microsoft Visual C++ runtime (needed by VirtualBox)...'
    $vc = Join-Path $HostDir 'vc_redist.x64.exe'
    if (Download 'https://aka.ms/vs/17/release/vc_redist.x64.exe' $vc) {
        Start-Process $vc -ArgumentList '/install', '/quiet', '/norestart' -Wait
    }
    Log 'Installing VirtualBox...'
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        & winget.exe install --id Oracle.VirtualBox -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    }
    if (-not (Test-Path $script:VBM)) {
        Log 'winget did not install it - downloading from virtualbox.org...'
        $ver  = ((& curl.exe -L -s 'https://download.virtualbox.org/virtualbox/LATEST-STABLE.TXT') -join '').Trim()
        $list = (& curl.exe -L -s "https://download.virtualbox.org/virtualbox/$ver/") -join "`n"
        if ($list -match "(VirtualBox-$([regex]::Escape($ver))-\d+-Win\.exe)") {
            $exe = Join-Path $HostDir $Matches[1]
            if (Download "https://download.virtualbox.org/virtualbox/$ver/$($Matches[1])" $exe) {
                Start-Process $exe -ArgumentList '--silent', '--ignore-reboot' -Wait
            }
        }
    }
    if (-not (Test-Path $script:VBM)) { Fail 'VirtualBox installation failed' 'ההתקנה של VirtualBox נכשלה.' }
}
Log "VirtualBox ready: $(& $script:VBM --version)"

# ---------- 3. download Windows Server 2022 (evaluation, free) ----------
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
if (-not (Has $state 'IsoOk') -and (Test-Iso $Iso)) { Set-StateValue $state 'IsoOk' $true }
if (-not (Has $state 'IsoOk')) {
    foreach ($u in $IsoUrls) {
        Log "Downloading Windows Server 2022 (about 4.7GB) from $u"
        $part = "$Iso.part"
        & curl.exe -L --fail --retry 10 --retry-delay 5 -o $part $u
        if ($LASTEXITCODE -eq 0 -and (Test-Path $part) -and (Get-Item $part).Length -gt 3GB) {
            Move-Item $part $Iso -Force
            if (Test-Iso $Iso) { Set-StateValue $state 'IsoOk' $true; Log 'Download complete and verified'; break }
            Log 'Downloaded file is not a valid Windows ISO'; Remove-Item $Iso -Force
        } else {
            Log "Download failed (curl exit $LASTEXITCODE)"
            Remove-Item $part -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Has $state 'IsoOk')) { Fail 'Could not download the Windows Server ISO' 'לא הצלחתי להוריד את Windows Server. בדוק את האינטרנט והרץ שוב.' }
} else { Log 'Windows Server ISO already downloaded' }

# ---------- 4. build the virtual disk (Windows applied directly - no setup screens) ----------
if (-not (Has $state 'AdminPassword')) { Set-StateValue $state 'AdminPassword' (New-RandomPassword) }
if (-not (Has $state 'InviteCode')) {
    Set-StateValue $state 'InviteCode' (-join ((50..57) + (65..72) + (74..78) + (80..90) | Get-Random -Count 8 | ForEach-Object { [char]$_ }))
}
$AdminPw = [string]$state.AdminPassword

if (-not (Has $state 'DiskReady')) {
    try { & $script:VBM unregistervm $VMName 2>$null | Out-Null } catch {}
    try { & $script:VBM closemedium disk $Vhd 2>$null | Out-Null } catch {}
    Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null   # left mounted by an earlier failed run
    if (Test-Path $Vhd) { Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null; Remove-Item $Vhd -Force }

    Log 'Creating virtual disk (127GB max, grows as needed)...'
    $dp = Join-Path $HostDir 'create-vhd.txt'
    "create vdisk file=`"$Vhd`" maximum=130048 type=expandable" | Set-Content $dp -Encoding ASCII
    & diskpart.exe /s $dp | Out-Null
    if (-not (Test-Path $Vhd)) { Fail 'diskpart could not create the virtual disk' 'לא הצלחתי ליצור דיסק וירטואלי.' }
    $disk = Mount-DiskImage -ImagePath $Vhd -NoDriveLetter -PassThru | Get-Disk
    $n = $disk.Number
    Initialize-Disk -Number $n -PartitionStyle GPT
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
    Log "Installing '$($pick.ImageName)' onto the virtual disk (5-15 minutes)..."
    Expand-WindowsImage -ImagePath $wim -Index $pick.ImageIndex -ApplyPath "${W}:\" | Out-Null
    Dismount-DiskImage -ImagePath $Iso | Out-Null

    Log 'Making the disk bootable...'
    # try this computer's bcdboot first, then the one inside the new Windows image
    $sysDir = if ([Environment]::Is64BitProcess) { "$env:SystemRoot\System32" } else { "$env:SystemRoot\Sysnative" }
    $booted = $false
    foreach ($b in "$sysDir\bcdboot.exe", "${W}:\Windows\System32\bcdboot.exe") {
        $ErrorActionPreference = 'Continue'
        $bo = & $b "${W}:\Windows" /s "${S}:" /f UEFI 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Log "bcdboot ($b) exit $code : $($bo.Trim())"
        if ($code -eq 0 -and (Test-Path "${S}:\EFI\Boot\bootx64.efi")) { $booted = $true; break }
    }
    if (-not $booted) { Fail 'bcdboot failed (see log above)' 'שגיאה בהכנת הדיסק לאתחול.' }

    # first-boot answers: name, time zone, Hebrew keyboard, Administrator password, skip all screens
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

    # SharedPC files + first-boot script (runs automatically as SYSTEM at the end of Windows setup)
    Log 'Copying the newest SharedPC files from GitHub into the virtual disk...'
    $gi = "${W}:\SharedPC-Install"
    New-Item -ItemType Directory -Path $gi -Force | Out-Null
    foreach ($f in 'setup.ps1', 'portal.ps1', 'update.ps1', 'version.txt', 'files.txt', 'install.bat', 'firstboot.ps1', 'tslogin.ps1') {
        if (-not (Download "$RepoRaw/$f" (Join-Path $gi $f))) { Fail "Could not download $f from GitHub" 'לא הצלחתי להוריד את קבצי המערכת מ-GitHub.' }
    }
    @{ InviteCode = [string]$state.InviteCode } | ConvertTo-Json | Set-Content (Join-Path $gi 'firstboot.json') -Encoding ASCII
    New-Item -ItemType Directory -Path "${W}:\Windows\Setup\Scripts" -Force | Out-Null
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SharedPC-Install\firstboot.ps1`r`n" |
        Set-Content "${W}:\Windows\Setup\Scripts\SetupComplete.cmd" -Encoding ASCII

    # make the system partition a real (hidden) EFI partition
    Remove-PartitionAccessPath -DiskNumber $n -PartitionNumber $sys.PartitionNumber -AccessPath "${S}:\"
    Set-Partition -DiskNumber $n -PartitionNumber $sys.PartitionNumber -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Dismount-DiskImage -ImagePath $Vhd | Out-Null
    Set-StateValue $state 'DiskReady' $true
    Log 'Virtual disk ready'
} else { Log 'Virtual disk already built' }

# ---------- 5. create and start the VM ----------
$vmList = (& $script:VBM list vms) -join "`n"
if ($vmList -notmatch "`"$VMName`"") {
    $memMB = if ($ramGB -ge 24) { 12288 } elseif ($ramGB -ge 16) { 8192 } elseif ($ramGB -ge 12) { 6144 } else { 4096 }
    $cpus  = [math]::Max(2, [math]::Min(6, [int]($cpu.NumberOfLogicalProcessors / 2)))
    Log "Creating VirtualBox VM '$VMName' with $([int]($memMB/1024))GB RAM and $cpus processors..."
    VBox createvm --name $VMName --ostype Windows2022_64 --register
    VBox modifyvm $VMName --firmware efi --memory $memMB --cpus $cpus --ioapic on --vram 128 --graphicscontroller vboxsvga --nic1 nat --nictype1 82540EM
    VBox modifyvm $VMName --natpf1 "portal,tcp,127.0.0.1,$PortalPort,,8080"
    VBox modifyvm $VMName --natpf1 "rdp,tcp,127.0.0.1,$RdpPort,,3389"
    VBox storagectl $VMName --name SATA --add sata --controller IntelAhci --portcount 1 --hostiocache on
    VBox storageattach $VMName --storagectl SATA --port 0 --device 0 --type hdd --medium $Vhd
}

# a task that starts the VM in the background every time you log in to this computer (also used right now)
$me2 = "$env:USERDOMAIN\$env:USERNAME"
$act = New-ScheduledTaskAction -Execute $script:VBM -Argument "startvm $VMName --type headless"
$trg = New-ScheduledTaskTrigger -AtLogOn -User $me2
$trg.Delay = 'PT30S'
$prn = New-ScheduledTaskPrincipal -UserId $me2 -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $StartTask -Action $act -Trigger $trg -Principal $prn -Force | Out-Null

$running = (& $script:VBM list runningvms) -join "`n"
if ($running -notmatch "`"$VMName`"") { Log 'Starting the VM in the background...'; VBox startvm $VMName --type headless }

# ---------- 6. wait for Windows + SharedPC inside the VM ----------
Log 'Waiting for Windows inside the VM to finish its first start and install SharedPC (10-25 minutes)...'
$deadline = (Get-Date).AddMinutes(50); $st = $null
while ((Get-Date) -lt $deadline) {
    $st = Get-SetupStatus
    if ($st -and $st.firstbootDone) { break }
    Start-Sleep -Seconds 20
}
if (-not ($st -and $st.firstbootDone)) {
    Fail 'SharedPC inside the VM did not respond within 50 minutes' 'המחשב המשותף לא סיים לעלות בזמן. אפשר להריץ שוב את ההתקנה, היא ממשיכה מאותה נקודה.'
}
Log "SharedPC portal is running inside the VM (version $($st.version))"

# ---------- 7. Tailscale login (so your friend can connect from anywhere) ----------
$tsIp = $st.tailscaleIp
if (-not $tsIp) {
    $opened = $false
    $deadline = (Get-Date).AddMinutes(30)
    while (-not $tsIp -and (Get-Date) -lt $deadline) {
        $st = Get-SetupStatus
        if ($st) {
            $tsIp = $st.tailscaleIp
            if (-not $tsIp -and $st.loginUrl -and -not $opened) {
                Log 'WAITING FOR YOU: log in to Tailscale in the browser window that just opened'
                Start-Process $st.loginUrl
                $opened = $true
                Popup "נפתח דף התחברות של Tailscale בדפדפן.`n`nהתחבר עם החשבון שלך (למשל Google) ואשר את המחשב 'sharedpc'.`nההתקנה תמשיך לבד ברגע שתסיים." | Out-Null
            }
        }
        if (-not $tsIp) { Start-Sleep -Seconds 5 }
    }
}
if ($tsIp) { Log "Tailscale connected: $tsIp" } else { Log 'Tailscale login not completed yet - the portal works from this computer; run the installer again later to finish Tailscale' }

# ---------- 8. done ----------
@"
SharedPC - פרטים חשובים (שמור את הקובץ הזה)
=============================================
פורטל מהמחשב הזה:                http://localhost:$PortalPort
פורטל לחבר (דרך Tailscale):       $(if ($tsIp) { "http://${tsIp}:8080" } else { 'עוד לא מחובר ל-Tailscale' })
קוד הזמנה ליצירת משתמשים:          $($state.InviteCode)

משתמש מנהל של המחשב המשותף (לתחזוקה בלבד):
  שם משתמש: Administrator
  סיסמה:     $AdminPw

המחשב המשותף עולה לבד בכל פעם שאתה מתחבר ל-Windows.
ניהול: תוכנת VirtualBox ← SharedPC
"@ | Set-Content $SecretFile -Encoding UTF8

Log "ALL DONE. Portal: http://localhost:$PortalPort  |  Friend: $(if ($tsIp) { "http://${tsIp}:8080" } else { 'n/a' })  |  details in $SecretFile"

$ans = Popup "כדי שהמחשב המשותף יהיה זמין כל הזמן, המחשב הזה לא צריך להיכנס למצב שינה כשהוא מחובר לחשמל.`n`nלבטל מצב שינה (בחיבור לחשמל)?" 'YesNo'
if ($ans -eq 'Yes') { & powercfg.exe /change standby-timeout-ac 0; & powercfg.exe /change hibernate-timeout-ac 0; Log 'Sleep on AC power disabled' }
Start-Process "http://localhost:$PortalPort"
Start-Process notepad.exe $SecretFile
Popup "הכל מוכן! 🎉`n`nהפורטל נפתח בדפדפן.`nקוד ההזמנה והסיסמאות נשמרו בקובץ שנפתח עכשיו." | Out-Null
