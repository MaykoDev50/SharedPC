// SharedPC Admin - the remote control app for partners: no VirtualBox, nothing to install.
// Opens the owner's management panel (create / manage computers) from anywhere.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("SharedPC Admin")]
[assembly: AssemblyProduct("SharedPC")]
[assembly: AssemblyVersion("1.2.0.0")]

namespace SharedPCAdmin
{
    static class Program
    {
        const string DefaultAddress = "37.142.176.147:8080";
        static readonly string Cfg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SharedPC-Admin.txt");
        static readonly Color Bg = Color.FromArgb(11, 15, 25), Card = Color.FromArgb(26, 34, 53), Text = Color.FromArgb(236, 240, 247),
            Muted = Color.FromArgb(143, 155, 179), Accent = Color.FromArgb(99, 102, 241), Green = Color.FromArgb(34, 197, 94), Red = Color.FromArgb(239, 68, 68);

        const string UpdUrl = "https://raw.githubusercontent.com/MaykoDev50/SharedPC/main/exe/";
        static string Latest()   // newer version on GitHub, or null
        {
            try
            {
                string latest;
                using (var wc = new WebClient()) latest = wc.DownloadString(UpdUrl + "admin-version.txt?t=" + DateTime.UtcNow.Ticks).Trim();
                return new Version(latest) > Assembly.GetExecutingAssembly().GetName().Version ? latest : null;
            }
            catch { return null; }
        }
        // replaces itself with the newest version from GitHub (no need to send a new file)
        static bool SelfUpdate()
        {
            const string url = UpdUrl;
            var exe = Application.ExecutablePath;
            try { File.Delete(exe + ".old"); } catch { }
            try
            {
                var latest = Latest(); if (latest == null) return false;
                var tmp = exe + ".new";
                using (var wc = new WebClient()) wc.DownloadFile(url + "SharedPC-Admin.exe?t=" + DateTime.UtcNow.Ticks, tmp);
                if (new FileInfo(tmp).Length < 10000 || AssemblyName.GetAssemblyName(tmp).Version < new Version(latest)) { File.Delete(tmp); return false; }
                File.Move(exe, exe + ".old"); File.Move(tmp, exe);
                Process.Start(exe); return true;
            }
            catch { try { if (!File.Exists(exe) && File.Exists(exe + ".old")) File.Move(exe + ".old", exe); } catch { } return false; }
        }

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            if (SelfUpdate()) return;

            var f = new Form
            {
                Text = "SharedPC · ניהול מרחוק", Size = new Size(520, 380), StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedSingle, MaximizeBox = false, BackColor = Bg, ForeColor = Text,
                Font = new Font("Segoe UI", 10.5f), RightToLeft = RightToLeft.Yes, RightToLeftLayout = true,
                AutoScaleDimensions = new SizeF(96F, 96F), AutoScaleMode = AutoScaleMode.Dpi
            };
            try { f.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            var title = new Label { Text = "🛡️  SharedPC · ניהול מרחוק", Font = new Font("Segoe UI", 17, FontStyle.Bold), AutoSize = true, Location = new Point(24, 22), ForeColor = Text };
            var sub = new Label { Text = "יצירה וניהול של המחשבים – מכל מקום, בלי להתקין כלום.", AutoSize = true, Location = new Point(26, 66), ForeColor = Muted };
            var lbl = new Label { Text = "כתובת השרת", AutoSize = true, Location = new Point(26, 108), ForeColor = Muted };
            var box = new TextBox { Location = new Point(26, 132), Width = 450, Font = new Font("Segoe UI", 13), BackColor = Card, ForeColor = Text, BorderStyle = BorderStyle.FixedSingle, RightToLeft = RightToLeft.No };
            box.Text = File.Exists(Cfg) ? File.ReadAllText(Cfg).Trim() : DefaultAddress;
            var status = new Label { Text = "", AutoSize = true, Location = new Point(26, 176), ForeColor = Muted };
            var open = new Button { Text = "פתח את פאנל הניהול", Location = new Point(26, 214), Size = new Size(450, 52), BackColor = Accent, ForeColor = Color.White, FlatStyle = FlatStyle.Flat, Font = new Font("Segoe UI", 13, FontStyle.Bold), Cursor = Cursors.Hand };
            open.FlatAppearance.BorderSize = 0;
            var hint = new Label { Text = "בפאנל נכנסים עם סיסמת הניהול שקיבלת. הסיסמה לא נשמרת בתוכנה.", AutoSize = true, Location = new Point(26, 284), ForeColor = Muted, Font = new Font("Segoe UI", 9) };
            var ver = Assembly.GetExecutingAssembly().GetName().Version;
            var upd = new Button { Text = "⬆️ בדוק עדכון", Location = new Point(26, 316), Size = new Size(200, 32), BackColor = Card, ForeColor = Text, FlatStyle = FlatStyle.Flat, Font = new Font("Segoe UI", 9, FontStyle.Bold), Cursor = Cursors.Hand };
            var verLbl = new Label { Text = "גרסה " + ver.Major + "." + ver.Minor + "." + ver.Build, AutoSize = true, Location = new Point(240, 324), ForeColor = Muted, Font = new Font("Segoe UI", 9) };
            string found = null;
            Action<bool> checkUpd = clicked =>
            {
                if (clicked && found != null)
                {
                    upd.Text = "⏳ מעדכן…"; upd.Enabled = false;
                    System.Threading.Tasks.Task.Run(() => SelfUpdate()).ContinueWith(t => f.BeginInvoke((Action)(() =>
                    {
                        if (t.Result) { Application.Exit(); return; }
                        upd.Enabled = true; upd.Text = "⬆️ עדכן עכשיו (" + found + ")";
                        MessageBox.Show("העדכון לא הצליח כרגע. נסה שוב בעוד כמה דקות.", "SharedPC", MessageBoxButtons.OK, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button1, MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
                    })));
                    return;
                }
                upd.Text = "⏳ בודק…"; upd.Enabled = false;
                System.Threading.Tasks.Task.Run(() => Latest()).ContinueWith(t => f.BeginInvoke((Action)(() =>
                {
                    upd.Enabled = true; found = t.Result;
                    if (found != null) { upd.Text = "⬆️ עדכן עכשיו (" + found + ")"; upd.BackColor = Color.FromArgb(34, 160, 90); }
                    else { upd.Text = "✓ הגרסה הכי חדשה"; upd.BackColor = Card; }
                    if (clicked && found == null) MessageBox.Show("יש לך את הגרסה הכי חדשה.", "SharedPC", MessageBoxButtons.OK, MessageBoxIcon.Information, MessageBoxDefaultButton.Button1, MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
                })));
            };
            upd.Click += (s, e) => checkUpd(true);
            f.Shown += (s, e) => checkUpd(false);
            f.Height += 30;
            f.Controls.AddRange(new Control[] { title, sub, lbl, box, status, open, hint, upd, verLbl });
            f.AcceptButton = open;

            Func<string> url = () =>
            {
                var a = box.Text.Trim().Replace("http://", "").Replace("https://", "").TrimEnd('/');
                if (a.EndsWith("/admin")) a = a.Substring(0, a.Length - 6);
                if (!a.Contains(":")) a += ":8080";
                return "http://" + a;
            };
            string working = null;   // the address that answered (on the server's own computer that is 127.0.0.1)
            Func<string, bool> ping = u =>
            {
                try { var r = (HttpWebRequest)WebRequest.Create(u + "/admin"); r.Timeout = 5000; using (r.GetResponse()) { } return true; }
                catch { return false; }
            };
            Action check = () =>
            {
                status.Text = "⏳ בודק חיבור לשרת…"; status.ForeColor = Muted;
                var u = url();
                Task.Run(() =>
                {
                    if (ping(u)) return Tuple.Create(u, "✅ השרת זמין");
                    // inside the owner's home the router often can't reach its own public address - try this computer / the home network
                    if (ping("http://127.0.0.1:8080")) return Tuple.Create("http://127.0.0.1:8080", "✅ השרת זמין (במחשב הזה)");
                    return Tuple.Create((string)null, "❌ השרת לא עונה (המחשב של המנהל כבוי? הכתובת השתנתה?)");
                }).ContinueWith(t => f.BeginInvoke((Action)(() =>
                {
                    working = t.Result.Item1; status.Text = t.Result.Item2;
                    status.ForeColor = working != null ? Green : Red;
                })));
            };
            open.Click += (s, e) =>
            {
                try { File.WriteAllText(Cfg, box.Text.Trim()); } catch { }
                Process.Start((working ?? url()) + "/admin");
            };
            box.Leave += (s, e) => check();
            f.Shown += (s, e) => check();
            Application.Run(f);
        }
    }
}
