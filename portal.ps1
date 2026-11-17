# SharedPC Portal - פורטל יצירת משתמשים למחשב המשותף
# רץ ברקע כמשימה מתוזמנת (SYSTEM) ומאזין בפורט שמוגדר ב-config.json

$ErrorActionPreference = 'Stop'
$Root    = 'C:\SharedPC'
$LogFile = Join-Path $Root 'portal.log'
$cfg     = Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$Port        = [int]$cfg.Port
$InviteCode  = [string]$cfg.InviteCode
$MaxUsers    = [int]$cfg.MaxUsers
$MakeAdmins  = [bool]$cfg.MakeAdmins
$PortalGroup = 'SharedPC-Users'
$RduGroup    = (Get-LocalGroup -SID 'S-1-5-32-555').Name   # Remote Desktop Users
$AdminGroup  = (Get-LocalGroup -SID 'S-1-5-32-544').Name   # Administrators

$script:Fails     = 0
$script:LockUntil = [datetime]::MinValue

function Write-Log([string]$msg) {
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) -Encoding UTF8
}
function Enc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }

function Page([string]$title, [string]$body) {
@"
<!DOCTYPE html>
<html lang="he" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title</title>
<style>
body{margin:0;font-family:"Segoe UI",Arial,sans-serif;background:#0f172a;color:#e2e8f0;display:flex;justify-content:center;padding:32px 16px}
.card{background:#1e293b;border-radius:14px;padding:28px;max-width:520px;width:100%;box-shadow:0 10px 30px rgba(0,0,0,.4)}
h1{margin:0 0 4px;font-size:24px}
h2{font-size:17px;margin:28px 0 10px;color:#93c5fd}
p.sub{color:#94a3b8;margin:0 0 18px}
label{display:block;margin:12px 0 4px;font-size:14px;color:#cbd5e1}
input{width:100%;box-sizing:border-box;padding:10px 12px;border-radius:8px;border:1px solid #334155;background:#0f172a;color:#e2e8f0;font-size:15px}
input[dir=ltr]{text-align:left}
button,.btn{display:inline-block;margin-top:18px;padding:11px 18px;border:0;border-radius:8px;background:#2563eb;color:#fff;font-size:15px;cursor:pointer;text-decoration:none}
button:hover,.btn:hover{background:#1d4ed8}
.status{display:flex;gap:8px;flex-wrap:wrap}
.pill{padding:5px 11px;border-radius:999px;font-size:13px;background:#334155}
.on{background:#166534}
.err{background:#7f1d1d;padding:10px 12px;border-radius:8px;margin-bottom:12px}
.ok{background:#14532d;padding:10px 12px;border-radius:8px;margin-bottom:12px}
small{color:#94a3b8}
code{background:#0f172a;padding:2px 6px;border-radius:4px;direction:ltr;display:inline-block}
ol{padding-right:20px;line-height:1.7}
</style></head>
<body><main class="card">$body</main></body></html>
"@
}

function Send($ctx, [int]$code, [string]$text, [string]$ctype = 'text/html; charset=utf-8', [hashtable]$headers = @{}) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $ctype
    $r.Headers['Cache-Control'] = 'no-store'
    foreach ($k in $headers.Keys) { $r.Headers[$k] = $headers[$k] }
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    $r.OutputStream.Close()
}

function Read-Form($req) {
    $sr  = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    $raw = $sr.ReadToEnd(); $sr.Close()
    $h = @{}
    foreach ($pair in ($raw -split '&')) {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        $k  = [uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        $v  = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
        $h[$k] = $v
    }
    $h
}

# מי מחובר עכשיו (לפי quser)
function Get-Sessions {
    $ErrorActionPreference = 'Continue'   # quser writes to stderr when nobody is logged in
    $lines = & quser.exe 2>$null
    if (-not $lines) { return @() }
    foreach ($l in ($lines | Select-Object -Skip 1)) {
        $t = $l.TrimStart([char[]]@('>', ' '))
        [pscustomobject]@{
            User   = ($t -split '\s+')[0]
            Active = [bool]($t -match '\sActive\s')
        }
    }
}

function Get-PortalUsers {
    @(Get-LocalGroupMember -Group $PortalGroup -ErrorAction SilentlyContinue |
        ForEach-Object { ($_.Name -split '\\')[-1] })
}

function Test-Password([string]$pw, [string]$user) {
    if ($pw.Length -lt 8) { return 'הסיסמה חייבת להכיל לפחות 8 תווים.' }
    $cats = 0
    if ($pw -cmatch '[A-Z]')        { $cats++ }
    if ($pw -cmatch '[a-z]')        { $cats++ }
    if ($pw -match  '\d')           { $cats++ }
    if ($pw -match  '[^A-Za-z0-9]') { $cats++ }
    if ($cats -lt 3) { return 'הסיסמה צריכה לשלב לפחות 3 מתוך 4: אות גדולה באנגלית, אות קטנה, ספרה, סימן (כמו !@#).' }
    if ($pw -match [regex]::Escape($user)) { return 'הסיסמה לא יכולה להכיל את שם המשתמש.' }
    return $null
}

function Home-Page([string]$notice = '') {
    $sessions = @(Get-Sessions)
    $users    = @(Get-PortalUsers)
    $active   = @($sessions | Where-Object { $_.Active }).Count

    if ($users.Count) {
        $pills = ($users | ForEach-Object {
            $u = $_
            $s = $sessions | Where-Object { $_.User -eq $u } | Select-Object -First 1
            if ($s -and $s.Active) { $cls = 'pill on'; $st = 'מחובר עכשיו' }
            elseif ($s)            { $cls = 'pill';    $st = 'מנותק (החלונות נשמרו)' }
            else                   { $cls = 'pill';    $st = 'לא מחובר' }
            "<span class='$cls'>$(Enc $u) · $st</span>"
        }) -join ''
    } else { $pills = '<small>עדיין אין משתמשים. צרו את הראשון למטה.</small>' }

    $full = if ($users.Count -ge $MaxUsers) { "<div class='err'>הגעתם למספר המשתמשים המרבי ($MaxUsers).</div>" } else { '' }

    Page 'המחשב המשותף' @"
<h1>🖥️ המחשב המשותף</h1>
<p class="sub">$(Enc $env:COMPUTERNAME) · מחוברים כרגע: $active מתוך 2</p>
$notice
<div class="status">$pills</div>

<h2>יצירת משתמש חדש</h2>
$full
<form method="post" action="/create" autocomplete="off">
  <label>שם משתמש (באנגלית, 3–20 תווים)</label>
  <input name="username" dir="ltr" required pattern="[A-Za-z0-9._-]{3,20}">
  <label>סיסמה</label>
  <input name="password" type="password" dir="ltr" required>
  <label>אימות סיסמה</label>
  <input name="password2" type="password" dir="ltr" required>
  <label>קוד הזמנה</label>
  <input name="invite" dir="ltr" required>
  <button type="submit">יצירת משתמש</button>
</form>
<small>סיסמה: לפחות 8 תווים, ושילוב של 3 מתוך: אות גדולה, אות קטנה, ספרה, סימן.</small>

<h2>כבר יש לך משתמש?</h2>
<form method="get" action="/rdp">
  <label>שם משתמש</label>
  <input name="user" dir="ltr" required>
  <button type="submit">הורדת קובץ חיבור</button>
</form>
<small>פותחים את הקובץ שירד, מקלידים סיסמה, ונכנסים לשולחן העבודה.</small>

<h2>עדכונים</h2>
<p><small>גרסה $(Enc (Get-LocalVersion)) · המערכת בודקת עדכונים לבד כל יום.<br>$(Enc (Get-LastUpdateLine))</small></p>
<form method="post" action="/update"><button type="submit">בדיקת עדכונים עכשיו</button></form>
"@
}

function Get-LocalVersion {
    $f = Join-Path $Root 'version.txt'
    if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { 'לא ידועה' }
}

function Get-LastUpdateLine {
    $f = Join-Path $Root 'update.log'
    if (Test-Path $f) { 'בדיקה אחרונה: ' + (Get-Content $f -Tail 1 -Encoding UTF8) } else { '' }
}

function New-PortalUser($f) {
    if ((Get-Date) -lt $script:LockUntil) { return 'יותר מדי ניסיונות עם קוד הזמנה שגוי. נסו שוב בעוד כמה דקות.' }
    if ($f['invite'] -cne $InviteCode) {
        $script:Fails++
        if ($script:Fails -ge 5) { $script:LockUntil = (Get-Date).AddMinutes(10); $script:Fails = 0 }
        Write-Log 'Wrong invite code'
        return 'קוד ההזמנה שגוי.'
    }
    $script:Fails = 0

    $u = [string]$f['username']; $pw = [string]$f['password']
    if ($u -notmatch '^[A-Za-z0-9._-]{3,20}$') { return 'שם המשתמש חייב להיות באנגלית, 3–20 תווים (אותיות, ספרות, . _ -).' }
    if (@(Get-PortalUsers).Count -ge $MaxUsers) { return "הגעתם למספר המשתמשים המרבי ($MaxUsers)." }
    if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) { return 'שם המשתמש הזה כבר תפוס.' }
    if ($pw -cne $f['password2']) { return 'הסיסמאות לא תואמות.' }
    $bad = Test-Password $pw $u
    if ($bad) { return $bad }

    try {
        $sec = ConvertTo-SecureString $pw -AsPlainText -Force
        New-LocalUser -Name $u -Password $sec -FullName $u -PasswordNeverExpires -AccountNeverExpires `
            -Description 'Created by SharedPC portal' | Out-Null
        Add-LocalGroupMember -Group $RduGroup   -Member $u
        Add-LocalGroupMember -Group $PortalGroup -Member $u
        if ($MakeAdmins) { Add-LocalGroupMember -Group $AdminGroup -Member $u }
    } catch {
        Write-Log "Create user '$u' failed: $($_.Exception.Message)"
        if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $u -ErrorAction SilentlyContinue }
        return "Windows לא אישר את יצירת המשתמש: $($_.Exception.Message)"
    }
    Write-Log "User '$u' created"
    return $null
}

function Handle($ctx) {
    $req  = $ctx.Request
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    if (-not $path) { $path = '/' }

    switch -Exact ($path) {
        '/' { Send $ctx 200 (Home-Page); return }

        '/create' {
            if ($req.HttpMethod -ne 'POST') { $ctx.Response.Redirect('/'); $ctx.Response.Close(); return }
            $f   = Read-Form $req
            $err = New-PortalUser $f
            if ($err) { Send $ctx 400 (Home-Page "<div class='err'>$(Enc $err)</div>"); return }
            $u = Enc $f['username']
            Send $ctx 200 (Page 'המשתמש נוצר' @"
<h1>✅ המשתמש <code>$u</code> נוצר</h1>
<p class="sub">עכשיו מתחברים לשולחן העבודה:</p>
<ol>
  <li>מורידים את קובץ החיבור.</li>
  <li>פותחים אותו (Windows פותח אותו ב"חיבור לשולחן עבודה מרוחק").</li>
  <li>מקלידים את הסיסמה שבחרתם ונכנסים.</li>
</ol>
<a class="btn" href="/rdp?user=$([uri]::EscapeDataString($f['username']))">⬇️ הורדת קובץ חיבור</a>
<p><small>ב-Mac, iPhone או Android: מתקינים את האפליקציה Windows App של Microsoft ופותחים בה את הקובץ.</small></p>
<p><a href="/" style="color:#93c5fd">חזרה לדף הראשי</a></p>
"@)
            return
        }

        '/rdp' {
            $u = [string]$req.QueryString['user']
            if ($u -notmatch '^[A-Za-z0-9._-]{3,20}$' -or ($u -notin @(Get-PortalUsers))) {
                Send $ctx 404 (Home-Page "<div class='err'>לא נמצא משתמש בשם הזה.</div>"); return
            }
            $hostName = $req.Url.Host
            $rdp = @(
                # when opened through the VirtualBox port-forward on the host (18080), RDP is on 13389
                $(if ($req.Url.Port -eq 18080) { "full address:s:${hostName}:13389" } else { "full address:s:$hostName" }),
                "username:s:$env:COMPUTERNAME\$u",
                'screen mode id:i:2', 'use multimon:i:0', 'session bpp:i:32',
                'dynamic resolution:i:1', 'smart sizing:i:1',
                'audiomode:i:0', 'redirectclipboard:i:1', 'redirectprinters:i:0',
                'autoreconnection enabled:i:1', 'authentication level:i:2', 'prompt for credentials:i:0'
            ) -join "`r`n"
            Send $ctx 200 $rdp 'application/x-rdp' @{ 'Content-Disposition' = "attachment; filename=`"SharedPC-$u.rdp`"" }
            return
        }

        '/setup-status' {
            # only for the host computer (VirtualBox NAT address) - used by the automatic installer
            $from = $req.RemoteEndPoint.Address.ToString()
            if ($from -notin @('10.0.2.2', '127.0.0.1', '::1')) { Send $ctx 404 'not found' 'text/plain'; return }
            $ts   = 'C:\Program Files\Tailscale\tailscale.exe'
            $tsIp = $null
            if (Test-Path $ts) { try { $tsIp = & $ts ip -4 2>$null | Select-Object -First 1 } catch {} }
            $status = [ordered]@{
                firstbootDone = (Test-Path 'C:\SharedPC\firstboot-done.txt')
                tailscaleIp   = $tsIp
                loginUrl      = [string](Get-Content 'C:\SharedPC\tailscale-login.txt' -ErrorAction SilentlyContinue | Select-Object -First 1)
                version       = (Get-LocalVersion)
            }
            Send $ctx 200 ($status | ConvertTo-Json) 'application/json; charset=utf-8'
            return
        }

        '/update' {
            if ($req.HttpMethod -eq 'POST') {
                Start-ScheduledTask -TaskName 'SharedPC Updater' -ErrorAction SilentlyContinue
                Write-Log 'Manual update check requested'
            }
            Send $ctx 200 (Page 'בודק עדכונים' @"
<h1>🔄 בודק עדכונים…</h1>
<p class="sub">אם יש גרסה חדשה היא תותקן תוך דקה, והדף יתרענן לבד.</p>
<meta http-equiv="refresh" content="45;url=/">
<a class="btn" href="/">חזרה לדף הראשי</a>
"@)
            return
        }

        default { Send $ctx 404 (Page 'לא נמצא' "<h1>לא נמצא</h1><a class='btn' href='/'>חזרה</a>") }
    }
}

# ---------- הפעלה ----------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()
Write-Log "Portal started on port $Port"

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try { Handle $ctx }
    catch {
        Write-Log ('ERROR: ' + $_.Exception.Message)
        try { Send $ctx 500 (Page 'שגיאה' "<h1>משהו השתבש</h1><p>$(Enc $_.Exception.Message)</p><a class='btn' href='/'>חזרה</a>") } catch {}
    }
}
