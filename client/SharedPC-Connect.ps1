# SharedPC app - the same app for everyone.
#  * Everyone: type the username + password you got, click "Connect" -> the shared computer's desktop opens.
#  * On the host computer (where the shared computer runs) there is also "Manage users":
#    create users, set how many GB each one may use, reset passwords, delete users.
# The launcher (SharedPC.bat) downloads the newest version of this file every time, so nobody re-downloads anything.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$DataDir  = Join-Path $env:APPDATA 'SharedPC'
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$PrefFile = Join-Path $DataDir 'prefs.json'
$RepoRaw  = 'https://raw.githubusercontent.com/MaykoDev50/SharedPC/main'
$Title    = 'המחשב המשותף'

# ---------- where is the shared computer? ----------
$HostTarget = [pscustomobject]@{ portal = 'http://127.0.0.1:18080'; rdp = '127.0.0.2:13389' }   # on the host itself
function Get-Targets {
    $list = @($HostTarget)
    $cache = Join-Path $DataDir 'targets.json'
    try {   # addresses are published in the repo, so they can change without re-downloading anything
        $j = (Invoke-WebRequest "$RepoRaw/client/targets.json?t=$([DateTime]::UtcNow.Ticks)" -UseBasicParsing -TimeoutSec 8).Content
        $j | Set-Content $cache -Encoding UTF8
    } catch { $j = if (Test-Path $cache) { Get-Content $cache -Raw } else { '[]' } }
    try { $list += @($j | ConvertFrom-Json) } catch {}
    $list += [pscustomobject]@{ portal = 'http://sharedpc:8080'; rdp = 'sharedpc' }
    $list
}
function Find-Target {
    foreach ($t in (Get-Targets)) {
        try { if ((Invoke-WebRequest "$($t.portal)/" -UseBasicParsing -TimeoutSec 6).StatusCode -eq 200) { return $t } } catch {}
    }
    return $null
}
$IsHost = Test-Path 'C:\SharedPC-Host'

# ---------- talking to the shared computer ----------
function Post($t, [string]$path, [hashtable]$fields) {
    $body = ($fields.GetEnumerator() | ForEach-Object { [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value) }) -join '&'
    try {
        $r = Invoke-WebRequest "$($t.portal)$path" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 60
        return ($r.Content | ConvertFrom-Json)
    } catch {
        $resp = $_.Exception.Response
        if (-not $resp) { return [pscustomobject]@{ ok = $false; error = 'אין חיבור למחשב המשותף.' } }
        if ([int]$resp.StatusCode -eq 404) { return [pscustomobject]@{ ok = $false; error = 'old' } }
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $txt = $sr.ReadToEnd(); $sr.Close()
        try { return ($txt | ConvertFrom-Json) } catch { return [pscustomobject]@{ ok = $false; error = 'הפעולה נכשלה.' } }
    }
}
function Request-Update($t) { try { Invoke-WebRequest "$($t.portal)/update" -Method Post -UseBasicParsing -TimeoutSec 4 | Out-Null } catch {} }

function Start-Desktop($t, [string]$u, [string]$p) {
    $hostOnly = ($t.rdp -split ':')[0]
    if ($p) { & cmdkey.exe "/generic:TERMSRV/$hostOnly" "/user:SHAREDPC\$u" "/pass:$p" | Out-Null }
    $rdpFile = Join-Path $DataDir "SharedPC-$u.rdp"
    @(
        "full address:s:$($t.rdp)", "username:s:SHAREDPC\$u",
        'screen mode id:i:2', 'use multimon:i:0', 'session bpp:i:32', 'dynamic resolution:i:1', 'smart sizing:i:1',
        'audiomode:i:0', 'redirectclipboard:i:1', 'redirectprinters:i:0', 'autoreconnection enabled:i:1',
        'authentication level:i:0', 'prompt for credentials:i:0', 'enablecredsspsupport:i:1'
    ) -join "`r`n" | Set-Content $rdpFile -Encoding ASCII
    Start-Process mstsc.exe "`"$rdpFile`""
}

# ---------- look ----------
$C = @{
    bg = [Drawing.Color]::FromArgb(15, 23, 42); card = [Drawing.Color]::FromArgb(30, 41, 59)
    fg = [Drawing.Color]::FromArgb(226, 232, 240); muted = [Drawing.Color]::FromArgb(148, 163, 184)
    blue = [Drawing.Color]::FromArgb(37, 99, 235); green = [Drawing.Color]::FromArgb(134, 239, 172); red = [Drawing.Color]::FromArgb(252, 165, 165)
}
function New-Form($text, $w, $h) {
    $f = New-Object Windows.Forms.Form
    $f.Text = $text; $f.Size = New-Object Drawing.Size($w, $h); $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedSingle'; $f.MaximizeBox = $false
    $f.BackColor = $C.bg; $f.ForeColor = $C.fg; $f.Font = New-Object Drawing.Font('Segoe UI', 11)
    $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $true
    $f
}
function Add-Label($form, $text, $x, $y, $w, $size = 10, $color = $null, [switch]$Bold) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, ($size * 2 + 8))
    $l.ForeColor = $(if ($color) { $color } else { $C.muted })
    $l.Font = New-Object Drawing.Font('Segoe UI', $size, $(if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
    $form.Controls.Add($l); $l
}
function Add-Box($form, $x, $y, $w, [switch]$Password) {
    $b = New-Object Windows.Forms.TextBox
    $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 30)
    $b.BackColor = $C.card; $b.ForeColor = $C.fg; $b.BorderStyle = 'FixedSingle'; $b.RightToLeft = 'No'
    $b.Font = New-Object Drawing.Font('Segoe UI', 12)
    if ($Password) { $b.UseSystemPasswordChar = $true }
    $form.Controls.Add($b); $b
}
function Add-Button($form, $text, $x, $y, $w, $h = 40, $color = $null) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, $h)
    $b.BackColor = $(if ($color) { $color } else { $C.blue }); $b.ForeColor = [Drawing.Color]::White
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $form.Controls.Add($b); $b
}
function Say($text) { [Windows.Forms.MessageBox]::Show($text, $Title, 'OK', 'Information', 'Button1', [Windows.Forms.MessageBoxOptions]::RtlReading -bor [Windows.Forms.MessageBoxOptions]::RightAlign) | Out-Null }
function Ask($text) { [Windows.Forms.MessageBox]::Show($text, $Title, 'YesNo', 'Question', 'Button2', [Windows.Forms.MessageBoxOptions]::RtlReading -bor [Windows.Forms.MessageBoxOptions]::RightAlign) -eq 'Yes' }
function Input($prompt, $default = '') { [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $Title, $default) }

# ================= user management (host only) =================
function Show-Admin($t) {
    $f = New-Form 'ניהול משתמשים' 760 520
    Add-Label $f '👥 ניהול משתמשים' 20 15 700 16 $C.fg -Bold | Out-Null
    $info = Add-Label $f '' 20 52 700 10

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Location = New-Object Drawing.Point(20, 85); $grid.Size = New-Object Drawing.Size(705, 300)
    $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
    $grid.RowHeadersVisible = $false; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = $C.card
    $grid.DefaultCellStyle.BackColor = $C.card; $grid.DefaultCellStyle.ForeColor = $C.fg
    $grid.DefaultCellStyle.SelectionBackColor = $C.blue; $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $C.bg; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $C.muted
    foreach ($col in 'שם משתמש', 'מצב', 'בשימוש (GB)', 'מגבלה (GB)', 'מנהל') { [void]$grid.Columns.Add($col, $col) }
    $f.Controls.Add($grid)

    function Load-Users {
        $grid.Rows.Clear()
        try { $d = Invoke-RestMethod "$($t.portal)/api/admin/users" -TimeoutSec 20 }
        catch { $info.Text = 'לא הצלחתי לקרוא את רשימת המשתמשים (המחשב המשותף מתעדכן? נסה "רענון").'; return }
        foreach ($u in @($d.users)) {
            $state = if ($u.online) { '🟢 מחובר' } elseif ($u.signedIn) { '🟡 מנותק (חלונות שמורים)' } else { '⚪ לא מחובר' }
            $quota = if ([double]$u.quotaGB -gt 0) { $u.quotaGB } else { 'ללא הגבלה' }
            [void]$grid.Rows.Add($u.name, $state, $u.usedGB, $quota, $(if ($u.admin) { 'כן' } else { '' }))
        }
        $online = @($d.users | Where-Object { $_.online }).Count
        $info.Text = "פנוי בדיסק של המחשב המשותף: $($d.freeGB) GB · מחוברים עכשיו: $online מתוך $($d.maxSessions)"
    }
    function Selected { if ($grid.SelectedRows.Count) { [string]$grid.SelectedRows[0].Cells[0].Value } else { Say 'בחר משתמש מהרשימה.'; $null } }
    function Do-Admin($action, $fields) {
        $r = Post $t "/api/admin/$action" $fields
        if ($r.error -eq 'old') { Request-Update $t; Say 'המחשב המשותף מתעדכן לגרסה החדשה. נסה שוב בעוד דקה.'; return $false }
        if (-not $r.ok) { Say $r.error; return $false }
        Load-Users; return $true
    }

    $bNew = Add-Button $f '➕ משתמש חדש' 20 400 135
    $bQuota = Add-Button $f '💾 שינוי נפח' 165 400 135 40 $C.card
    $bPw = Add-Button $f '🔑 סיסמה חדשה' 310 400 135 40 $C.card
    $bAdm = Add-Button $f '🛡️ מנהל כן/לא' 455 400 130 40 $C.card
    $bDel = Add-Button $f '🗑️ מחיקה' 595 400 130 40 ([Drawing.Color]::FromArgb(127, 29, 29))
    $bRef = Add-Button $f 'רענון' 20 448 100 30 $C.card
    Add-Label $f 'מגבלת נפח לא חלה על משתמשים שהם "מנהל". 0 = ללא הגבלה.' 130 452 595 9 | Out-Null

    $bNew.Add_Click({
        $u = (Input 'שם משתמש (באנגלית, 3–20 תווים):').Trim(); if (-not $u) { return }
        $p = Input "סיסמה ל-$u`n(8 תווים לפחות, עם אות גדולה, אות קטנה וספרה):"; if (-not $p) { return }
        $g = Input "כמה GB מותר ל-$u להשתמש? (0 = ללא הגבלה)" '20'; if ($g -eq '') { return }
        if ($g -notmatch '^\d+(\.\d+)?$') { Say 'צריך מספר.'; return }
        $adm = Ask "לתת ל-$u הרשאות מנהל? (יוכל להתקין תוכנות, ומגבלת הנפח לא תחול עליו)"
        if (Do-Admin 'create' @{ username = $u; password = $p; quotaGB = $g; admin = $(if ($adm) { '1' } else { '0' }) }) {
            [Windows.Forms.Clipboard]::SetText("שם משתמש: ${u}`r`nסיסמה: ${p}")
            Say "המשתמש $u נוצר ✅`n`nשם המשתמש והסיסמה הועתקו (Ctrl+V כדי להדביק). שלח אותם לחבר יחד עם הקובץ SharedPC.bat."
        }
    })
    $bQuota.Add_Click({ $u = Selected; if (-not $u) { return }
        $g = Input "כמה GB מותר ל-$u להשתמש? (0 = ללא הגבלה)" '20'; if ($g -eq '') { return }
        if ($g -notmatch '^\d+(\.\d+)?$') { Say 'צריך מספר.'; return }
        if (Do-Admin 'quota' @{ username = $u; quotaGB = $g }) { Say "הנפח של $u עודכן." } })
    $bPw.Add_Click({ $u = Selected; if (-not $u) { return }
        $p = Input "סיסמה חדשה ל-${u}:"; if (-not $p) { return }
        if (Do-Admin 'password' @{ username = $u; password = $p }) { [Windows.Forms.Clipboard]::SetText($p); Say "הסיסמה של $u שונתה (הועתקה ללוח)." } })
    $bAdm.Add_Click({ $u = Selected; if (-not $u) { return }
        $adm = Ask "לתת ל-$u הרשאות מנהל?`n(כן = יכול להתקין תוכנות, בלי מגבלת נפח. לא = משתמש רגיל עם מגבלת נפח)"
        [void](Do-Admin 'admin' @{ username = $u; admin = $(if ($adm) { '1' } else { '0' }) }) })
    $bDel.Add_Click({ $u = Selected; if (-not $u) { return }
        if (Ask "למחוק את המשתמש $u?`nהוא יתנתק, והחשבון שלו יימחק. קבצים בתיקיות המשותפות נשארים.") {
            if (Do-Admin 'delete' @{ username = $u }) { Say "$u נמחק." } } })
    $bRef.Add_Click({ Load-Users })

    $f.Add_Shown({ Request-Update $t; Load-Users })
    [void]$f.ShowDialog()
}

# ================= main window =================
$prefs = if (Test-Path $PrefFile) { Get-Content $PrefFile -Raw | ConvertFrom-Json } else { $null }
$form = New-Form $Title 420 $(if ($IsHost) { 420 } else { 370 })
Add-Label $form "🖥️ $Title" 25 18 355 18 $C.fg -Bold | Out-Null
$status = Add-Label $form 'מחפש את המחשב המשותף…' 25 60 355 10
Add-Label $form 'שם משתמש' 25 98 355 10 | Out-Null
$user = Add-Box $form 25 122 355
Add-Label $form 'סיסמה' 25 162 355 10 | Out-Null
$pass = Add-Box $form 25 186 355 -Password
$savedLbl = Add-Label $form '🔒 הסיסמה שמורה במחשב הזה. אפשר להשאיר ריק.' 25 220 355 9
$savedLbl.Visible = $false
if ($prefs -and $prefs.user) { $user.Text = [string]$prefs.user; if ($prefs.saved) { $savedLbl.Visible = $true } }
$go = Add-Button $form 'התחבר' 25 250 355 48
$go.Font = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$form.AcceptButton = $go
if ($IsHost) {
    $adminBtn = Add-Button $form '👥 ניהול משתמשים (רק אצלך)' 25 312 355 40 $C.card
    $adminBtn.Add_Click({ if (-not $script:target) { Refresh-Target }; if ($script:target) { Show-Admin $script:target } else { Say 'המחשב המשותף לא זמין כרגע.' } })
}

$script:target = $null
function Refresh-Target {
    $status.Text = 'מחפש את המחשב המשותף…'; $status.ForeColor = $C.muted; $form.Refresh()
    $script:target = Find-Target
    if ($script:target) { $status.Text = '✅ המחשב המשותף זמין'; $status.ForeColor = $C.green; Request-Update $script:target }
    elseif ($IsHost) { $status.Text = '❌ המחשב המשותף כבוי או עולה. חכה דקה ונסה שוב.'; $status.ForeColor = $C.red }
    else { $status.Text = '❌ לא מוצא את המחשב המשותף. האם Tailscale פתוח ומחובר?'; $status.ForeColor = $C.red }
}

$go.Add_Click({
    $u = $user.Text.Trim(); $p = $pass.Text
    if (-not $u) { Say 'כתוב שם משתמש.'; return }
    $samePerson = $prefs -and $prefs.saved -and ([string]$prefs.user -eq $u)
    if (-not $p -and -not $samePerson) { Say 'כתוב סיסמה.'; return }
    if (-not $script:target) { Refresh-Target }
    if (-not $script:target) {
        if (-not $IsHost -and (Ask "לא מוצא את המחשב המשותף.`n`nכדי להתחבר מבחוץ צריך את Tailscale (חינם), מחובר לחשבון שאליו שיתפו את המחשב.`n`nלפתוח את דף ההורדה של Tailscale?")) {
            Start-Process 'https://tailscale.com/download/windows'
        }
        return
    }
    $go.Enabled = $false; $go.Text = 'בודק…'; $form.Refresh()
    if ($p) {
        $r = Post $script:target '/api/login-check' @{ username = $u; password = $p }
        if ($r.error -eq 'old') { $r = [pscustomobject]@{ ok = $true } }   # older shared computer: skip the check
        if (-not $r.ok) { $go.Enabled = $true; $go.Text = 'התחבר'; Say $r.error; return }
    }
    @{ user = $u; saved = $true } | ConvertTo-Json | Set-Content $PrefFile -Encoding UTF8
    Start-Desktop $script:target $u $p
    $form.Close()
})

$form.Add_Shown({ Refresh-Target })
[void]$form.ShowDialog()
