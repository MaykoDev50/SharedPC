# SharedPC client website - customers log in with their username + password and manage their own computer:
# see status and connection details, download a connection file, start / restart, see storage, change password.
# Runs in the background on the host (scheduled task at login, as administrator - same account that runs the VMs).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')
$Port    = 8080
$LogFile = 'C:\SharedPC-Host\client-portal.log'
function Write-Log([string]$m) { Add-Content $LogFile ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $m) -Encoding UTF8 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Sessions = @{}          # token -> @{ name; until }
$script:Fails    = @{}          # ip -> @{ count; until }
$script:Usage    = @{}          # vm name -> @{ gb; at }
$script:PublicIp = ''; $script:IpAt = [datetime]::MinValue

function Get-PublicIp {
    if ((Get-Date) - $script:IpAt -gt [TimeSpan]::FromMinutes(10) -or -not $script:PublicIp) {
        try { $script:PublicIp = (Invoke-WebRequest 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 8).Content.Trim(); $script:IpAt = Get-Date } catch {}
    }
    $script:PublicIp
}
function Enc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }
function CompName([string]$vm) { $c = ('PC-' + ($vm -replace '[^A-Za-z0-9-]', '')).ToUpper(); if ($c.Length -gt 15) { $c.Substring(0, 15) } else { $c } }
function Guest($r, [string]$cmd) {
    $ErrorActionPreference = 'Continue'
    (& $script:VBM guestcontrol "PC-$($r.name)" run --exe 'C:\Windows\System32\cmd.exe' --username $r.adminName --password $r.adminPassword `
        --wait-stdout --wait-stderr --timeout 60000 -- cmd.exe /c $cmd 2>&1 | Out-String)
}
function Has-Agent($r) { "$($r.agent)" -eq 'True' }

function Get-UsageGB($r) {
    $u = $script:Usage[$r.name]
    if ($u -and ((Get-Date) - $u.at).TotalMinutes -lt 5) { return $u.gb }
    if (-not (Has-Agent $r) -or (Get-VmState "PC-$($r.name)") -ne 'running') { return $null }
    $out = Guest $r 'fsutil quota query C:'
    foreach ($block in ($out -replace "`r", '') -split "`n\s*`n") {
        if ($block -match [regex]::Escape('\' + $r.user) -and $block -match 'Quota Used\s*[:=]\s*([\d,\.]+)') {
            $gb = [math]::Round(([double]($Matches[1] -replace '[,\.]', '')) / 1GB, 2)
            $script:Usage[$r.name] = @{ gb = $gb; at = Get-Date }
            return $gb
        }
    }
    $null
}

# ---------------- HTML ----------------
$Css = @'
*{box-sizing:border-box}body{margin:0;font-family:"Segoe UI",system-ui,Arial,sans-serif;background:#0b0f19;color:#ecf0f7;min-height:100vh}
a{color:#38bdf8}.wrap{max-width:760px;margin:0 auto;padding:28px 18px 60px}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:26px}.logo{width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,#6366f1,#38bdf8);display:grid;place-items:center;font-size:22px}
.brand b{font-size:22px}.brand span{color:#8f9bb3;font-size:14px}.spacer{flex:1}
.card{background:#131928;border:1px solid #2d3852;border-radius:16px;padding:22px;margin-bottom:16px}
h1{font-size:26px;margin:0 0 6px}h2{font-size:17px;margin:0 0 14px}.muted{color:#8f9bb3}
.pill{display:inline-flex;align-items:center;gap:8px;padding:6px 12px;border-radius:999px;font-weight:600;font-size:14px;background:#1a2235}
.dot{width:10px;height:10px;border-radius:50%}.on{background:#22c55e}.off{background:#64748b}.busy{background:#facc15}
.row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 0;border-bottom:1px solid #1f2940}.row:last-child{border:0}
.row .k{color:#8f9bb3;font-size:13px}.row .v{font-weight:700;font-size:17px;direction:ltr;text-align:right;word-break:break-all}
button,.btn{font:inherit;font-weight:700;border:0;border-radius:10px;padding:11px 18px;cursor:pointer;color:#fff;background:#6366f1;text-decoration:none;display:inline-flex;align-items:center;gap:8px}
button:hover,.btn:hover{filter:brightness(1.15)}.ghost{background:#1a2235}.green{background:#16a34a}.small{padding:7px 12px;font-size:13px}
.actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:6px}
input{width:100%;font:inherit;font-size:16px;padding:12px 14px;border-radius:10px;border:1px solid #2d3852;background:#1a2235;color:#ecf0f7;direction:ltr;text-align:left}
label{display:block;margin:14px 0 6px;color:#8f9bb3;font-size:14px}
.bar{height:12px;background:#1a2235;border-radius:99px;overflow:hidden;margin:10px 0 8px}.bar i{display:block;height:100%;background:linear-gradient(90deg,#38bdf8,#6366f1);border-radius:99px;margin-right:0;margin-left:auto}
.msg{padding:12px 14px;border-radius:10px;margin-bottom:16px;font-weight:600}.ok{background:#14532d}.err{background:#7f1d1d}
.login{max-width:420px;margin:8vh auto 0}.center{text-align:center}.hint{font-size:13px;color:#8f9bb3;margin-top:12px;line-height:1.6}
.steps{margin:0;padding-right:20px;line-height:1.9;color:#cbd5e1}
'@
function Page([string]$title, [string]$body, [bool]$withLogout = $false) {
    $logout = if ($withLogout) { "<div class='spacer'></div><form method='post' action='/logout'><button class='ghost small'>יציאה</button></form>" } else { '' }
@"
<!DOCTYPE html><html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title</title><style>$Css</style></head><body><div class="wrap">
<div class="brand"><div class="logo">🖥️</div><div><b>SharedPC</b><br><span>המחשב שלך בענן</span></div>$logout</div>
$body
</div></body></html>
"@
}

function Login-Page([string]$err = '') {
    $e = if ($err) { "<div class='msg err'>$(Enc $err)</div>" } else { '' }
    Page 'כניסה · SharedPC' @"
<div class="login"><div class="card">
<h1 class="center">כניסה</h1><p class="muted center">התחבר עם שם המשתמש והסיסמה שקיבלת</p>
$e
<form method="post" action="/login" autocomplete="on">
<label>שם משתמש</label><input name="u" required autofocus autocomplete="username">
<label>סיסמה</label><input name="p" type="password" required autocomplete="current-password">
<div style="margin-top:18px"><button style="width:100%;justify-content:center">כניסה</button></div>
</form></div></div>
"@
}

function Dash-Page($r, [string]$msg = '', [string]$kind = 'ok') {
    $state = Get-VmState "PC-$($r.name)"
    $running = $state -eq 'running'
    $stTxt = switch ($state) { 'running' { 'פועל' } 'starting' { 'עולה…' } 'stopping' { 'נכבה…' } default { 'כבוי' } }
    $dot = if ($running) { 'on' } elseif ($state -in 'starting', 'stopping') { 'busy' } else { 'off' }
    $ip = Get-PublicIp
    $addr = "${ip}:$($r.port)"
    $user = "$(CompName $r.name)\$($r.user)"
    $m = if ($msg) { "<div class='msg $kind'>$(Enc $msg)</div>" } else { '' }
    $limit = [int]$r.diskGB
    $used = Get-UsageGB $r
    $usage = if ($null -ne $used) {
        $pct = if ($limit -gt 0) { [math]::Min(100, [math]::Round($used / $limit * 100)) } else { 0 }
        "<div class='bar'><i style='width:$pct%'></i></div><div class='muted'>בשימוש <b style='color:#ecf0f7'>$used GB</b> מתוך $limit GB</div>"
    } else { "<div class='muted'>הנפח שלך: <b style='color:#ecf0f7'>$limit GB</b></div>" }
    $power = if ($running) { "<form method='post' action='/restart' onsubmit=""return confirm('להפעיל מחדש? חלונות פתוחים ייסגרו.')""><button class='ghost'>↻ הפעלה מחדש</button></form>" }
             else { "<form method='post' action='/start'><button class='green'>▶ הדלק את המחשב</button></form>" }
    $pwCard = if (Has-Agent $r) { @"
<div class="card"><h2>🔑 שינוי סיסמה</h2>
<form method="post" action="/password">
<label>סיסמה נוכחית</label><input name="old" type="password" required autocomplete="current-password">
<label>סיסמה חדשה</label><input name="new" type="password" required autocomplete="new-password">
<label>שוב את הסיסמה החדשה</label><input name="new2" type="password" required autocomplete="new-password">
<div class="hint">8 תווים לפחות, עם אות גדולה, אות קטנה וספרה. המחשב צריך להיות דלוק.</div>
<div style="margin-top:14px"><button>שמור סיסמה</button></div></form></div>
"@ } else { '' }
    Page "$($r.name) · SharedPC" @"
$m
<div class="card">
<div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
<div><h1>שלום, $(Enc $r.user) 👋</h1><div class="muted">המחשב שלך: <b>$(Enc $r.name)</b></div></div>
<span class="pill"><span class="dot $dot"></span>$stTxt</span></div>
<div class="actions" style="margin-top:18px">
<a class="btn" href="/connect.rdp">🖥️ התחבר עכשיו</a>
$power
</div>
<div class="hint">"התחבר עכשיו" מוריד קובץ קטן – פותחים אותו, מקלידים את הסיסמה, ונכנסים לשולחן העבודה.</div>
</div>

<div class="card"><h2>🔗 פרטי חיבור</h2>
<div class="row"><span class="k">כתובת</span><span class="v">$(Enc $addr)</span></div>
<div class="row"><span class="k">שם משתמש</span><span class="v">$(Enc $user)</span></div>
<div class="row"><span class="k">סיסמה</span><span class="v">הסיסמה שלך</span></div>
<div class="hint">אפשר גם לפתוח את "חיבור לשולחן עבודה מרוחק" (mstsc) ב-Windows, או את האפליקציה <b>Windows App</b> ב-Mac, iPhone ו-Android, ולהקליד את הפרטים.</div>
</div>

<div class="card"><h2>💾 אחסון</h2>$usage</div>
$pwCard
<div class="card"><h2>❓ איך מתחברים</h2><ol class="steps">
<li>לוחצים <b>"התחבר עכשיו"</b> ופותחים את הקובץ שירד.</li>
<li>מקלידים את הסיסמה ולוחצים אישור.</li>
<li>אם מופיעה שאלה על אישור אבטחה – לוחצים <b>"כן"</b>.</li>
<li>המחשב כבוי? לוחצים <b>"הדלק את המחשב"</b> ומחכים דקה.</li></ol></div>
"@ $true
}

# ---------------- helpers ----------------
function Send($ctx, [int]$code, [string]$body, [string]$type = 'text/html; charset=utf-8', [hashtable]$headers = @{}) {
    $b = [Text.Encoding]::UTF8.GetBytes($body); $r = $ctx.Response
    $r.StatusCode = $code; $r.ContentType = $type
    $r.Headers['Cache-Control'] = 'no-store'; $r.Headers['X-Frame-Options'] = 'DENY'; $r.Headers['Referrer-Policy'] = 'no-referrer'
    foreach ($k in $headers.Keys) { $r.Headers[$k] = $headers[$k] }
    $r.ContentLength64 = $b.Length; $r.OutputStream.Write($b, 0, $b.Length); $r.OutputStream.Close()
}
function Redirect($ctx, [string]$to, [hashtable]$headers = @{}) {
    $r = $ctx.Response; foreach ($k in $headers.Keys) { $r.Headers[$k] = $headers[$k] }
    $r.StatusCode = 303; $r.RedirectLocation = $to; $r.Close()
}
function Read-Form($req) {
    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $raw = $sr.ReadToEnd(); $sr.Close()
    $h = @{}
    foreach ($pair in ($raw -split '&')) { if (-not $pair) { continue }; $kv = $pair -split '=', 2
        $h[[uri]::UnescapeDataString($kv[0].Replace('+', ' '))] = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' } }
    $h
}
function Get-SessionVm($req) {
    $c = $req.Cookies['spc']; if (-not $c) { return $null }
    $s = $script:Sessions[$c.Value]; if (-not $s -or $s.until -lt (Get-Date)) { return $null }
    $s.until = (Get-Date).AddHours(8)
    Get-VmRecords | Where-Object { $_.name -eq $s.name -and $_.status -eq 'ready' } | Select-Object -First 1
}
function Check-Password([string]$pw, [string]$user) {
    if ($pw.Length -lt 8 -or $pw -cnotmatch '[A-Z]' -or $pw -cnotmatch '[a-z]' -or $pw -notmatch '\d') { return 'הסיסמה צריכה 8 תווים לפחות, עם אות גדולה, אות קטנה וספרה.' }
    if ($pw -notmatch '^[A-Za-z0-9!@#$*_\-+=.?]+$') { return 'בסיסמה מותר: אותיות באנגלית, ספרות והסימנים ! @ # $ * _ - + = . ?' }
    if ($user.Length -gt 2 -and $pw.ToLower().Contains($user.ToLower())) { return 'הסיסמה לא יכולה להכיל את שם המשתמש.' }
    $null
}

# ---------------- requests ----------------
function Handle($ctx) {
    $req = $ctx.Request; $path = $req.Url.AbsolutePath; $ip = $req.RemoteEndPoint.Address.ToString()
    if ($path -eq '/favicon.ico') { Send $ctx 404 ''; return }

    if ($path -eq '/login' -and $req.HttpMethod -eq 'POST') {
        $f = $script:Fails[$ip]
        if ($f -and $f.count -ge 5 -and $f.until -gt (Get-Date)) { Send $ctx 429 (Login-Page 'יותר מדי ניסיונות. נסה שוב בעוד 10 דקות.'); return }
        $form = Read-Form $req
        $u = ([string]$form['u']).Trim(); if ($u -match '\\') { $u = ($u -split '\\')[-1] }
        $r = Get-VmRecords | Where-Object { $_.status -eq 'ready' -and $_.user -ieq $u -and $_.password -ceq [string]$form['p'] } | Select-Object -First 1
        if (-not $r) {
            if (-not $f -or $f.until -lt (Get-Date)) { $f = @{ count = 0; until = (Get-Date).AddMinutes(10) } }
            $f.count++; $script:Fails[$ip] = $f
            Write-Log "login failed for '$u' from $ip"
            Send $ctx 401 (Login-Page 'שם משתמש או סיסמה לא נכונים.'); return
        }
        $script:Fails.Remove($ip)
        $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $token = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
        $script:Sessions[$token] = @{ name = $r.name; until = (Get-Date).AddHours(8) }
        Write-Log "login '$($r.user)' ($($r.name)) from $ip"
        Redirect $ctx '/' @{ 'Set-Cookie' = "spc=$token; Path=/; HttpOnly; SameSite=Strict" }; return
    }
    if ($path -eq '/logout') {
        $c = $req.Cookies['spc']; if ($c) { $script:Sessions.Remove($c.Value) }
        Redirect $ctx '/' @{ 'Set-Cookie' = 'spc=; Path=/; Max-Age=0' }; return
    }

    $r = Get-SessionVm $req
    if (-not $r) { if ($path -eq '/') { Send $ctx 200 (Login-Page) } else { Redirect $ctx '/' }; return }

    switch ($path) {
        '/' { Send $ctx 200 (Dash-Page $r); return }
        '/connect.rdp' {
            $rdp = @("full address:s:$(Get-PublicIp):$($r.port)", "username:s:$(CompName $r.name)\$($r.user)", 'screen mode id:i:2', 'use multimon:i:0',
                     'session bpp:i:32', 'dynamic resolution:i:1', 'smart sizing:i:1', 'audiomode:i:0', 'redirectclipboard:i:1',
                     'autoreconnection enabled:i:1', 'authentication level:i:2', 'prompt for credentials:i:1') -join "`r`n"
            Send $ctx 200 $rdp 'application/x-rdp' @{ 'Content-Disposition' = "attachment; filename=`"$($r.name).rdp`"" }; return
        }
        '/start' {
            if ($req.HttpMethod -ne 'POST') { Redirect $ctx '/'; return }
            $ErrorActionPreference = 'Continue'; & $script:VBM startvm "PC-$($r.name)" --type headless 2>&1 | Out-Null
            Update-VmRecord $r.name @{ stopped = $false }
            Write-Log "start $($r.name) by customer"
            Send $ctx 200 (Dash-Page $r 'המחשב נדלק. עוד כדקה אפשר להתחבר.'); return
        }
        '/restart' {
            if ($req.HttpMethod -ne 'POST') { Redirect $ctx '/'; return }
            $ErrorActionPreference = 'Continue'; & $script:VBM controlvm "PC-$($r.name)" reset 2>&1 | Out-Null
            Write-Log "restart $($r.name) by customer"
            Send $ctx 200 (Dash-Page $r 'המחשב מופעל מחדש. עוד כדקה אפשר להתחבר.'); return
        }
        '/password' {
            if ($req.HttpMethod -ne 'POST' -or -not (Has-Agent $r)) { Redirect $ctx '/'; return }
            $form = Read-Form $req
            if ([string]$form['old'] -cne $r.password) { Send $ctx 400 (Dash-Page $r 'הסיסמה הנוכחית לא נכונה.' 'err'); return }
            if ([string]$form['new'] -cne [string]$form['new2']) { Send $ctx 400 (Dash-Page $r 'הסיסמאות החדשות לא זהות.' 'err'); return }
            $bad = Check-Password ([string]$form['new']) $r.user; if ($bad) { Send $ctx 400 (Dash-Page $r $bad 'err'); return }
            if ((Get-VmState "PC-$($r.name)") -ne 'running') { Send $ctx 400 (Dash-Page $r 'המחשב צריך להיות דלוק כדי לשנות סיסמה.' 'err'); return }
            $o = Guest $r "net user $($r.user) $([string]$form['new'])"
            if ($o -notmatch 'successfully') { Write-Log "password change failed $($r.name): $o"; Send $ctx 500 (Dash-Page $r 'שינוי הסיסמה נכשל. נסה שוב בעוד דקה.' 'err'); return }
            Update-VmRecord $r.name @{ password = [string]$form['new'] }
            Write-Log "password changed by customer $($r.name)"
            $r = Get-VmRecords | Where-Object { $_.name -eq $r.name } | Select-Object -First 1
            Send $ctx 200 (Dash-Page $r 'הסיסמה שונתה ✅'); return
        }
        default { Redirect $ctx '/' }
    }
}

# ---------------- start ----------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try { $listener.Start() } catch { Write-Log "cannot listen on ${Port}: $($_.Exception.Message)"; exit 1 }
Write-Log "client website started on port $Port"
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try { Handle $ctx }
    catch {
        Write-Log ('ERROR: ' + $_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber)
        try { Send $ctx 500 (Page 'שגיאה' "<div class='card'><h1>משהו השתבש</h1><p class='muted'>נסה שוב בעוד רגע.</p><a class='btn' href='/'>חזרה</a></div>") } catch {}
    }
}
