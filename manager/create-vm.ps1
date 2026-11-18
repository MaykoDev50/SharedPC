# Creates ONE virtual computer for one person (runs in its own window, started by SharedPC-Manager).
# Windows Server 2022 is applied straight onto a new virtual disk, the person's user is created,
# and Remote Desktop is opened on the chosen port of this computer.
param(
    [Parameter(Mandatory)] [string]$Name,       # e.g. dani  ->  VirtualBox VM "PC-dani"
    [Parameter(Mandatory)] [string]$User,
    [Parameter(Mandatory)] [string]$PasswordFile, # json with the password (deleted when done)
    [Parameter(Mandatory)] [int]$DiskGB,        # size of drive C: as the person sees it, Windows included (min 20)
    [Parameter(Mandatory)] [int]$RamGB,
    [Parameter(Mandatory)] [int]$Port,
    [switch]$Admin
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$HostDir = 'C:\SharedPC-Host'
. (Join-Path $PSScriptRoot 'common.ps1')

$VmName = "PC-$Name"
$VmDir  = Join-Path $HostDir "vms\$Name"
New-Item -ItemType Directory -Path $VmDir -Force | Out-Null
$LogFile = Join-Path $VmDir 'create.log'
function Log([string]$m) { $l = '{0:HH:mm:ss}  {1}' -f (Get-Date), $m; Write-Host $l; Add-Content $LogFile $l -Encoding UTF8 }
$Host.UI.RawUI.WindowTitle = "Creating $VmName - do not close"

$secret = Get-Content $PasswordFile -Raw | ConvertFrom-Json
Remove-Item $PasswordFile -Force
$Password = [string]$secret.password
$AdminName = 'pcadmin' + (Get-Random -Minimum 1000 -Maximum 9999)
$AdminPw   = New-RandomPassword
Update-VmRecord $Name @{ adminName = $AdminName; adminPassword = $AdminPw; status = 'creating'; step = 'מתחיל' }

$Iso = Join-Path $HostDir 'WindowsServer2022.iso'
$Vhd = Join-Path $VmDir "$VmName.vhd"
$mounted = @()
trap {
    Log "FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    foreach ($m in $mounted) { try { Dismount-DiskImage -ImagePath $m -ErrorAction SilentlyContinue | Out-Null } catch {} }
    Update-VmRecord $Name @{ status = 'failed'; step = $_.Exception.Message }
    exit 1
}
if (-not (Test-Path $Iso)) { throw "Windows Server ISO not found at $Iso" }

# ---------- 1. virtual disk with Windows on it (one build at a time) ----------
$build = New-Object System.Threading.Mutex($false, 'Global\SharedPCBuild')
Log 'Waiting for other builds to finish (if any)...'
Update-VmRecord $Name @{ step = 'ממתין לתור' }
[void]$build.WaitOne()
try {
    Update-VmRecord $Name @{ step = 'בונה דיסק' }
    # the virtual disk can grow up to 2TB (it only takes real space as it fills); drive C: is made exactly $DiskGB GB,
    # so the person sees exactly what he paid for. Changing the size later = resizing C: inside (no restart).
    if ($DiskGB -lt 20) { $DiskGB = 20 }
    $sizeMB = [math]::Max(2040, $DiskGB + 2) * 1024
    Log "Creating virtual disk (drive C: = $DiskGB GB, Windows included)..."
    if (Test-Path $Vhd) { Dismount-DiskImage -ImagePath $Vhd -ErrorAction SilentlyContinue | Out-Null; Remove-Item $Vhd -Force }
    $dp = Join-Path $VmDir 'diskpart.txt'
    "create vdisk file=`"$Vhd`" maximum=$sizeMB type=expandable" | Set-Content $dp -Encoding ASCII
    & diskpart.exe /s $dp | Out-Null
    if (-not (Test-Path $Vhd)) { throw 'diskpart could not create the virtual disk' }
    $disk = Mount-DiskImage -ImagePath $Vhd -NoDriveLetter -PassThru | Get-Disk; $mounted += $Vhd
    $n = $disk.Number
    Initialize-Disk -Number $n -PartitionStyle GPT
    $sys = New-Partition -DiskNumber $n -Size 300MB -AssignDriveLetter
    Format-Volume -Partition $sys -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    New-Partition -DiskNumber $n -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
    $win = New-Partition -DiskNumber $n -Size ([uint64]$DiskGB * 1GB) -AssignDriveLetter
    Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $S = (Get-Partition -DiskNumber $n -PartitionNumber $sys.PartitionNumber).DriveLetter
    $W = (Get-Partition -DiskNumber $n -PartitionNumber $win.PartitionNumber).DriveLetter

    Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null
    $img = Mount-DiskImage -ImagePath $Iso -PassThru; $mounted += $Iso
    $I = ($img | Get-Volume).DriveLetter
    $wim = if (Test-Path "${I}:\sources\install.wim") { "${I}:\sources\install.wim" } else { "${I}:\sources\install.esd" }
    $pick = Get-WindowsImage -ImagePath $wim | Where-Object { $_.ImageName -match 'Standard' -and $_.ImageName -match 'Desktop' } | Select-Object -First 1
    Log "Installing '$($pick.ImageName)' (2-5 minutes)..."
    Update-VmRecord $Name @{ step = 'מתקין Windows' }
    Expand-WindowsImage -ImagePath $wim -Index $pick.ImageIndex -ApplyPath "${W}:\" | Out-Null
    Dismount-DiskImage -ImagePath $Iso | Out-Null; $mounted = @($Vhd)

    $booted = $false
    foreach ($b in "$env:SystemRoot\System32\bcdboot.exe", "${W}:\Windows\System32\bcdboot.exe") {
        $ErrorActionPreference = 'Continue'
        $bo = & $b "${W}:\Windows" /s "${S}:" /f UEFI 2>&1 | Out-String; $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Log "bcdboot ($b): $code $($bo.Trim())"
        if ($code -eq 0 -and (Test-Path "${S}:\EFI\Boot\bootx64.efi")) { $booted = $true; break }
    }
    if (-not $booted) { throw 'bcdboot failed' }

    New-Item -ItemType Directory -Path "${W}:\Windows\Panther" -Force | Out-Null
    $compName = ('PC-' + ($Name -replace '[^A-Za-z0-9-]', '')).ToUpper()
    if ($compName.Length -gt 15) { $compName = $compName.Substring(0, 15) }
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$compName</ComputerName>
      <TimeZone>Israel Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409;040d:0000040d</InputLocale>
      <SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>he-IL</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE></OOBE>
      <UserAccounts><AdministratorPassword><Value>$AdminPw</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
    </component>
  </settings>
</unattend>
"@ | Set-Content "${W}:\Windows\Panther\unattend.xml" -Encoding UTF8 -Force

    # first-boot script inside the new computer
    New-Item -ItemType Directory -Path "${W}:\Setup-Client" -Force | Out-Null
    @{ user = $User; password = $Password; admin = [bool]$Admin; adminName = $AdminName; diskGB = $DiskGB } | ConvertTo-Json |
        Set-Content "${W}:\Setup-Client\client.json" -Encoding UTF8
    Copy-Item (Join-Path $PSScriptRoot 'setup-client.ps1') "${W}:\Setup-Client\setup-client.ps1" -Force
    if (Test-Path 'C:\SharedPC-Host\wallpaper.jpg') { Copy-Item 'C:\SharedPC-Host\wallpaper.jpg' "${W}:\Setup-Client\wallpaper.jpg" -Force }
    New-Item -ItemType Directory -Path "${W}:\Windows\Setup\Scripts" -Force | Out-Null
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Setup-Client\setup-client.ps1`r`n" |
        Set-Content "${W}:\Windows\Setup\Scripts\SetupComplete.cmd" -Encoding ASCII

    Remove-PartitionAccessPath -DiskNumber $n -PartitionNumber $sys.PartitionNumber -AccessPath "${S}:\"
    Set-Partition -DiskNumber $n -PartitionNumber $sys.PartitionNumber -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Dismount-DiskImage -ImagePath $Vhd | Out-Null; $mounted = @()
} finally { $build.ReleaseMutex() }

# ---------- 2. the virtual machine ----------
Update-VmRecord $Name @{ step = 'יוצר מכונה' }
Log "Creating VM $VmName ($RamGB GB RAM, Remote Desktop on port $Port)..."
VBox createvm --name $VmName --ostype Windows2022_64 --basefolder $VmDir --register
VBox modifyvm $VmName --firmware efi --memory ($RamGB * 1024) --cpus 2 --ioapic on --vram 128 --graphicscontroller vboxsvga --nic1 nat --nictype1 82540EM
VBox modifyvm $VmName --natpf1 "rdp,tcp,,$Port,,3389"
VBox storagectl $VmName --name SATA --add sata --controller IntelAhci --portcount 2 --hostiocache on
VBox storageattach $VmName --storagectl SATA --port 0 --device 0 --type hdd --medium $Vhd
# VirtualBox Guest Additions: lets this manager change password / GB later
$gaIso = Join-Path (Split-Path $script:VBM) 'VBoxGuestAdditions.iso'
$gaAttached = $false
if (Test-Path $gaIso) {
    try { VBox storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $gaIso | Out-Null; $gaAttached = $true }
    catch { Log "Guest Additions ISO not attached: $($_.Exception.Message)" }
} else { Log "Guest Additions ISO not found at $gaIso" }

Get-NetFirewallRule -DisplayName "SharedPC $VmName" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "SharedPC $VmName" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null

VBox startvm $VmName --type headless

# ---------- 3. wait until Remote Desktop answers ----------
Update-VmRecord $Name @{ step = 'Windows עולה בפעם הראשונה' }
Log 'Waiting for Windows to finish its first start (5-15 minutes)...'
$deadline = (Get-Date).AddMinutes(40)
while ((Get-Date) -lt $deadline -and -not (Test-Rdp $Port)) { Start-Sleep -Seconds 15 }
if (-not (Test-Rdp $Port)) { throw 'Remote Desktop did not come up within 40 minutes' }
# wait until the management channel (Guest Additions) works - that also means the user and settings are done
Update-VmRecord $Name @{ step = 'מסיים הגדרות' }
$agent = $false
$deadline = if ($gaAttached) { (Get-Date).AddMinutes(25) } else { Get-Date }   # no Guest Additions -> nothing to wait for
while ((Get-Date) -lt $deadline) {
    $ErrorActionPreference = 'Continue'
    $o = & $script:VBM guestcontrol $VmName run --exe 'C:\Windows\System32\cmd.exe' --username $AdminName --password $AdminPw --wait-stdout --timeout 20000 -- cmd.exe /c echo SHAREDPC-OK 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    if ($o -match 'SHAREDPC-OK') { $agent = $true; break }
    Start-Sleep -Seconds 20
}
Log "Management channel: $agent"
try { VBox storageattach $VmName --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive | Out-Null } catch {}
if (-not $agent) { Start-Sleep -Seconds 60 }
Update-VmRecord $Name @{ status = 'ready'; step = ''; agent = $agent }
$opened = Open-RouterPort $Port
Log "Router port ${Port}: $opened"
Log "READY. Remote Desktop: <your IP>:$Port  user: $User"
Start-Sleep -Seconds 3
