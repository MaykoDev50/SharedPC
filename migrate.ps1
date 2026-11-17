# SharedPC migration (runs as SYSTEM after an update; safe to run many times)
# Everyone shares the SAME Desktop, Documents, Downloads, Pictures, Music and Videos (C:\Shared\...),
# and Google Chrome is installed for all users.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # PowerShell 5.1 downloads are extremely slow with the progress bar on
$Log = 'C:\SharedPC\migrate.log'
function L([string]$m) { Add-Content $Log ('{0:yyyy-MM-dd HH:mm:ss}  migrate: {1}' -f (Get-Date), $m) -Encoding UTF8 }

$folders = [ordered]@{
    'Desktop'                                = 'Desktop'
    'Personal'                               = 'Documents'
    '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'
    '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}' = 'Downloads'
    'My Pictures'                            = 'Pictures'
    'My Music'                               = 'Music'
    'My Video'                               = 'Videos'
}

# 1. shared folders
foreach ($n in ($folders.Values | Select-Object -Unique)) { New-Item -ItemType Directory -Path "C:\Shared\$n" -Force | Out-Null }
& icacls.exe 'C:\Shared' /grant '*S-1-5-32-555:(OI)(CI)M' '*S-1-5-32-544:(OI)(CI)F' /C /Q 2>&1 | Out-Null

function Set-Redirect([string]$root) {
    $k = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
    foreach ($name in $folders.Keys) {
        New-ItemProperty -Path $k -Name $name -Value "C:\Shared\$($folders[$name])" -PropertyType ExpandString -Force | Out-Null
    }
}
function With-Hive([string]$file, [scriptblock]$do) {
    & reg.exe load 'HKU\SharedPCTmp' $file 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { L "could not load $file"; return }
    try { & $do 'Registry::HKEY_USERS\SharedPCTmp' } finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload 'HKU\SharedPCTmp' 2>&1 | Out-Null
    }
}

# 2. new users (profiles are copied from the Default profile)
With-Hive 'C:\Users\Default\NTUSER.DAT' { param($r) Set-Redirect $r }
L 'default profile now uses the shared folders'

# 3. users that already exist
$names = @(Get-LocalGroupMember -Group 'SharedPC-Users' -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -split '\\')[-1] })
foreach ($u in $names) {
    $lu = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
    if (-not $lu) { continue }
    $sid = $lu.SID.Value
    $prof = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
    if (Test-Path "Registry::HKEY_USERS\$sid") { Set-Redirect "Registry::HKEY_USERS\$sid" }        # logged in right now
    elseif ($prof -and (Test-Path "$prof\NTUSER.DAT")) { With-Hive "$prof\NTUSER.DAT" { param($r) Set-Redirect $r } }
    else { continue }                                                                              # never logged in: gets Default
    # bring over what was already on that user's own desktop / folders (nothing is overwritten or deleted)
    if ($prof) {
        foreach ($pair in @(@('Desktop', 'Desktop'), @('Documents', 'Documents'), @('Downloads', 'Downloads'), @('Pictures', 'Pictures'), @('Music', 'Music'), @('Videos', 'Videos'))) {
            $src = Join-Path $prof $pair[0]
            if (Test-Path $src) { & robocopy.exe $src "C:\Shared\$($pair[1])" /E /XC /XN /XO /XF desktop.ini /R:0 /W:0 /NFL /NDL /NJH /NJS 2>&1 | Out-Null }
        }
    }
    L "user $u now uses the shared folders"
}

# 4. restart Explorer for logged-in users so the change shows immediately (Windows restarts it by itself)
Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
    Where-Object { ($_.UserName -split '\\')[-1] -in $names } |
    Stop-Process -Force -ErrorAction SilentlyContinue

# per-user storage limits (set from the host's "Manage users")
& fsutil.exe quota enforce C: 2>&1 | Out-Null

# 5. Google Chrome for everyone (one installation, Downloads go to the shared folder)
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (-not (Test-Path $chrome)) {
    $msi = Join-Path $env:TEMP 'chrome.msi'
    try {
        & curl.exe -L -s --fail --retry 3 -o $msi 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
        if ($LASTEXITCODE -ne 0) { throw "download failed ($LASTEXITCODE)" }
        Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
        L 'Google Chrome installed'
    } catch { L "Chrome install failed: $($_.Exception.Message)" }
}
