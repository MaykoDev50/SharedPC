# Connects the shared PC to Tailscale. Runs at startup; does nothing once connected.
$exe = 'C:\Program Files\Tailscale\tailscale.exe'
$out = 'C:\SharedPC\tailscale-login.txt'
for ($i = 0; $i -lt 60 -and -not (Test-Path $exe); $i++) { Start-Sleep -Seconds 5 }
if (-not (Test-Path $exe)) { exit 1 }
Start-Sleep -Seconds 10
if (& $exe ip -4 2>$null) { Remove-Item $out -ErrorAction SilentlyContinue; exit 0 }

$log = 'C:\SharedPC\tailscale-up.txt'
$p = Start-Process $exe -ArgumentList 'up', '--unattended', '--hostname=sharedpc' -WindowStyle Hidden -PassThru `
        -RedirectStandardError $log -RedirectStandardOutput "$log.out"
# publish the login link (the portal shows it to the host computer) and wait up to 2 hours
$deadline = (Get-Date).AddHours(2)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $txt = (Get-Content $log, "$log.out" -Raw -ErrorAction SilentlyContinue) -join ' '
    if ($txt -match '(https://login\.tailscale\.com/\S+)') { Set-Content $out $Matches[1] }
    if (& $exe ip -4 2>$null) { Remove-Item $out -ErrorAction SilentlyContinue; break }
}
if (-not $p.HasExited) { $p | Stop-Process -ErrorAction SilentlyContinue }
