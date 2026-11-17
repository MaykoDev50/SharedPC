# SharedPC Connect - type a username, get the shared computer's desktop. Same app for both of you.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$AppDir  = Split-Path -Parent $PSCommandPath
$DataDir = Join-Path $env:APPDATA 'SharedPC'
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$PrefFile = Join-Path $DataDir 'prefs.json'

# ---------- where is the shared computer? ----------
$targets = @()
$cfgFile = Join-Path $AppDir 'connect.json'
$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
# on the host computer the VM is on localhost (Remote Desktop refuses 127.0.0.1, so RDP uses 127.0.0.2)
$targets += [pscustomobject]@{ portal = 'http://127.0.0.1:18080'; rdp = '127.0.0.2:13389' }
if ($cfg -and $cfg.targets) { $targets += $cfg.targets }
$targets += [pscustomobject]@{ portal = 'http://sharedpc:8080'; rdp = 'sharedpc' }

function Find-Target {
    foreach ($t in $targets) {
        try { if ((Invoke-WebRequest "$($t.portal)/setup-status" -UseBasicParsing -TimeoutSec 4).StatusCode -eq 200) { return $t } } catch {}
        try { if ((Invoke-WebRequest "$($t.portal)/" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200) { return $t } } catch {}
    }
    return $null
}
function Get-Invite {
    $f = 'C:\SharedPC-Host\state.json'
    if (Test-Path $f) { try { return [string](Get-Content $f -Raw | ConvertFrom-Json).InviteCode } catch {} }
    if ($cfg -and $cfg.invite) { return [string]$cfg.invite }
    return ''
}
# must match Get-QuickPassword in the portal
function Get-QuickPassword([string]$u, [string]$invite) {
    $h = New-Object System.Security.Cryptography.HMACSHA256 (,[Text.Encoding]::UTF8.GetBytes($invite))
    $b = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($u.ToLowerInvariant()))
    ([Convert]::ToBase64String($b).Substring(0, 16) -replace '[+/=]', 'x') + 'Aa1!'
}

function Invoke-Quick($t, $u, $invite) {
    $body = 'username=' + [uri]::EscapeDataString($u) + '&invite=' + [uri]::EscapeDataString($invite)
    try {
        Invoke-WebRequest "$($t.portal)/api/quick" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing -TimeoutSec 30 | Out-Null
        return 'ok'
    } catch {
        $resp = $_.Exception.Response
        if (-not $resp) { return 'nonet' }
        if ([int]$resp.StatusCode -eq 404) { return 'old' }
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $j = $sr.ReadToEnd(); $sr.Close()
        try { return [string]($j | ConvertFrom-Json).error } catch { return 'הכניסה נכשלה.' }
    }
}

function Start-Desktop($t, $u, $p) {
    $hostOnly = ($t.rdp -split ':')[0]
    & cmdkey.exe "/generic:TERMSRV/$hostOnly" "/user:SHAREDPC\$u" "/pass:$p" | Out-Null
    $rdpFile = Join-Path $DataDir "SharedPC-$u.rdp"
    @(
        "full address:s:$($t.rdp)", "username:s:SHAREDPC\$u",
        'screen mode id:i:2', 'use multimon:i:0', 'session bpp:i:32', 'dynamic resolution:i:1', 'smart sizing:i:1',
        'audiomode:i:0', 'redirectclipboard:i:1', 'redirectprinters:i:0', 'autoreconnection enabled:i:1',
        'authentication level:i:0', 'prompt for credentials:i:0', 'enablecredsspsupport:i:1'
    ) -join "`r`n" | Set-Content $rdpFile -Encoding ASCII
    Start-Process mstsc.exe "`"$rdpFile`""
}

$prefs = if (Test-Path $PrefFile) { Get-Content $PrefFile -Raw | ConvertFrom-Json } else { $null }

# ---------- window ----------
$bg = [Drawing.Color]::FromArgb(15, 23, 42); $card = [Drawing.Color]::FromArgb(30, 41, 59)
$fg = [Drawing.Color]::FromArgb(226, 232, 240); $muted = [Drawing.Color]::FromArgb(148, 163, 184)
$form = New-Object Windows.Forms.Form
$form.Text = 'המחשב המשותף'; $form.Size = New-Object Drawing.Size(420, 360)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = New-Object Drawing.Font('Segoe UI', 11)
$form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true

function Add-Label($text, $y, $size, $color, $bold = $false) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point(25, $y); $l.Size = New-Object Drawing.Size(355, ($size * 2 + 8))
    $l.ForeColor = $color
    $l.Font = New-Object Drawing.Font('Segoe UI', $size, $(if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
    $form.Controls.Add($l); $l
}
Add-Label '🖥️ המחשב המשותף' 18 18 $fg $true | Out-Null
$status = Add-Label 'מחפש את המחשב המשותף…' 60 10 $muted
Add-Label 'השם שלך (באנגלית)' 100 10 $muted | Out-Null

$user = New-Object Windows.Forms.TextBox
$user.Location = New-Object Drawing.Point(25, 125); $user.Size = New-Object Drawing.Size(355, 32)
$user.BackColor = $card; $user.ForeColor = $fg; $user.BorderStyle = 'FixedSingle'; $user.RightToLeft = 'No'
$user.Font = New-Object Drawing.Font('Segoe UI', 13)
if ($prefs) { $user.Text = [string]$prefs.user }
$form.Controls.Add($user)

$inviteLbl = Add-Label 'קוד הזמנה' 168 10 $muted
$invite = New-Object Windows.Forms.TextBox
$invite.Location = New-Object Drawing.Point(25, 192); $invite.Size = New-Object Drawing.Size(355, 30)
$invite.BackColor = $card; $invite.ForeColor = $fg; $invite.BorderStyle = 'FixedSingle'; $invite.RightToLeft = 'No'
$invite.Text = Get-Invite
$form.Controls.Add($invite)
if ($invite.Text) { $inviteLbl.Visible = $false; $invite.Visible = $false }

$go = New-Object Windows.Forms.Button
$go.Text = 'היכנס'; $go.Location = New-Object Drawing.Point(25, 240); $go.Size = New-Object Drawing.Size(355, 48)
$go.BackColor = [Drawing.Color]::FromArgb(37, 99, 235); $go.ForeColor = [Drawing.Color]::White
$go.FlatStyle = 'Flat'; $go.FlatAppearance.BorderSize = 0
$go.Font = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$form.Controls.Add($go); $form.AcceptButton = $go

$script:target = $null
function Refresh-Target {
    $status.Text = 'מחפש את המחשב המשותף…'; $status.ForeColor = $muted; $form.Refresh()
    $script:target = Find-Target
    if ($script:target) {
        $status.Text = '✅ המחשב המשותף זמין'; $status.ForeColor = [Drawing.Color]::FromArgb(134, 239, 172)
        try { Invoke-WebRequest "$($script:target.portal)/update" -Method Post -UseBasicParsing -TimeoutSec 3 | Out-Null } catch {}
    } else {
        $status.Text = '❌ לא מוצא את המחשב המשותף (Tailscale מחובר?)'
        $status.ForeColor = [Drawing.Color]::FromArgb(252, 165, 165)
    }
}

$go.Add_Click({
    $u = $user.Text.Trim(); $code = $invite.Text.Trim()
    if ($u -notmatch '^[A-Za-z0-9._-]{3,20}$') {
        [Windows.Forms.MessageBox]::Show('כתוב שם באנגלית, 3 עד 20 תווים (בלי רווחים).', 'המחשב המשותף') | Out-Null; return
    }
    if (-not $code) { $inviteLbl.Visible = $true; $invite.Visible = $true; [Windows.Forms.MessageBox]::Show('צריך קוד הזמנה.', 'המחשב המשותף') | Out-Null; return }
    if (-not $script:target) { Refresh-Target }
    if (-not $script:target) { [Windows.Forms.MessageBox]::Show('המחשב המשותף לא זמין כרגע.', 'המחשב המשותף') | Out-Null; return }

    $go.Enabled = $false; $go.Text = 'מתחבר…'; $form.Refresh()
    $r = Invoke-Quick $script:target $u $code
    if ($r -eq 'old' -or $r -eq 'nonet') {
        # the shared computer is on an older version or restarting after an update - wait for it
        $status.Text = 'המחשב המשותף מתעדכן, עוד רגע…'; $form.Refresh()
        for ($i = 0; $i -lt 18 -and ($r -eq 'old' -or $r -eq 'nonet'); $i++) {
            for ($k = 0; $k -lt 20; $k++) { Start-Sleep -Milliseconds 500; [Windows.Forms.Application]::DoEvents() }
            try { Invoke-WebRequest "$($script:target.portal)/update" -Method Post -UseBasicParsing -TimeoutSec 3 | Out-Null } catch {}
            $r = Invoke-Quick $script:target $u $code
        }
        if ($r -eq 'old' -or $r -eq 'nonet') { $r = 'המחשב המשותף עוד מתעדכן. נסה שוב בעוד דקה.' }
        $status.Text = '✅ המחשב המשותף זמין'
    }
    $go.Enabled = $true; $go.Text = 'היכנס'
    if ($r -ne 'ok') { [Windows.Forms.MessageBox]::Show($r, 'המחשב המשותף') | Out-Null; return }

    @{ user = $u } | ConvertTo-Json | Set-Content $PrefFile -Encoding UTF8
    Start-Desktop $script:target $u (Get-QuickPassword $u $code)
    $form.Close()
})

$form.Add_Shown({ Refresh-Target })
[void]$form.ShowDialog()
