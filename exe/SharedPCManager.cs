// SharedPC Manager - Windows app for creating virtual computers (one person each) that people
// reach with Remote Desktop (address + username + password).
// Build: mcs -target:winexe -out:SharedPC-Manager.exe -win32manifest:app.manifest -win32icon:app.ico
//        -r:System.Windows.Forms -r:System.Drawing -r:System.Web.Extensions -resource:... SharedPCManager.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("SharedPC Manager")]
[assembly: AssemblyProduct("SharedPC")]
[assembly: AssemblyVersion("2.0.3.0")]

namespace SharedPC
{
    static class App
    {
        public const string HostDir = @"C:\SharedPC-Host";
        public static readonly string VmsFile = Path.Combine(HostDir, "vms.json");
        public static readonly string ScriptDir = Path.Combine(HostDir, "manager");
        public static readonly string Iso = Path.Combine(HostDir, "WindowsServer2022.iso");
        public static readonly string VBM = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Oracle\VirtualBox\VBoxManage.exe");
        const string Repo = "https://raw.githubusercontent.com/MaykoDev50/SharedPC/main/manager/";
        static readonly string[] Scripts = { "common.ps1", "create-vm.ps1", "setup-client.ps1" };
        public const string Title = "ניהול מחשבים וירטואליים";
        public const string Version = "2.0.3";

        public static readonly Color Bg = Color.FromArgb(15, 23, 42), Card = Color.FromArgb(30, 41, 59), Fg = Color.FromArgb(226, 232, 240),
            Muted = Color.FromArgb(148, 163, 184), Blue = Color.FromArgb(37, 99, 235), Red = Color.FromArgb(153, 27, 27), Green = Color.FromArgb(22, 101, 52);

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (s, e) => Error(e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Error(e.ExceptionObject as Exception);
            // creating virtual disks needs administrator rights: restart elevated if needed
            var me = new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent());
            if (!me.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator))
            {
                try { Process.Start(new ProcessStartInfo(Application.ExecutablePath) { UseShellExecute = true, Verb = "runas" }); }
                catch { Say("התוכנה צריכה הרשאות מנהל כדי ליצור מחשבים.\nפתח אותה שוב ולחץ \"כן\" בחלון ההרשאות."); }
                return;
            }
            try
            {
                Directory.CreateDirectory(ScriptDir);
                Log("Manager " + Version + " started (admin)");
                if (!File.Exists(VBM)) { Say("VirtualBox לא מותקן במחשב הזה.\nצריך להריץ קודם את ההתקנה הראשונית (Install-SharedPC)."); return; }
                if (!File.Exists(Iso)) { Say("לא נמצא קובץ Windows Server ב-" + Iso + "\nצריך להריץ קודם את ההתקנה הראשונית (Install-SharedPC)."); return; }
                UpdateScripts();
                RegisterAutostart();
                Application.Run(new MainForm());
            }
            catch (Exception ex) { Error(ex); }
        }

        // ---------- helpers ----------
        public static void Log(string m)
        {
            try { Directory.CreateDirectory(HostDir); File.AppendAllText(Path.Combine(HostDir, "manager.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + m + "\r\n", Encoding.UTF8); } catch { }
        }
        public static void Error(Exception ex)
        {
            if (ex == null) return;
            Log("ERROR " + ex);
            Say("משהו השתבש:\n\n" + ex.Message + "\n\nהפרטים נשמרו ב-" + Path.Combine(HostDir, "manager.log"), MessageBoxIcon.Error);
        }
        public static void Say(string text, MessageBoxIcon icon = MessageBoxIcon.Information)
        {
            MessageBox.Show(text, Title, MessageBoxButtons.OK, icon, MessageBoxDefaultButton.Button1, MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
        }
        public static bool Ask(string text)
        {
            return MessageBox.Show(text, Title, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2, MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign) == DialogResult.Yes;
        }

        // newest scripts from GitHub; the copies built into this exe are used when offline
        static void UpdateScripts()
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // TLS 1.2
            foreach (var name in Scripts)
            {
                var dest = Path.Combine(ScriptDir, name);
                try
                {
                    using (var wc = new WebClient())
                    {
                        wc.Headers.Add("Cache-Control", "no-cache");
                        var data = wc.DownloadData(Repo + name + "?t=" + DateTime.UtcNow.Ticks);
                        if (data.Length > 100) { File.WriteAllBytes(dest, data); continue; }
                    }
                }
                catch (Exception ex) { Log("download " + name + " failed: " + ex.Message); }
                if (!File.Exists(dest))
                {
                    using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
                    using (var f = File.Create(dest)) { s.CopyTo(f); }
                }
            }
        }

        // start every ready computer (and the shared one) when you log in to Windows
        static void RegisterAutostart()
        {
            var startAll = Path.Combine(HostDir, "start-all.ps1");
            File.WriteAllText(startAll,
@"$vbm = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
$f = 'C:\SharedPC-Host\vms.json'
$names = @('SharedPC')
if (Test-Path $f) { $names += @((Get-Content $f -Raw | ConvertFrom-Json) | Where-Object { $_.status -eq 'ready' } | ForEach-Object { ""PC-$($_.name)"" }) }
$running = (& $vbm list runningvms) -join ""`n""
foreach ($n in $names) { if ($running -notmatch ""`""$n`"""") { & $vbm startvm $n --type headless 2>&1 | Out-Null } }
", new UTF8Encoding(true));
            Run("schtasks.exe", "/Create /F /TN \"SharedPC - start VMs at login\" /SC ONLOGON /RL HIGHEST /DELAY 0000:30 /TR \"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + startAll + "\"");
            Run("schtasks.exe", "/Delete /F /TN \"SharedPC - start VM at login\"");
        }

        public static string Run(string exe, string args, int timeoutMs = 120000)
        {
            var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using (var p = Process.Start(psi))
            {
                var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
                p.WaitForExit(timeoutMs);
                return o.Result + e.Result;
            }
        }
        public static string VBox(string args) { return Run(VBM, args); }

        public static string VmState(string name)
        {
            var info = VBox("showvminfo \"PC-" + name + "\" --machinereadable");
            foreach (var line in info.Split(new[] { '\n' }))
                if (line.StartsWith("VMState=")) return line.Substring(8).Trim().Trim('"');
            return "missing";
        }

        public static string RandomPassword()
        {
            const string U = "ABCDEFGHJKLMNPQRSTUVWXYZ", L = "abcdefghijkmnpqrstuvwxyz", D = "23456789";
            var r = new Random(); var c = new List<char>();
            for (int i = 0; i < 4; i++) { c.Add(U[r.Next(U.Length)]); c.Add(L[r.Next(L.Length)]); c.Add(D[r.Next(D.Length)]); }
            return new string(c.OrderBy(x => r.Next()).ToArray()) + "!";
        }

        public static string LanIp()
        {
            try
            {
                using (var s = new System.Net.Sockets.Socket(System.Net.Sockets.AddressFamily.InterNetwork, System.Net.Sockets.SocketType.Dgram, 0))
                { s.Connect("8.8.8.8", 65530); return ((IPEndPoint)s.LocalEndPoint).Address.ToString(); }
            }
            catch { return "?"; }
        }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        class MEMSTAT { public uint len = 64, load; public ulong total, avail, totalPage, availPage, totalVirt, availVirt, availExt; }
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([System.Runtime.InteropServices.In, System.Runtime.InteropServices.Out] MEMSTAT m);
        public static double TotalRamGB()
        {
            var m = new MEMSTAT();
            try { return GlobalMemoryStatusEx(m) ? Math.Round(m.total / 1073741824.0) : 0; } catch { return 0; }
        }
        public static double FreeDiskGB() { try { return Math.Round(new DriveInfo("C").AvailableFreeSpace / 1073741824.0); } catch { return 0; } }
    }

    // ---------- the list of computers (shared with the PowerShell scripts, same lock name) ----------
    static class Store
    {
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        static T Locked<T>(Func<T> f)
        {
            using (var m = new Mutex(false, @"Global\SharedPCVms"))
            {
                try { m.WaitOne(); } catch (AbandonedMutexException) { }
                try { return f(); } finally { m.ReleaseMutex(); }
            }
        }
        static List<Dictionary<string, object>> ReadRaw()
        {
            var list = new List<Dictionary<string, object>>();
            if (!File.Exists(App.VmsFile)) return list;
            var txt = File.ReadAllText(App.VmsFile, Encoding.UTF8).Trim();
            if (txt.Length == 0) return list;
            var o = Json.DeserializeObject(txt);
            if (o is object[]) foreach (var x in (object[])o) { var d = x as Dictionary<string, object>; if (d != null) list.Add(d); }
            else if (o is Dictionary<string, object>) list.Add((Dictionary<string, object>)o);
            return list;
        }
        static void WriteRaw(List<Dictionary<string, object>> list)
        {
            File.WriteAllText(App.VmsFile, Json.Serialize(list), new UTF8Encoding(true));
        }
        public static List<Dictionary<string, object>> All() { return Locked(() => ReadRaw()); }
        public static void Add(Dictionary<string, object> rec) { Locked(() => { var l = ReadRaw(); l.Add(rec); WriteRaw(l); return 0; }); }
        public static void Remove(string name) { Locked(() => { var l = ReadRaw(); l.RemoveAll(r => S(r, "name") == name); WriteRaw(l); return 0; }); }
        public static void Set(string name, string key, object value)
        {
            Locked(() => { var l = ReadRaw(); foreach (var r in l) if (S(r, "name") == name) r[key] = value; WriteRaw(l); return 0; });
        }
        public static string S(Dictionary<string, object> r, string k) { object v; return r.TryGetValue(k, out v) && v != null ? v.ToString() : ""; }
        public static int I(Dictionary<string, object> r, string k) { int i; return int.TryParse(S(r, k), out i) ? i : 0; }
    }

    // ---------- UI building blocks ----------
    static class UI
    {
        public static Button Btn(string text, Color back, int w = 150, int h = 44)
        {
            var b = new Button { Text = text, BackColor = back, ForeColor = Color.White, FlatStyle = FlatStyle.Flat, Size = new Size(w, h), Margin = new Padding(6), Cursor = Cursors.Hand };
            b.FlatAppearance.BorderSize = 0;
            b.Font = new Font("Segoe UI", 10.5f, FontStyle.Bold);
            b.AccessibleName = text;
            return b;
        }
        public static Label Lbl(string text, float size = 10, bool bold = false, Color? color = null)
        {
            return new Label { Text = text, AutoSize = true, ForeColor = color ?? App.Muted, Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular), Margin = new Padding(3, 8, 3, 2) };
        }
        public static void Dark(Form f)
        {
            f.BackColor = App.Bg; f.ForeColor = App.Fg; f.Font = new Font("Segoe UI", 10.5f);
            f.RightToLeft = RightToLeft.Yes; f.RightToLeftLayout = true; f.StartPosition = FormStartPosition.CenterScreen;
            f.AutoScaleDimensions = new SizeF(96F, 96F); f.AutoScaleMode = AutoScaleMode.Dpi;
            try { f.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        }
    }

    // ---------- main window ----------
    class MainForm : Form
    {
        DataGridView grid = new DataGridView();
        Label info = UI.Lbl("טוען…", 10);
        string publicIp = "…", lanIp = App.LanIp();
        System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 10000 };
        bool loading;

        public MainForm()
        {
            UI.Dark(this);
            Text = App.Title + "  ·  גרסה " + App.Version; Size = new Size(1080, 680); MinimumSize = new Size(900, 520);

            var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 110, FlowDirection = FlowDirection.TopDown, Padding = new Padding(16, 10, 16, 0), WrapContents = false };
            top.Controls.Add(UI.Lbl("🖥️  " + App.Title, 18, true, App.Fg));
            info.MaximumSize = new Size(1000, 0);
            top.Controls.Add(info);

            grid.Dock = DockStyle.Fill; grid.ReadOnly = true; grid.AllowUserToAddRows = false; grid.AllowUserToDeleteRows = false;
            grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect; grid.MultiSelect = false; grid.RowHeadersVisible = false;
            grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; grid.BackgroundColor = App.Card; grid.BorderStyle = BorderStyle.None;
            grid.DefaultCellStyle.BackColor = App.Card; grid.DefaultCellStyle.ForeColor = App.Fg; grid.DefaultCellStyle.SelectionBackColor = App.Blue;
            grid.DefaultCellStyle.Font = new Font("Segoe UI", 11); grid.RowTemplate.Height = 38;
            grid.EnableHeadersVisualStyles = false; grid.ColumnHeadersHeight = 40;
            grid.ColumnHeadersDefaultCellStyle.BackColor = App.Bg; grid.ColumnHeadersDefaultCellStyle.ForeColor = App.Muted;
            grid.ColumnHeadersDefaultCellStyle.Font = new Font("Segoe UI", 10, FontStyle.Bold);
            grid.AccessibleName = "רשימת המחשבים";
            foreach (var c in new[] { "שם", "מצב", "שם משתמש", "נפח לקבצים (GB)", "זיכרון (GB)", "כתובת לחיבור" }) grid.Columns.Add(c, c);
            grid.Columns[1].FillWeight = 180;
            grid.CellDoubleClick += (s, e) => CopyDetails();
            var gridWrap = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 6, 16, 6) };
            gridWrap.Controls.Add(grid);

            var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 125, Padding = new Padding(12, 6, 12, 6) };
            var bNew = UI.Btn("➕  מחשב חדש", App.Blue, 170);
            var bCopy = UI.Btn("📋  פרטי חיבור", App.Card);
            var bConnect = UI.Btn("🖱️  התחבר בעצמי", App.Card);
            var bStart = UI.Btn("▶  הפעלה", App.Card, 120);
            var bStop = UI.Btn("⏹  כיבוי", App.Card, 120);
            var bLog = UI.Btn("📄  יומן הקמה", App.Card, 140);
            var bDel = UI.Btn("🗑️  מחיקה", App.Red, 120);
            var bRef = UI.Btn("🔄  רענון", App.Card, 120);
            var bShot = UI.Btn("📷  מה רואים במסך", App.Card, 170);
            bShot.Click += (s, e) => Screenshot();
            bNew.Click += (s, e) => NewComputer();
            bCopy.Click += (s, e) => CopyDetails();
            bConnect.Click += (s, e) => ConnectMyself();
            bStart.Click += (s, e) => Act("start");
            bStop.Click += (s, e) => Act("stop");
            bLog.Click += (s, e) => { var n = Sel(); if (n == null) return; var l = Path.Combine(App.HostDir, "vms", n, "create.log"); if (File.Exists(l)) Process.Start("notepad.exe", "\"" + l + "\""); else App.Say("אין יומן עדיין."); };
            bDel.Click += (s, e) => Delete();
            bRef.Click += (s, e) => Reload();
            bar.Controls.AddRange(new Control[] { bNew, bCopy, bConnect, bStart, bStop, bLog, bShot, bDel, bRef });
            var tip = new ToolTip();
            tip.SetToolTip(bCopy, "מעתיק כתובת, שם משתמש וסיסמה כדי לשלוח ללקוח (גם דאבל-קליק על שורה)");
            tip.SetToolTip(bConnect, "פותח את המחשב אצלך בחיבור לשולחן עבודה מרוחק");

            Controls.Add(gridWrap); Controls.Add(bar); Controls.Add(top);
            timer.Tick += (s, e) => Reload();
            Shown += (s, e) => { Reload(); timer.Start(); FetchPublicIp(); if (Store.All().Count == 0) App.Say("ברוך הבא! 👋\n\nלחץ על \"➕ מחשב חדש\" כדי ליצור את המחשב הראשון."); };
        }

        void FetchPublicIp()
        {
            Task.Run(() =>
            {
                try { using (var wc = new WebClient()) return wc.DownloadString("https://api.ipify.org").Trim(); } catch { return "?"; }
            }).ContinueWith(t => { publicIp = t.Result; BeginInvoke((Action)Reload); });
        }

        string Sel()
        {
            if (grid.SelectedRows.Count == 0) { App.Say("בחר מחשב מהרשימה."); return null; }
            return grid.SelectedRows[0].Cells[0].Value as string;
        }
        Dictionary<string, object> Rec(string n) { return Store.All().FirstOrDefault(r => Store.S(r, "name") == n); }

        void Reload()
        {
            if (loading) return; loading = true;
            Task.Run(() =>
            {
                var recs = Store.All();
                var rows = new List<object[]>(); int ramOn = 0;
                foreach (var r in recs)
                {
                    var name = Store.S(r, "name"); var status = Store.S(r, "status");
                    var state = App.VmState(name);
                    string txt;
                    if (status == "creating") txt = "⏳ בהקמה: " + Store.S(r, "step");
                    else if (status == "failed") txt = "❌ נכשל: " + Store.S(r, "step");
                    else txt = state == "running" ? "🟢 פועל" : state == "missing" ? "⚠️ לא נמצא" : "⚪ כבוי";
                    if (state == "running") ramOn += Store.I(r, "ramGB");
                    rows.Add(new object[] { name, txt, Store.S(r, "user"), Store.S(r, "diskGB"), Store.S(r, "ramGB"), publicIp + ":" + Store.S(r, "port") });
                }
                return Tuple.Create(rows, ramOn);
            }).ContinueWith(t =>
            {
                BeginInvoke((Action)(() =>
                {
                    loading = false;
                    if (t.IsFaulted) { App.Log("reload: " + t.Exception); return; }
                    var sel = grid.SelectedRows.Count > 0 ? grid.SelectedRows[0].Cells[0].Value as string : null;
                    grid.Rows.Clear();
                    foreach (var row in t.Result.Item1) { int i = grid.Rows.Add(row); if ((string)row[0] == sel) grid.Rows[i].Selected = true; }
                    info.Text = "IP ציבורי: " + publicIp + "     ·     IP ברשת הביתית: " + lanIp + "     ·     פנוי בכונן C: " + App.FreeDiskGB() + " GB     ·     זיכרון של מחשבים פועלים: " + t.Result.Item2 + " מתוך " + App.TotalRamGB() + " GB\n" +
                                "כדי שיתחברו מחוץ לבית: בראוטר מעבירים כל פורט (המספר אחרי \":\") ל-" + lanIp + ".     דאבל-קליק על מחשב = העתקת פרטי חיבור.";
                }));
            });
        }

        void NewComputer()
        {
            using (var f = new NewVmForm())
            {
                if (f.ShowDialog(this) != DialogResult.OK) return;
                var used = new HashSet<int>(Store.All().Select(r => Store.I(r, "port")));
                int port = 3390; while (used.Contains(port)) port++;
                var rec = new Dictionary<string, object> {
                    { "name", f.VmName }, { "user", f.User }, { "password", f.Password }, { "diskGB", f.DiskGB }, { "ramGB", f.RamGB },
                    { "port", port }, { "admin", f.Admin }, { "status", "creating" }, { "step", "מתחיל" }, { "created", DateTime.Now.ToString("s") } };
                Store.Add(rec);
                var pf = Path.Combine(Path.GetTempPath(), "spc-" + f.VmName + ".json");
                File.WriteAllText(pf, new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "password", f.Password } }), new UTF8Encoding(true));
                var args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(App.ScriptDir, "create-vm.ps1") + "\" -Name " + f.VmName +
                           " -User " + f.User + " -PasswordFile \"" + pf + "\" -DiskGB " + f.DiskGB + " -RamGB " + f.RamGB + " -Port " + port + (f.Admin ? " -Admin" : "");
                var p = new Process { StartInfo = new ProcessStartInfo("powershell.exe", args) { UseShellExecute = false, CreateNoWindow = true }, EnableRaisingEvents = true };
                var name = f.VmName;
                p.Exited += (s, e) =>
                {
                    var r = Store.All().FirstOrDefault(x => Store.S(x, "name") == name);
                    if (r != null && Store.S(r, "status") == "creating") { Store.Set(name, "status", "failed"); Store.Set(name, "step", "התהליך נעצר (ראה יומן הקמה)"); }
                };
                p.Start();
                App.Log("Creating " + name + " port " + port);
                Reload();
                App.Say("המחשב " + name + " בהקמה ⏳\nזה לוקח בערך 10–15 דקות, ואפשר להמשיך לעבוד בינתיים.\n\nכשהמצב יהיה 🟢 פועל, לחץ \"פרטי חיבור\" ושלח ללקוח.");
            }
        }

        string Details(Dictionary<string, object> r)
        {
            return "כתובת (חיבור לשולחן עבודה מרוחק): " + publicIp + ":" + Store.S(r, "port") + "\r\nשם משתמש: " + Store.S(r, "user") + "\r\nסיסמה: " + Store.S(r, "password");
        }
        void CopyDetails()
        {
            var n = Sel(); if (n == null) return; var r = Rec(n); if (r == null) return;
            if (Store.S(r, "status") != "ready") { App.Say("המחשב עוד לא מוכן."); return; }
            Clipboard.SetText(Details(r));
            App.Say(Details(r) + "\n\n✅ הועתק. הדבק (Ctrl+V) ושלח ללקוח.\nהלקוח פותח \"חיבור לשולחן עבודה מרוחק\" (mstsc) ומקליד את הפרטים.");
        }
        public static string CompName(string vm) { var c = ("PC-" + System.Text.RegularExpressions.Regex.Replace(vm, "[^A-Za-z0-9-]", "")).ToUpper(); return c.Length > 15 ? c.Substring(0, 15) : c; }
        void ConnectMyself()
        {
            var n = Sel(); if (n == null) return; var r = Rec(n); if (r == null) return;
            var port = Store.S(r, "port"); var user = CompName(n) + "\\" + Store.S(r, "user");
            App.Run("cmdkey.exe", "/delete:TERMSRV/127.0.0.2");
            var rdp = Path.Combine(App.HostDir, "vms", n, n + ".rdp");
            File.WriteAllText(rdp, "full address:s:127.0.0.2:" + port + "\r\nusername:s:" + user + "\r\nprompt for credentials:i:1\r\nauthentication level:i:0\r\nscreen mode id:i:2\r\n", Encoding.ASCII);
            Clipboard.SetText(Store.S(r, "password"));
            Process.Start("mstsc.exe", "\"" + rdp + "\"");
            App.Say("נפתח חלון התחברות.\nשם המשתמש: " + user + "\nהסיסמה הועתקה – הדבק אותה (Ctrl+V) ולחץ אישור.");
        }
        void Screenshot()
        {
            var n = Sel(); if (n == null) return;
            var png = Path.Combine(App.HostDir, "vms", n, "screen.png");
            try { File.Delete(png); } catch { }
            var o = App.VBox("controlvm \"PC-" + n + "\" screenshotpng \"" + png + "\"");
            App.Log("screenshot " + n + ": " + o.Trim());
            if (!File.Exists(png)) { App.Say("לא הצלחתי לצלם את המסך (המחשב כבוי?)."); return; }
            var f = new Form { Text = "המסך של " + n, Size = new Size(1100, 850), StartPosition = FormStartPosition.CenterScreen, BackColor = App.Bg };
            byte[] bytes = File.ReadAllBytes(png);
            f.Controls.Add(new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Image = Image.FromStream(new MemoryStream(bytes)) });
            f.Show(this);
        }
        void Act(string what)
        {
            var n = Sel(); if (n == null) return;
            if (what == "stop" && !App.Ask("לכבות את " + n + "? מי שמחובר אליו יתנתק.")) return;
            var outp = App.VBox(what == "start" ? "startvm \"PC-" + n + "\" --type headless" : "controlvm \"PC-" + n + "\" acpipowerbutton");
            App.Log(what + " " + n + ": " + outp.Trim());
            Reload();
        }
        void Delete()
        {
            var n = Sel(); if (n == null) return;
            if (!App.Ask("למחוק את המחשב " + n + " לגמרי?\nכל הקבצים שבו יימחקו ולא יהיה אפשר לשחזר.")) return;
            Cursor = Cursors.WaitCursor;
            App.VBox("controlvm \"PC-" + n + "\" poweroff"); Thread.Sleep(3000);
            App.VBox("unregistervm \"PC-" + n + "\" --delete");
            App.Run("netsh.exe", "advfirewall firewall delete rule name=\"SharedPC PC-" + n + "\"");
            try { Directory.Delete(Path.Combine(App.HostDir, "vms", n), true); } catch (Exception ex) { App.Log("delete dir: " + ex.Message); }
            Store.Remove(n);
            Cursor = Cursors.Default;
            Reload(); App.Say(n + " נמחק.");
        }
    }

    // ---------- "new computer" window ----------
    class NewVmForm : Form
    {
        TextBox name = Box(), user = Box(), pass = Box();
        NumericUpDown disk = Num(5, 2000, 50), ram = Num(2, 64, 4);
        CheckBox admin = new CheckBox { Text = "הרשאות מנהל (יוכל להתקין תוכנות)", AutoSize = true, ForeColor = App.Fg, Margin = new Padding(3, 12, 3, 3) };
        Label capacity = UI.Lbl("", 9.5f);
        public string VmName { get { return name.Text.Trim().ToLower(); } }
        public string User { get { return user.Text.Trim(); } }
        public string Password { get { return pass.Text; } }
        public int DiskGB { get { return (int)disk.Value; } }
        public int RamGB { get { return (int)ram.Value; } }
        public bool Admin { get { return admin.Checked; } }

        static TextBox Box() { return new TextBox { Width = 380, BackColor = App.Card, ForeColor = App.Fg, BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 12), RightToLeft = RightToLeft.No }; }
        static NumericUpDown Num(int min, int max, int val) { return new NumericUpDown { Minimum = min, Maximum = max, Value = val, Width = 120, BackColor = App.Card, ForeColor = App.Fg, Font = new Font("Segoe UI", 12), RightToLeft = RightToLeft.No }; }

        public NewVmForm()
        {
            UI.Dark(this);
            Text = "מחשב חדש"; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink; Padding = new Padding(20);
            var p = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
            p.Controls.Add(UI.Lbl("➕  מחשב חדש", 16, true, App.Fg));
            p.Controls.Add(UI.Lbl("שם המחשב (באנגלית, למשל dani)")); p.Controls.Add(name);
            p.Controls.Add(UI.Lbl("שם משתמש להתחברות (באנגלית)")); p.Controls.Add(user);
            p.Controls.Add(UI.Lbl("סיסמה (8 תווים לפחות, אות גדולה, אות קטנה וספרה)"));
            var pw = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            pass.Width = 260; pass.Text = App.RandomPassword();
            var gen = UI.Btn("🎲 סיסמה חדשה", App.Card, 112, 32); gen.Font = new Font("Segoe UI", 9); gen.Click += (s, e) => pass.Text = App.RandomPassword();
            pw.Controls.Add(pass); pw.Controls.Add(gen); p.Controls.Add(pw);
            p.Controls.Add(UI.Lbl("נפח לקבצים של הלקוח (GB) – Windows עצמו לא נספר")); p.Controls.Add(disk);
            p.Controls.Add(UI.Lbl("זיכרון RAM (GB) – 4 מספיק לרוב")); p.Controls.Add(ram);
            p.Controls.Add(admin);
            capacity.MaximumSize = new Size(390, 0); p.Controls.Add(capacity);
            var buttons = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 14, 0, 0) };
            var ok = UI.Btn("צור מחשב", App.Blue, 180); var cancel = UI.Btn("ביטול", App.Card, 120);
            ok.Click += (s, e) => { if (Valid()) { DialogResult = DialogResult.OK; Close(); } };
            cancel.Click += (s, e) => { DialogResult = DialogResult.Cancel; Close(); };
            buttons.Controls.Add(ok); buttons.Controls.Add(cancel); p.Controls.Add(buttons);
            Controls.Add(p);
            AcceptButton = ok; CancelButton = cancel;
            name.TextChanged += (s, e) => { if (user.Tag == null) user.Text = name.Text.Trim().ToLower(); };
            user.KeyPress += (s, e) => user.Tag = "edited";
            disk.ValueChanged += (s, e) => UpdateCapacity(); ram.ValueChanged += (s, e) => UpdateCapacity();
            UpdateCapacity();
        }

        void UpdateCapacity()
        {
            int planned = Store.All().Where(r => Store.S(r, "status") != "failed").Sum(r => Store.I(r, "ramGB")) + RamGB;
            double total = App.TotalRamGB(), free = App.FreeDiskGB();
            capacity.Text = "💾 פנוי בכונן C: " + free + " GB (המחשב הזה צריך עד " + (DiskGB + 25) + " GB)\n🧠 זיכרון: כל המחשבים יחד " + planned + " GB מתוך " + total + " GB";
            capacity.ForeColor = (planned > total - 6 || DiskGB + 25 > free) ? Color.FromArgb(252, 165, 165) : App.Muted;
        }

        bool Valid()
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(VmName, "^[a-z0-9-]{2,12}$")) { App.Say("שם המחשב: באנגלית, 2–12 תווים (אותיות, ספרות, מקף)."); return false; }
            if (Store.All().Any(r => Store.S(r, "name") == VmName)) { App.Say("כבר יש מחשב בשם הזה."); return false; }
            if (!System.Text.RegularExpressions.Regex.IsMatch(User, "^[A-Za-z0-9._-]{3,20}$")) { App.Say("שם משתמש: באנגלית, 3–20 תווים."); return false; }
            if (Password.Length < 8 || !Password.Any(char.IsUpper) || !Password.Any(char.IsLower) || !Password.Any(char.IsDigit)) { App.Say("סיסמה: 8 תווים לפחות, עם אות גדולה, אות קטנה וספרה."); return false; }
            if (Password.ToLower().Contains(User.ToLower())) { App.Say("הסיסמה לא יכולה להכיל את שם המשתמש."); return false; }
            if (DiskGB + 25 > App.FreeDiskGB()) { App.Say("אין מספיק מקום בכונן C."); return false; }
            int planned = Store.All().Where(r => Store.S(r, "status") != "failed").Sum(r => Store.I(r, "ramGB")) + RamGB;
            if (planned > App.TotalRamGB() - 6 && !App.Ask("כל המחשבים יחד צריכים " + planned + " GB זיכרון, ובמחשב יש " + App.TotalRamGB() + " GB.\nאפשר ליצור, אבל לא כולם יוכלו לפעול בו-זמנית.\n\nלהמשיך?")) return false;
            return true;
        }
    }
}
