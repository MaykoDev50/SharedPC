# SharedPC Connect - one app for both of you: create a user, then connect to the shared computer's desktop.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Web
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$AppDir  = Split-Path -Parent $PSCommandPath
$DataDir = Join-Path $env:APPDATA 'SharedPC'
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$PrefFile = Join-Path $DataDir 'prefs.json'

# ---------- where is the shared computer? ----------
# connect.json (made for your friend) lists addresses; on the host computer localhost always works.
$targets = @()
$cfgFile = Join-Path $AppDir 'connect.json'
$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
if ($cfg -and $cfg.targets) { $targets += $cfg.targets }
$targets += [pscustomobject]@{ portal = 'http://127.0.0.1:18080'; rdp = '127.0.0.1:13389' }
$targets += [pscustomobject]@{ portal = 'http://sharedpc:8080';   rdp = 'sharedpc' }

function Find-Target {
    foreach ($t in $targets) {
        try {
            $r = Invoke-WebRequest "$($t.portal)/" -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { return $t }
        } catch {}
    }
    return $null
}

function Get-InviteFromHost {
    $f = 'C:\SharedPC-Host\state.json'
    if (Test-Path $f) { try { return [string](Get-Content $f -Raw | ConvertFrom-Json).InviteCode } catch {} }
    if ($cfg -and $cfg.invite) { return [string]$cfg.invite }
    return ''
}

function New-User($t, $u, $p, $code) {
    $body = 'username=' + [uri]::EscapeDataString($u) + '&password=' + [uri]::EscapeDataString($p) +
            '&password2=' + [uri]::EscapeDataString($p) + '&invite=' + [uri]::EscapeDataString($code)
    try {
        Invoke-WebRequest "$($t.portal)/create" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded; charset=utf-8' `
            -UseBasicParsing -TimeoutSec 30 | Out-Null
        return $null
    } catch {
        $resp = $_.Exception.Response
        if (-not $resp) { return "אין חיבור למחשב המשותף: $($_.Exception.Message)" }
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $html = $sr.ReadToEnd(); $sr.Close()
        if ($html -match "class='err'>(.*?)</div>") { return [System.Web.HttpUtility]::HtmlDecode($Matches[1]) }
        return 'יצירת המשתמש נכשלה.'
    }
}

function Start-Desktop($t, $u, $p) {
    $hostOnly = ($t.rdp -split ':')[0]
    # save the password in Windows Credential Manager so Remote Desktop logs in by itself
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

function Save-Prefs($u) { @{ user = $u } | ConvertTo-Json | Set-Content $PrefFile -Encoding UTF8 }
$prefs = if (Test-Path $PrefFile) { Get-Content $PrefFile -Raw | ConvertFrom-Json } else { $null }

# ---------- window ----------
$bg = [Drawing.Color]::FromArgb(15, 23, 42); $card = [Drawing.Color]::FromArgb(30, 41, 59)
$fg = [Drawing.Color]::FromArgb(226, 232, 240); $muted = [Drawing.Color]::FromArgb(148, 163, 184)
$blue = [Drawing.Color]::FromArgb(37, 99, 235)
$font = New-Object Drawing.Font('Segoe UI', 11)

$form = New-Object Windows.Forms.Form
$form.Text = 'המחשב המשותף'; $form.Size = New-Object Drawing.Size(440, 560)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = $font
$form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true

function Add-Label($text, $y, $size = 11, $color = $fg, $bold = $false) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point(30, $y); $l.Size = New-Object Drawing.Size(370, ($size * 2 + 6))
    $l.ForeColor = $color
    $l.Font = New-Object Drawing.Font('Segoe UI', $size, $(if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
    $form.Controls.Add($l); $l
}
function Add-Box($y, $pw = $false) {
    $b = New-Object Windows.Forms.TextBox
    $b.Location = New-Object Drawing.Point(30, $y); $b.Size = New-Object Drawing.Size(370, 30)
    $b.BackColor = $card; $b.ForeColor = $fg; $b.BorderStyle = 'FixedSingle'; $b.RightToLeft = 'No'
    if ($pw) { $b.UseSystemPasswordChar = $true }
    $form.Controls.Add($b); $b
}

Add-Label '🖥️ המחשב המשותף' 20 18 $fg $true | Out-Null
$status = Add-Label 'מחפש את המחשב המשותף…' 62 10 $muted

$tabLogin = New-Object Windows.Forms.RadioButton
$tabLogin.Text = 'כניסה'; $tabLogin.Location = New-Object Drawing.Point(250, 100); $tabLogin.Size = New-Object Drawing.Size(150, 30)
$tabLogin.Appearance = 'Button'; $tabLogin.TextAlign = 'MiddleCenter'; $tabLogin.FlatStyle = 'Flat'; $tabLogin.Checked = $true
$tabNew = New-Object Windows.Forms.RadioButton
$tabNew.Text = 'משתמש חדש'; $tabNew.Location = New-Object Drawing.Point(30, 100); $tabNew.Size = New-Object Drawing.Size(150, 30)
$tabNew.Appearance = 'Button'; $tabNew.TextAlign = 'MiddleCenter'; $tabNew.FlatStyle = 'Flat'
$form.Controls.AddRange(@($tabLogin, $tabNew))

Add-Label 'שם משתמש (באנגלית)' 145 10 $muted | Out-Null
$user = Add-Box 170
Add-Label 'סיסמה' 210 10 $muted | Out-Null
$pass = Add-Box 235 $true
$l2 = Add-Label 'אימות סיסמה' 275 10 $muted
$pass2 = Add-Box 300 $true
$l3 = Add-Label 'קוד הזמנה' 340 10 $muted
$invite = Add-Box 365
$invite.Text = Get-InviteFromHost
if ($prefs) { $user.Text = [string]$prefs.user }

$go = New-Object Windows.Forms.Button
$go.Location = New-Object Drawing.Point(30, 415); $go.Size = New-Object Drawing.Size(370, 44)
$go.BackColor = $blue; $go.ForeColor = [Drawing.Color]::White; $go.FlatStyle = 'Flat'; $go.FlatAppearance.BorderSize = 0
$go.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$form.Controls.Add($go)
$hint = Add-Label 'סיסמה: 8 תווים לפחות, עם אות גדולה, אות קטנה וספרה.' 470 9 $muted

$friendBtn = New-Object Windows.Forms.LinkLabel
$friendBtn.Text = 'יצירת קובץ התקנה לחבר'; $friendBtn.Location = New-Object Drawing.Point(30, 495); $friendBtn.Size = New-Object Drawing.Size(370, 22)
$friendBtn.LinkColor = [Drawing.Color]::FromArgb(147, 197, 253); $friendBtn.Visible = (Test-Path 'C:\SharedPC-Host')
$form.Controls.Add($friendBtn)

function Set-Mode {
    $new = $tabNew.Checked
    foreach ($c in $l2, $pass2, $l3, $invite, $hint) { $c.Visible = $new }
    $go.Text = if ($new) { 'צור משתמש והתחבר' } else { 'התחבר לשולחן העבודה' }
    $tabLogin.BackColor = if ($new) { $card } else { $blue }
    $tabNew.BackColor   = if ($new) { $blue } else { $card }
}
$tabLogin.Add_CheckedChanged({ Set-Mode }); $tabNew.Add_CheckedChanged({ Set-Mode }); Set-Mode
if (-not $prefs) { $tabNew.Checked = $true }

$script:target = $null
function Refresh-Target {
    $status.Text = 'מחפש את המחשב המשותף…'; $form.Refresh()
    $script:target = Find-Target
    if ($script:target) { $status.Text = '✅ המחשב המשותף זמין'; $status.ForeColor = [Drawing.Color]::FromArgb(134, 239, 172) }
    else {
        $status.Text = '❌ לא מוצא את המחשב המשותף. ודא ש-Tailscale מחובר.'
        $status.ForeColor = [Drawing.Color]::FromArgb(252, 165, 165)
    }
}

$go.Add_Click({
    $u = $user.Text.Trim(); $p = $pass.Text
    if (-not $script:target) { Refresh-Target }
    if (-not $script:target) { [Windows.Forms.MessageBox]::Show('המחשב המשותף לא זמין כרגע.', 'המחשב המשותף') | Out-Null; return }
    if (-not $u -or -not $p) { [Windows.Forms.MessageBox]::Show('צריך למלא שם משתמש וסיסמה.', 'המחשב המשותף') | Out-Null; return }
    if ($tabNew.Checked) {
        if ($p -cne $pass2.Text) { [Windows.Forms.MessageBox]::Show('הסיסמאות לא תואמות.', 'המחשב המשותף') | Out-Null; return }
        $go.Enabled = $false; $go.Text = 'יוצר משתמש…'; $form.Refresh()
        $err = New-User $script:target $u $p $invite.Text.Trim()
        $go.Enabled = $true; Set-Mode
        if ($err) { [Windows.Forms.MessageBox]::Show($err, 'המחשב המשותף') | Out-Null; return }
    }
    Save-Prefs $u
    Start-Desktop $script:target $u $p
    $form.Close()
})

$friendBtn.Add_LinkClicked({
    try {
        $st = Invoke-RestMethod 'http://127.0.0.1:18080/setup-status' -TimeoutSec 10
        if (-not $st.tailscaleIp) { [Windows.Forms.MessageBox]::Show('המחשב המשותף עוד לא מחובר ל-Tailscale. סיים את ההתחברות ל-Tailscale ונסה שוב.', 'המחשב המשותף') | Out-Null; return }
        $tmp = Join-Path $env:TEMP 'SharedPC-Connect'
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Copy-Item (Join-Path $AppDir 'SharedPC-Connect.ps1'), (Join-Path $AppDir 'SharedPC-Connect.bat') $tmp
        @{ targets = @(@{ portal = "http://$($st.tailscaleIp):8080"; rdp = [string]$st.tailscaleIp }); invite = (Get-InviteFromHost) } |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $tmp 'connect.json') -Encoding UTF8
        $zip = Join-Path ([Environment]::GetFolderPath('Desktop')) 'SharedPC-Connect-לחבר.zip'
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip
        [Windows.Forms.MessageBox]::Show("הקובץ נשמר על שולחן העבודה:`n$zip`n`nשלח אותו לחבר. הוא צריך:`n1. להתקין Tailscale ולהתחבר`n2. לפתוח את הקישור לשיתוף המחשב ששלחת לו`n3. לחלץ את הקובץ וללחוץ פעמיים על SharedPC-Connect.bat", 'המחשב המשותף') | Out-Null
        Start-Process explorer.exe "/select,`"$zip`""
    } catch { [Windows.Forms.MessageBox]::Show("לא הצלחתי ליצור את הקובץ: $($_.Exception.Message)", 'המחשב המשותף') | Out-Null }
})

$form.Add_Shown({ Refresh-Target })
[void]$form.ShowDialog()
