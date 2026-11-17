# SharedPC auto-updater
# Runs as SYSTEM: at startup, every day, and when "check for updates" is pressed in the portal.
# Downloads the newest files from GitHub only if version.txt there is newer than the local one.

$ErrorActionPreference = 'Stop'
$Root    = 'C:\SharedPC'
$LogFile = Join-Path $Root 'update.log'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log([string]$msg) {
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) -Encoding UTF8
}

function Get-Remote([string]$url) {
    # cache-busting so GitHub's CDN gives the newest copy
    $u = $url + '?t=' + [DateTime]::UtcNow.Ticks
    (Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Cache-Control' = 'no-cache' }).Content
}

try {
    $cfg    = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $repo   = if ($cfg.UpdateRepo)   { [string]$cfg.UpdateRepo }   else { 'MaykoDev50/SharedPC' }
    $branch = if ($cfg.UpdateBranch) { [string]$cfg.UpdateBranch } else { 'main' }
    $base   = "https://raw.githubusercontent.com/$repo/$branch"

    $localFile = Join-Path $Root 'version.txt'
    $local  = if (Test-Path $localFile) { [version]((Get-Content $localFile -Raw).Trim()) } else { [version]'0.0.0' }
    $remote = [version]((Get-Remote "$base/version.txt").Trim())

    if ($remote -le $local) { Write-Log "Up to date ($local)"; exit 0 }
    Write-Log "Updating $local -> $remote"

    # files.txt = list of files to install (one per line)
    $files = (Get-Remote "$base/files.txt") -split "`r?`n" |
             ForEach-Object { $_.Trim() } |
             Where-Object { $_ -and $_ -notmatch '^#' -and $_ -match '^[A-Za-z0-9._-]+$' }

    # download everything to a temp folder first; install only if ALL downloads are valid
    $tmp = Join-Path $env:TEMP ('SharedPC-update-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    foreach ($f in $files) {
        $dest = Join-Path $tmp $f
        Invoke-WebRequest "$base/$f`?t=$([DateTime]::UtcNow.Ticks)" -UseBasicParsing -TimeoutSec 60 -OutFile $dest
        if ((Get-Item $dest).Length -eq 0) { throw "Downloaded file is empty: $f" }
        if ($f -like '*.ps1') {
            $errs = $null
            [System.Management.Automation.Language.Parser]::ParseFile($dest, [ref]$null, [ref]$errs) | Out-Null
            if ($errs) { throw "Syntax error in $f : $($errs[0].Message)" }
        }
    }

    # install
    $backup = Join-Path $Root "backup-$local"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($f in $files) {
        $cur = Join-Path $Root $f
        if (Test-Path $cur) { Copy-Item $cur $backup -Force }
        Copy-Item (Join-Path $tmp $f) $cur -Force
    }

    # optional one-time system changes that come with this version
    $migrate = Join-Path $Root 'migrate.ps1'
    if ('migrate.ps1' -in $files -and (Test-Path $migrate)) {
        Write-Log 'Running migrate.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $migrate *>> $LogFile
    }

    Set-Content $localFile $remote.ToString() -Encoding ASCII
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    # restart the portal so the new version is live
    Stop-ScheduledTask  -TaskName 'SharedPC Portal' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName 'SharedPC Portal'
    Write-Log "Updated to $remote"
}
catch {
    Write-Log ('Update failed: ' + $_.Exception.Message)
    exit 1
}
