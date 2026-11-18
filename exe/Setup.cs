// SharedPC Manager - first-time setup on a new computer: installs everything by itself.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SharedPC
{
    class SetupForm : Form
    {
        static readonly string[] IsoUrls = {
            "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US",
            "https://software-download.microsoft.com/download/sg/20348.169.210806-2348.fe_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso",
            "https://go.microsoft.com/fwlink/p/?linkid=2195686&clcid=0x409&culture=en-us&country=us"
        };
        public bool Done;
        Label[] marks = new Label[4], texts = new Label[4];
        Label detail = T.Lbl("", 10, false, T.Muted);
        Bar bar = new Bar { Width = 560, Height = 12 };
        Btn retry = new Btn("נסה שוב", T.Accent, 140, 42);

        public SetupForm()
        {
            T.Dark(this);
            Text = "SharedPC · התקנה ראשונה"; Size = new Size(660, 520); FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
            var title = T.Lbl("👋  ברוך הבא ל-SharedPC", 18, true, T.Text); title.Location = new Point(28, 24);
            var sub = T.Lbl("מכין את המחשב הזה ליצירת מחשבים. זה קורה פעם אחת בלבד,\nלוקח בערך 15–40 דקות (תלוי במהירות האינטרנט), ואפשר להמשיך לעבוד בינתיים.", 10.5f, false, T.Muted);
            sub.Location = new Point(30, 70);
            Controls.Add(title); Controls.Add(sub);
            var names = new[] { "בודק את המחשב", "מתקין רכיבי Microsoft", "מתקין VirtualBox (חינם)", "מוריד את Windows Server (כ-4.7GB)" };
            for (int i = 0; i < 4; i++)
            {
                marks[i] = T.Lbl("○", 13, true, T.Muted); marks[i].Location = new Point(30, 140 + i * 44);
                texts[i] = T.Lbl(names[i], 12, false, T.Muted); texts[i].Location = new Point(64, 142 + i * 44);
                Controls.Add(marks[i]); Controls.Add(texts[i]);
            }
            bar.Location = new Point(30, 330); Controls.Add(bar);
            detail.Location = new Point(30, 352); detail.MaximumSize = new Size(580, 0); Controls.Add(detail);
            retry.Location = new Point(30, 410); retry.Visible = false; retry.Click += (s, e) => { retry.Visible = false; Start(); };
            Controls.Add(retry);
            Shown += (s, e) => Start();
            FormClosing += (s, e) => { if (!Done && running && !App.Ask("ההתקנה עוד רצה. לסגור? (בפעם הבאה היא תמשיך מאיפה שעצרה)")) e.Cancel = true; };
        }

        bool running;
        void Ui(Action a) { if (IsHandleCreated) BeginInvoke(a); }
        void Step(int i, string state)   // state: run | ok | fail
        {
            Ui(() =>
            {
                marks[i].Text = state == "run" ? "◐" : state == "ok" ? "✓" : "✕";
                marks[i].ForeColor = state == "run" ? T.Accent2 : state == "ok" ? T.Green : T.Red;
                texts[i].ForeColor = state == "run" ? T.Text : state == "ok" ? T.Muted : T.Red;
                if (state != "run") { bar.Value = 0; bar.Invalidate(); }
            });
        }
        void Detail(string s) { Ui(() => detail.Text = s); App.Log("setup: " + s); }
        void Progress(double v, double max) { Ui(() => { bar.Value = v; bar.Max = max; bar.Invalidate(); }); }

        void Start()
        {
            running = true;
            Task.Run(() =>
            {
                int i = 0;
                try
                {
                    i = 0; Step(0, "run"); CheckComputer(); Step(0, "ok");
                    i = 1; Step(1, "run"); if (!File.Exists(App.VBM)) InstallVcRedist(); Step(1, "ok");
                    i = 2; Step(2, "run"); if (!File.Exists(App.VBM)) InstallVirtualBox(); Step(2, "ok");
                    i = 3; Step(3, "run"); if (!IsoOk()) DownloadIso(); Step(3, "ok");
                    Detail("הכל מוכן! 🎉"); Done = true;
                    Thread.Sleep(900);
                    Ui(Close);
                }
                catch (Exception ex)
                {
                    App.Log("setup failed at step " + i + ": " + ex);
                    Step(i, "fail"); Detail("❌ " + ex.Message);
                    Ui(() => retry.Visible = true);
                }
                finally { running = false; }
            });
        }

        // ---------- steps ----------
        void CheckComputer()
        {
            Directory.CreateDirectory(App.HostDir);
            var ram = App.TotalRamGB(); var free = App.FreeDiskGB();
            Detail("זיכרון: " + ram + " GB · פנוי בכונן C: " + free + " GB");
            if (ram > 0 && ram < 8) throw new Exception("צריך לפחות 8GB זיכרון במחשב (יש " + ram + " GB).");
            if (free > 0 && free < 40 && !IsoOk()) throw new Exception("צריך לפחות 40GB פנויים בכונן C (יש " + free + " GB). פנה מקום ונסה שוב.");
            string vt = "";
            try { vt = App.Run("powershell.exe", "-NoProfile -Command \"$p=Get-CimInstance Win32_Processor|Select -First 1; $c=Get-CimInstance Win32_ComputerSystem; \\\"$($p.VirtualizationFirmwareEnabled)|$($c.HypervisorPresent)\\\"\"", 60000).Trim(); } catch (Exception ex) { App.Log("vt check: " + ex.Message); }
            App.Log("virtualization: " + vt);
            if (vt.StartsWith("False|False"))
                throw new Exception("הווירטואליזציה כבויה ב-BIOS של המחשב הזה.\nצריך להיכנס ל-BIOS (בהדלקה: F2 / Del / F10), להפעיל Intel VT-x או AMD SVM, ולנסות שוב.");
            Thread.Sleep(600);
        }

        void Download(string url, string dest, string what)
        {
            var part = dest + ".part";
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) SharedPC"; req.Timeout = 30000; req.ReadWriteTimeout = 60000; req.AllowAutoRedirect = true;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var src = resp.GetResponseStream())
            using (var dst = File.Create(part))
            {
                long total = resp.ContentLength, got = 0; var buf = new byte[1 << 20]; int n; var last = DateTime.MinValue; var start = DateTime.Now;
                while ((n = src.Read(buf, 0, buf.Length)) > 0)
                {
                    dst.Write(buf, 0, n); got += n;
                    if ((DateTime.Now - last).TotalMilliseconds > 400)
                    {
                        last = DateTime.Now;
                        var speed = got / Math.Max(1, (DateTime.Now - start).TotalSeconds);
                        if (total > 0)
                        {
                            Progress(got, total);
                            var left = TimeSpan.FromSeconds((total - got) / Math.Max(1, speed));
                            Detail(what + ": " + (got >> 20) + " / " + (total >> 20) + " MB  ·  " + (speed / 1048576).ToString("0.0") + " MB/s  ·  נשארו בערך " + (int)left.TotalMinutes + " דק'");
                        }
                        else Detail(what + ": " + (got >> 20) + " MB");
                    }
                }
            }
            if (File.Exists(dest)) File.Delete(dest);
            File.Move(part, dest);
        }

        void InstallVcRedist()
        {
            Detail("מוריד רכיבי Microsoft Visual C++…");
            var exe = Path.Combine(App.HostDir, "vc_redist.x64.exe");
            Download("https://aka.ms/vs/17/release/vc_redist.x64.exe", exe, "רכיבי Microsoft");
            Detail("מתקין רכיבי Microsoft…");
            App.Run(exe, "/install /quiet /norestart", 600000);
        }

        void InstallVirtualBox()
        {
            Detail("מתקין VirtualBox… (יכול לקחת כמה דקות)");
            var winget = Environment.ExpandEnvironmentVariables(@"%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe");
            if (File.Exists(winget))
            {
                var o = App.Run(winget, "install --id Oracle.VirtualBox -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity", 1200000);
                App.Log("winget: " + o);
            }
            if (File.Exists(App.VBM)) return;
            Detail("מוריד את VirtualBox מהאתר הרשמי…");
            string ver;
            using (var wc = new WebClient()) ver = wc.DownloadString("https://download.virtualbox.org/virtualbox/LATEST-STABLE.TXT").Trim();
            string list;
            using (var wc = new WebClient()) list = wc.DownloadString("https://download.virtualbox.org/virtualbox/" + ver + "/");
            var m = Regex.Match(list, "(VirtualBox-" + Regex.Escape(ver) + @"-\d+-Win\.exe)");
            if (!m.Success) throw new Exception("לא מצאתי את קובץ ההתקנה של VirtualBox " + ver);
            var exe = Path.Combine(App.HostDir, m.Groups[1].Value);
            Download("https://download.virtualbox.org/virtualbox/" + ver + "/" + m.Groups[1].Value, exe, "VirtualBox");
            Detail("מתקין VirtualBox…");
            App.Run(exe, "--silent --ignore-reboot", 1200000);
            if (!File.Exists(App.VBM)) throw new Exception("ההתקנה של VirtualBox לא הצליחה. נסה שוב, או התקן אותו ידנית מ-virtualbox.org.");
        }

        static bool IsoOk() { return File.Exists(App.Iso) && new FileInfo(App.Iso).Length > 3L * 1024 * 1024 * 1024; }

        void DownloadIso()
        {
            Exception last = null;
            foreach (var url in IsoUrls)
            {
                try
                {
                    Detail("מתחבר לאתר של Microsoft…");
                    Download(url, App.Iso, "Windows Server");
                    if (IsoOk()) return;
                    File.Delete(App.Iso); last = new Exception("הקובץ שירד לא תקין");
                }
                catch (Exception ex) { last = ex; App.Log("iso " + url + ": " + ex.Message); }
            }
            throw new Exception("לא הצלחתי להוריד את Windows Server (" + (last != null ? last.Message : "") + "). בדוק את האינטרנט ולחץ \"נסה שוב\".");
        }
    }
}
