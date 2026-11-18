#!/usr/bin/env python3
# SharedPC on Oracle Cloud - one web app for both:
#   /admin  : the owner creates customers (username + password + GB), changes GB / password, logs out, deletes
#   /       : customers log in, see their connection details, change their password, see their storage
# Customers use Remote Desktop (mstsc / Windows App) to the server's IP with their username + password.
import ctypes, html, http.server, json, os, re, secrets, socketserver, subprocess, threading, time, urllib.parse, urllib.request

PORT = 8080
CONF = '/etc/sharedpc'
USERS_FILE = os.path.join(CONF, 'users.json')
ADMIN_FILE = os.path.join(CONF, 'admin-password')
LOG_FILE = '/var/log/sharedpc.log'
lock = threading.Lock()
_libcrypt = ctypes.CDLL('libcrypt.so.1'); _libcrypt.crypt.restype = ctypes.c_char_p
_libcrypt.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]

def log(m):
    with open(LOG_FILE, 'a') as f: f.write(time.strftime('%Y-%m-%d %H:%M:%S  ') + m + '\n')

def run(*cmd, inp=None):
    try:
        r = subprocess.run(list(cmd), input=inp, capture_output=True, text=True, timeout=60)
        return r.returncode, (r.stdout or '') + (r.stderr or '')
    except Exception as e:
        return 127, str(e)

def load_users():
    try:
        with open(USERS_FILE) as f: return json.load(f)
    except Exception: return {}

def save_users(u):
    tmp = USERS_FILE + '.tmp'
    with open(tmp, 'w') as f: json.dump(u, f, ensure_ascii=False, indent=1)
    os.replace(tmp, USERS_FILE); os.chmod(USERS_FILE, 0o600)

_ip = {'v': '', 't': 0}
def public_ip():
    if time.time() - _ip['t'] > 600 or not _ip['v']:
        try: _ip['v'] = urllib.request.urlopen('https://api.ipify.org', timeout=6).read().decode().strip(); _ip['t'] = time.time()
        except Exception: pass
    return _ip['v'] or '?'

def check_password(user, pw):
    try:
        with open('/etc/shadow') as f:
            for line in f:
                p = line.split(':')
                if p[0] == user and p[1] not in ('', '*', '!') and not p[1].startswith('!'):
                    out = _libcrypt.crypt(pw.encode(), p[1].encode())
                    return out is not None and secrets.compare_digest(out.decode(), p[1])
    except Exception as e: log('check_password: %s' % e)
    return False

def pw_problem(pw, user):
    if len(pw) < 8 or not re.search('[A-Z]', pw) or not re.search('[a-z]', pw) or not re.search(r'\d', pw):
        return 'סיסמה: 8 תווים לפחות, עם אות גדולה, אות קטנה וספרה.'
    if not re.fullmatch(r'[A-Za-z0-9!@#$*_\-+=.?]+', pw): return 'בסיסמה מותר: אותיות באנגלית, ספרות והסימנים ! @ # $ * _ - + = . ?'
    if len(user) > 2 and user.lower() in pw.lower(): return 'הסיסמה לא יכולה להכיל את שם המשתמש.'
    return None

def rand_pw():
    a = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; b = 'abcdefghijkmnpqrstuvwxyz'; d = '23456789'
    c = [secrets.choice(a) for _ in range(4)] + [secrets.choice(b) for _ in range(4)] + [secrets.choice(d) for _ in range(4)]
    secrets.SystemRandom().shuffle(c); return ''.join(c) + '!'

def set_quota(user, gb):
    if gb <= 0: kb = 0
    else: kb = int(gb * 1024 * 1024)
    rc, out = run('setquota', '-u', user, str(int(kb * 0.95)), str(kb), '0', '0', '/')
    if rc != 0: log('setquota %s: %s' % (user, out.strip()))
    return rc == 0

def usage_gb():
    rc, out = run('repquota', '-u', '-O', 'csv', '/')
    res = {}
    if rc == 0:
        for line in out.splitlines()[1:]:
            p = line.split(',')
            if len(p) > 3:
                try: res[p[0]] = round(int(p[3]) / 1048576, 2)
                except ValueError: pass
    return res

def signed_in(user):
    rc, out = run('pgrep', '-u', user, '-f', 'xfce4-session')
    return rc == 0

# ---------------- HTML ----------------
CSS = '''*{box-sizing:border-box}body{margin:0;font-family:"Segoe UI",system-ui,Arial,sans-serif;background:#0b0f19;color:#ecf0f7}
a{color:#38bdf8}.wrap{max-width:820px;margin:0 auto;padding:28px 18px 60px}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:24px}.logo{width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,#6366f1,#38bdf8);display:grid;place-items:center;font-size:22px}
.brand b{font-size:22px}.brand span{color:#8f9bb3;font-size:14px}.spacer{flex:1}
.card{background:#131928;border:1px solid #2d3852;border-radius:16px;padding:22px;margin-bottom:16px}
h1{font-size:25px;margin:0 0 6px}h2{font-size:17px;margin:0 0 12px}.muted{color:#8f9bb3}
.pill{display:inline-flex;align-items:center;gap:8px;padding:6px 12px;border-radius:999px;font-weight:600;font-size:14px;background:#1a2235}
.dot{width:10px;height:10px;border-radius:50%}.on{background:#22c55e}.off{background:#64748b}
.row{display:flex;justify-content:space-between;gap:10px;padding:10px 0;border-bottom:1px solid #1f2940}.row:last-child{border:0}
.k{color:#8f9bb3;font-size:13px}.v{font-weight:700;font-size:17px;direction:ltr;word-break:break-all}
button,.btn{font:inherit;font-weight:700;border:0;border-radius:10px;padding:10px 16px;cursor:pointer;color:#fff;background:#6366f1;text-decoration:none;display:inline-flex;gap:8px;align-items:center}
button:hover,.btn:hover{filter:brightness(1.15)}.ghost{background:#1a2235}.red{background:#991b1b}.small{padding:7px 12px;font-size:13px}
.actions{display:flex;flex-wrap:wrap;gap:8px}form.inline{display:inline}
input{width:100%;font:inherit;font-size:16px;padding:11px 13px;border-radius:10px;border:1px solid #2d3852;background:#1a2235;color:#ecf0f7;direction:ltr;text-align:left}
label{display:block;margin:12px 0 6px;color:#8f9bb3;font-size:14px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:0 14px}@media(max-width:600px){.grid{grid-template-columns:1fr}}
.bar{height:12px;background:#1a2235;border-radius:99px;overflow:hidden;margin:10px 0 8px}.bar i{display:block;height:100%;background:linear-gradient(90deg,#38bdf8,#6366f1);margin-left:auto}
.msg{padding:12px 14px;border-radius:10px;margin-bottom:16px;font-weight:600}.ok{background:#14532d}.err{background:#7f1d1d}
.login{max-width:420px;margin:8vh auto 0}.center{text-align:center}.hint{font-size:13px;color:#8f9bb3;margin-top:10px;line-height:1.6}
textarea{width:100%;height:120px;background:#1a2235;color:#ecf0f7;border:1px solid #2d3852;border-radius:10px;padding:10px;font:inherit}
details summary{cursor:pointer;color:#8f9bb3;margin-top:10px}'''
E = html.escape

def page(title, body, logout=None):
    lo = '<div class="spacer"></div><form method="post" action="%s"><button class="ghost small">יציאה</button></form>' % logout if logout else ''
    return ('<!DOCTYPE html><html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>%s</title><style>%s</style></head><body><div class="wrap"><div class="brand"><div class="logo">🖥️</div><div><b>SharedPC</b><br>'
            '<span>המחשב שלך בענן</span></div>%s</div>%s</div></body></html>') % (E(title), CSS, lo, body)

def msg_html(m, kind='ok'): return '<div class="msg %s">%s</div>' % (kind, E(m)) if m else ''

def login_page(action, title, sub, err='', user_field=True):
    u = '<label>שם משתמש</label><input name="u" required autofocus autocomplete="username">' if user_field else ''
    return page(title, '<div class="login"><div class="card"><h1 class="center">%s</h1><p class="muted center">%s</p>%s'
                '<form method="post" action="%s">%s<label>סיסמה</label><input name="p" type="password" required %s autocomplete="current-password">'
                '<div style="margin-top:18px"><button style="width:100%%;justify-content:center">כניסה</button></div></form></div></div>'
                % (E(title), E(sub), msg_html(err, 'err'), action, u, '' if user_field else 'autofocus'))

def details_text(name):
    return 'חיבור לשולחן עבודה מרוחק (mstsc / Windows App)\nכתובת: %s\nשם משתמש: %s\nסיסמה: (הסיסמה שקיבלת)\n\nאתר לניהול המחשב שלך: http://%s:%d' % (public_ip(), name, public_ip(), PORT)

def admin_page(m='', kind='ok'):
    users = load_users(); use = usage_gb()
    rows = []
    for name in sorted(users):
        u = users[name]; gb = u.get('gb', 0); used = use.get(name, 0)
        on = signed_in(name)
        pct = min(100, round(used / gb * 100)) if gb else 0
        det = 'חיבור לשולחן עבודה מרוחק (mstsc / Windows App)\nכתובת: %s\nשם משתמש: %s\nסיסמה: %s\n\nאתר לניהול המחשב שלך: http://%s:%d' % (public_ip(), name, u.get('pw', ''), public_ip(), PORT)
        n = E(name)
        rows.append('''<div class="card"><div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
<div><h2 style="margin:0">👤 %s</h2><div class="muted">%s GB בשימוש מתוך %s</div></div><span class="pill"><span class="dot %s"></span>%s</span></div>
<div class="bar"><i style="width:%d%%"></i></div>
<details><summary>פרטי חיבור ללקוח</summary><textarea readonly>%s</textarea></details>
<details><summary>⚙️ שינויים</summary>
<form method="post" action="/admin/do" class="grid"><input type="hidden" name="n" value="%s"><input type="hidden" name="a" value="gb">
<div><label>נפח (GB, 0 = ללא הגבלה)</label><input name="v" type="number" min="0" max="500" value="%s"></div><div><label>&nbsp;</label><button>שמור נפח</button></div></form>
<form method="post" action="/admin/do" class="grid"><input type="hidden" name="n" value="%s"><input type="hidden" name="a" value="pw">
<div><label>סיסמה חדשה</label><input name="v" value="%s"></div><div><label>&nbsp;</label><button>שנה סיסמה</button></div></form></details>
<div class="actions" style="margin-top:12px">
<form class="inline" method="post" action="/admin/do"><input type="hidden" name="n" value="%s"><input type="hidden" name="a" value="logout"><button class="ghost small">⏏ נתק אותו</button></form>
<form class="inline" method="post" action="/admin/do" onsubmit="return confirm('למחוק את %s וכל הקבצים שלו?')"><input type="hidden" name="n" value="%s"><input type="hidden" name="a" value="delete"><button class="red small">🗑 מחק</button></form>
</div></div>''' % (n, used, (str(gb) + ' GB') if gb else 'ללא הגבלה', 'on' if on else 'off', 'מחובר' if on else 'לא מחובר',
                  pct, E(det), n, gb, n, rand_pw(), n, n, n))
    mem = os.popen("free -g | awk '/Mem:/{print $3\"/\"$2}'").read().strip()
    disk = os.popen("df -BG --output=avail / | tail -1").read().strip()
    body = msg_html(m, kind) + '''<div class="card"><div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
<div><h1>🛡️ ניהול לקוחות</h1><div class="muted">%d לקוחות · IP: %s · זיכרון בשימוש %s GB · פנוי בדיסק %s</div></div><a class="btn ghost" href="/admin">↻ רענון</a></div></div>
<div class="card"><h2>➕ לקוח חדש</h2><form method="post" action="/admin/create"><div class="grid">
<div><label>שם משתמש (באנגלית, אותיות קטנות)</label><input name="name" required pattern="[a-z][a-z0-9_-]{2,19}" placeholder="dani"></div>
<div><label>סיסמה</label><input name="pw" required value="%s"></div>
<div><label>נפח לקבצים (GB)</label><input name="gb" type="number" min="1" max="500" value="10"></div></div>
<div style="margin-top:14px"><button>צור לקוח</button></div><div class="hint">הלקוח מתחבר מיד אחרי היצירה עם חיבור לשולחן עבודה מרוחק לכתובת %s.</div></form></div>
%s''' % (len(users), public_ip(), mem, disk, rand_pw(), public_ip(), '\n'.join(rows))
    return page('ניהול · SharedPC', body, '/admin/logout')

def customer_page(name, m='', kind='ok'):
    u = load_users().get(name, {}); gb = u.get('gb', 0); used = usage_gb().get(name, 0)
    pct = min(100, round(used / gb * 100)) if gb else 0
    on = signed_in(name)
    body = msg_html(m, kind) + '''<div class="card"><div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
<div><h1>שלום, %s 👋</h1><div class="muted">המחשב שלך בענן – פועל 24/7</div></div><span class="pill"><span class="dot %s"></span>%s</span></div>
<div class="actions" style="margin-top:16px"><a class="btn" href="/connect.rdp">🖥️ התחבר עכשיו</a>
<form class="inline" method="post" action="/logoff"><button class="ghost">⏏ נתק חיבור תקוע</button></form></div>
<div class="hint">"התחבר עכשיו" מוריד קובץ קטן – פותחים אותו, מקלידים את הסיסמה, ונכנסים לשולחן העבודה.</div></div>
<div class="card"><h2>🔗 פרטי חיבור</h2><div class="row"><span class="k">כתובת</span><span class="v">%s</span></div>
<div class="row"><span class="k">שם משתמש</span><span class="v">%s</span></div><div class="row"><span class="k">סיסמה</span><span class="v">הסיסמה שלך</span></div>
<div class="hint">ב-Windows: "חיבור לשולחן עבודה מרוחק" (mstsc). ב-Mac, iPhone ו-Android: האפליקציה <b>Windows App</b>.</div></div>
<div class="card"><h2>💾 אחסון</h2><div class="bar"><i style="width:%d%%"></i></div><div class="muted">בשימוש <b style="color:#ecf0f7">%s GB</b> מתוך %s</div></div>
<div class="card"><h2>🔑 שינוי סיסמה</h2><form method="post" action="/password">
<label>סיסמה נוכחית</label><input name="old" type="password" required><label>סיסמה חדשה</label><input name="new" type="password" required>
<label>שוב את הסיסמה החדשה</label><input name="new2" type="password" required><div style="margin-top:14px"><button>שמור סיסמה</button></div></form></div>''' % (
        E(name), 'on' if on else 'off', 'מחובר עכשיו' if on else 'לא מחובר', public_ip(), E(name), pct, used, ('%s GB' % gb) if gb else 'ללא הגבלה')
    return page('SharedPC', body, '/logout')

# ---------------- server ----------------
SESS = {}; ADM = {}; FAILS = {}

def blocked(ip):
    f = FAILS.get(ip); return f and f[0] >= 6 and f[1] > time.time()
def failed(ip):
    f = FAILS.get(ip)
    if not f or f[1] < time.time(): f = [0, time.time() + 900]
    f[0] += 1; FAILS[ip] = f

class H(http.server.BaseHTTPRequestHandler):
    server_version = 'SharedPC'
    def log_message(self, *a): pass
    def send(self, code, body, ctype='text/html; charset=utf-8', headers=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store'); self.send_header('X-Frame-Options', 'DENY')
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
    def redirect(self, to, cookie=None):
        self.send_response(303); self.send_header('Location', to)
        if cookie: self.send_header('Set-Cookie', cookie)
        self.send_header('Content-Length', '0'); self.end_headers()
    def form(self):
        n = int(self.headers.get('Content-Length') or 0)
        d = urllib.parse.parse_qs(self.rfile.read(n).decode('utf-8', 'replace'), keep_blank_values=True)
        return {k: v[0] for k, v in d.items()}
    def cookie(self, name):
        for part in (self.headers.get('Cookie') or '').split(';'):
            k, _, v = part.strip().partition('=')
            if k == name: return v
        return None
    def admin_ok(self):
        t = self.cookie('spcadm'); return bool(t and ADM.get(t, 0) > time.time())
    def customer(self):
        t = self.cookie('spc'); s = SESS.get(t) if t else None
        return s[0] if s and s[1] > time.time() and s[0] in load_users() else None

    def do_GET(self):
        p = urllib.parse.urlparse(self.path).path
        if p.startswith('/admin'):
            return self.send(200, admin_page() if self.admin_ok() else login_page('/admin/login', '🛡️ ניהול', 'כניסה למנהלים בלבד', user_field=False))
        name = self.customer()
        if p == '/connect.rdp' and name:
            rdp = 'full address:s:%s\r\nusername:s:%s\r\nscreen mode id:i:2\r\nsession bpp:i:24\r\nsmart sizing:i:1\r\ndynamic resolution:i:1\r\nprompt for credentials:i:1\r\nauthentication level:i:0\r\n' % (public_ip(), name)
            return self.send(200, rdp, 'application/x-rdp', {'Content-Disposition': 'attachment; filename="%s.rdp"' % name})
        return self.send(200, customer_page(name) if name else login_page('/login', 'כניסה', 'התחבר עם שם המשתמש והסיסמה שקיבלת'))

    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path; ip = self.client_address[0]; f = self.form()
        with lock:
            # ----- admin -----
            if p == '/admin/login':
                if blocked(ip): return self.send(429, login_page('/admin/login', '🛡️ ניהול', '', 'יותר מדי ניסיונות. נסה שוב בעוד 15 דקות.', False))
                if secrets.compare_digest(f.get('p', ''), open(ADMIN_FILE).read().strip()):
                    t = secrets.token_urlsafe(32); ADM[t] = time.time() + 4 * 3600; log('ADMIN login from ' + ip)
                    return self.redirect('/admin', 'spcadm=%s; Path=/admin; HttpOnly; SameSite=Strict' % t)
                failed(ip); log('ADMIN login failed from ' + ip)
                return self.send(401, login_page('/admin/login', '🛡️ ניהול', 'כניסה למנהלים בלבד', 'סיסמה לא נכונה.', False))
            if p == '/admin/logout':
                ADM.pop(self.cookie('spcadm') or '', None); return self.redirect('/admin')
            if p.startswith('/admin'):
                if not self.admin_ok(): return self.redirect('/admin')
                users = load_users()
                if p == '/admin/create':
                    name = f.get('name', '').strip().lower(); pw = f.get('pw', '').strip()
                    try: gb = int(f.get('gb', '10'))
                    except ValueError: gb = 10
                    err = None
                    if not re.fullmatch(r'[a-z][a-z0-9_-]{2,19}', name): err = 'שם משתמש: באנגלית באותיות קטנות, 3–20 תווים, מתחיל באות.'
                    elif name in users or run('id', name)[0] == 0: err = 'השם הזה כבר תפוס.'
                    else: err = pw_problem(pw, name)
                    if err: return self.send(400, admin_page(err, 'err'))
                    rc, out = run('useradd', '-m', '-s', '/bin/bash', '-c', 'SharedPC customer', name)
                    if rc != 0: return self.send(500, admin_page('יצירת המשתמש נכשלה: ' + out, 'err'))
                    run('chpasswd', inp='%s:%s\n' % (name, pw))
                    set_quota(name, gb)
                    users[name] = {'gb': gb, 'pw': pw, 'created': time.strftime('%Y-%m-%d %H:%M')}; save_users(users)
                    log('created customer %s (%d GB) from %s' % (name, gb, ip))
                    return self.send(200, admin_page('הלקוח %s נוצר ✅ – פתח "פרטי חיבור ללקוח" ושלח לו.' % name))
                if p == '/admin/do':
                    name = f.get('n', ''); a = f.get('a', ''); v = f.get('v', '').strip()
                    if name not in users: return self.send(404, admin_page('הלקוח לא נמצא.', 'err'))
                    if a == 'gb':
                        try: gb = max(0, int(v))
                        except ValueError: return self.send(400, admin_page('נפח לא תקין.', 'err'))
                        set_quota(name, gb); users[name]['gb'] = gb; save_users(users); m = 'הנפח של %s עודכן ל-%s.' % (name, ('%d GB' % gb) if gb else 'ללא הגבלה')
                    elif a == 'pw':
                        e = pw_problem(v, name)
                        if e: return self.send(400, admin_page(e, 'err'))
                        run('chpasswd', inp='%s:%s\n' % (name, v)); users[name]['pw'] = v; save_users(users); m = 'הסיסמה של %s שונתה ל: %s' % (name, v)
                    elif a == 'logout':
                        run('pkill', '-KILL', '-u', name); m = '%s נותק.' % name
                    elif a == 'delete':
                        run('pkill', '-KILL', '-u', name); time.sleep(1); run('userdel', '-r', '-f', name)
                        users.pop(name, None); save_users(users); m = '%s נמחק.' % name
                    else: m = 'פעולה לא מוכרת.'
                    log('admin %s %s from %s' % (a, name, ip))
                    return self.send(200, admin_page(m))
                return self.redirect('/admin')
            # ----- customers -----
            if p == '/login':
                if blocked(ip): return self.send(429, login_page('/login', 'כניסה', '', 'יותר מדי ניסיונות. נסה שוב בעוד 15 דקות.'))
                name = f.get('u', '').strip().lower()
                if name in load_users() and check_password(name, f.get('p', '')):
                    t = secrets.token_urlsafe(32); SESS[t] = (name, time.time() + 8 * 3600); log('login %s from %s' % (name, ip))
                    return self.redirect('/', 'spc=%s; Path=/; HttpOnly; SameSite=Strict' % t)
                failed(ip); log('login failed %s from %s' % (name, ip))
                return self.send(401, login_page('/login', 'כניסה', 'התחבר עם שם המשתמש והסיסמה שקיבלת', 'שם משתמש או סיסמה לא נכונים.'))
            if p == '/logout':
                SESS.pop(self.cookie('spc') or '', None); return self.redirect('/')
            name = self.customer()
            if not name: return self.redirect('/')
            if p == '/logoff':
                run('pkill', '-KILL', '-u', name); return self.send(200, customer_page(name, 'החיבור נותק. אפשר להתחבר שוב.'))
            if p == '/password':
                if not check_password(name, f.get('old', '')): return self.send(400, customer_page(name, 'הסיסמה הנוכחית לא נכונה.', 'err'))
                if f.get('new', '') != f.get('new2', ''): return self.send(400, customer_page(name, 'הסיסמאות החדשות לא זהות.', 'err'))
                e = pw_problem(f.get('new', ''), name)
                if e: return self.send(400, customer_page(name, e, 'err'))
                run('chpasswd', inp='%s:%s\n' % (name, f['new']))
                users = load_users(); users[name]['pw'] = f['new']; save_users(users); log('password changed by %s' % name)
                return self.send(200, customer_page(name, 'הסיסמה שונתה ✅'))
            return self.redirect('/')

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True

if __name__ == '__main__':
    os.makedirs(CONF, exist_ok=True)
    if not os.path.exists(ADMIN_FILE):
        with open(ADMIN_FILE, 'w') as fh: fh.write(rand_pw())
    os.chmod(ADMIN_FILE, 0o600)
    if not os.path.exists(USERS_FILE): save_users({})
    log('SharedPC portal started on port %d' % PORT)
    S(('0.0.0.0', PORT), H).serve_forever()
