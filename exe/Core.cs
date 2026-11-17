// SharedPC Manager - core: paths, VirtualBox calls, the list of computers, guest commands.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("SharedPC Manager")]
[assembly: AssemblyProduct("SharedPC")]
[assembly: AssemblyVersion("3.2.0.0")]

namespace SharedPC
{
    static partial class App
    {
        public const string Version = "3.2.0";
        public const string Title = "SharedPC · ניהול מחשבים";
        public const string HostDir = @"C:\SharedPC-Host";
        public static readonly string VmsFile = Path.Combine(HostDir, "vms.json");
        public static readonly string ScriptDir = Path.Combine(HostDir, "manager");
        public static readonly string Iso = Path.Combine(HostDir, "WindowsServer2022.iso");
        public static readonly string VBM = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Oracle\VirtualBox\VBoxManage.exe");
        const string Repo = "https://raw.githubusercontent.com/MaykoDev50/SharedPC/main/manager/";
        static readonly string[] Scripts = { "common.ps1", "create-vm.ps1", "setup-client.ps1", "client-portal.ps1" };
        public const int WebPort = 8080;

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (s, e) => Error(e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Error(e.ExceptionObject as Exception);

            var me = new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent());
            if (!me.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator))
            {
                try { Process.Start(new ProcessStartInfo(Application.ExecutablePath) { UseShellExecute = true, Verb = "runas" }); }
                catch { Say("התוכנה צריכה הרשאות מנהל כדי לנהל מחשבים.\nפתח אותה שוב ולחץ \"כן\" בחלון ההרשאות."); }
                return;
            }
            try
            {
                Directory.CreateDirectory(ScriptDir);
                Log("Manager " + Version + " started (admin)");
                if (!File.Exists(VBM)) { Say("VirtualBox לא מותקן במחשב הזה.\nצריך להריץ קודם את ההתקנה הראשונית."); return; }
                if (!File.Exists(Iso)) { Say("לא נמצא קובץ Windows Server ב-" + Iso + "\nצריך להריץ קודם את ההתקנה הראשונית."); return; }
                UpdateScripts();
                RegisterAutostart();
                Application.Run(new MainForm());
            }
            catch (Exception ex) { Error(ex); }
        }

        // ---------- messages & log ----------
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
            MessageBox.Show(text, "SharedPC", MessageBoxButtons.OK, icon, MessageBoxDefaultButton.Button1, MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign);
        }
        public static bool Ask(string text)
        {
            return MessageBox.Show(text, "SharedPC", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2, MessageBoxOptions.RtlReading | MessageBoxOptions.RightAlign) == DialogResult.Yes;
        }

        // ---------- startup chores ----------
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
        static void RegisterAutostart()
        {
            var startAll = Path.Combine(HostDir, "start-all.ps1");
            File.WriteAllText(startAll,
@"$vbm = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
$f = 'C:\SharedPC-Host\vms.json'
$names = @('SharedPC')
if (Test-Path $f) { $names += @((Get-Content $f -Raw | ConvertFrom-Json) | Where-Object { $_.status -eq 'ready' -and -not $_.stopped } | ForEach-Object { ""PC-$($_.name)"" }) }
$running = (& $vbm list runningvms) -join ""`n""
foreach ($n in $names) { if ($running -notmatch ""`""$n`"""") { & $vbm startvm $n --type headless 2>&1 | Out-Null } }
", new UTF8Encoding(true));
            Run("schtasks.exe", "/Create /F /TN \"SharedPC - start VMs at login\" /SC ONLOGON /RL HIGHEST /DELAY 0000:30 /TR \"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + startAll + "\"");
            Run("schtasks.exe", "/Delete /F /TN \"SharedPC - start VM at login\"");

            // client website: runs in the background (same account as the computers), restarted so it uses the newest version
            var portal = Path.Combine(ScriptDir, "client-portal.ps1");
            Run("schtasks.exe", "/Create /F /TN \"SharedPC - client website\" /SC ONLOGON /RL HIGHEST /TR \"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + portal + "\"");
            Run("netsh.exe", "advfirewall firewall delete rule name=\"SharedPC client website\"");
            Run("netsh.exe", "advfirewall firewall add rule name=\"SharedPC client website\" dir=in action=allow protocol=TCP localport=" + WebPort);
            Run("schtasks.exe", "/End /TN \"SharedPC - client website\"");
            Thread.Sleep(800);
            Run("schtasks.exe", "/Run /TN \"SharedPC - client website\"");
        }

        // ---------- processes ----------
        public static string Run(string exe, string args, int timeoutMs = 120000)
        {
            var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
            using (var p = Process.Start(psi))
            {
                var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } }
                return o.Result + e.Result;
            }
        }
        public static string VBox(string args) { return Run(VBM, args); }
        public static string AdminPassword()
        {
            var f = Path.Combine(HostDir, "admin-password.txt");
            for (int i = 0; i < 10 && !File.Exists(f); i++) Thread.Sleep(500);   // the website creates it on first start
            return File.Exists(f) ? File.ReadAllText(f).Trim() : "";
        }

        public static string VmState(string name)
        {
            try
            {
                var info = VBox("showvminfo \"PC-" + name + "\" --machinereadable");
                foreach (var line in info.Split(new[] { '\n' }))
                    if (line.StartsWith("VMState=")) return line.Substring(8).Trim().Trim('"');
            }
            catch (Exception ex) { Log("state " + name + ": " + ex.Message); }
            return "missing";
        }

        // run a command inside a computer (needs Guest Additions = computers made with version 3.0+)
        public static string Guest(Dictionary<string, object> r, string command, int timeoutMs = 90000)
        {
            var name = Store.S(r, "name");
            var args = "guestcontrol \"PC-" + name + "\" run --exe \"C:\\Windows\\System32\\cmd.exe\" --username \"" + Store.S(r, "adminName") +
                       "\" --password \"" + Store.S(r, "adminPassword") + "\" --wait-stdout --wait-stderr --timeout " + timeoutMs + " -- cmd.exe /c " + command;
            return Run(VBM, args, timeoutMs + 15000);
        }
        public static bool HasAgent(Dictionary<string, object> r) { return Store.S(r, "agent").ToLower() == "true"; }

        public static string CompName(string vm)
        {
            var c = ("PC-" + Regex.Replace(vm, "[^A-Za-z0-9-]", "")).ToUpper();
            return c.Length > 15 ? c.Substring(0, 15) : c;
        }
        public static string FullUser(Dictionary<string, object> r) { return CompName(Store.S(r, "name")) + "\\" + Store.S(r, "user"); }

        public static string RandomPassword()
        {
            const string U = "ABCDEFGHJKLMNPQRSTUVWXYZ", L = "abcdefghijkmnpqrstuvwxyz", D = "23456789";
            var rnd = new Random(); var c = new List<char>();
            for (int i = 0; i < 4; i++) { c.Add(U[rnd.Next(U.Length)]); c.Add(L[rnd.Next(L.Length)]); c.Add(D[rnd.Next(D.Length)]); }
            return new string(c.OrderBy(x => rnd.Next()).ToArray()) + "!";
        }
        public static string CheckPassword(string pw, string user)
        {
            if (pw.Length < 8 || !pw.Any(char.IsUpper) || !pw.Any(char.IsLower) || !pw.Any(char.IsDigit)) return "סיסמה: 8 תווים לפחות, עם אות גדולה, אות קטנה וספרה.";
            if (!Regex.IsMatch(pw, @"^[A-Za-z0-9!@#$*_\-+=.?]+$")) return "בסיסמה מותר: אותיות באנגלית, ספרות והסימנים ! @ # $ * _ - + = . ?";
            if (user.Length > 2 && pw.ToLower().Contains(user.ToLower())) return "הסיסמה לא יכולה להכיל את שם המשתמש.";
            return null;
        }

        // ---------- this computer ----------
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
        public static double TotalRamGB() { try { var m = new MEMSTAT(); return GlobalMemoryStatusEx(m) ? Math.Round(m.total / 1073741824.0) : 0; } catch { return 0; } }
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
        static void WriteRaw(List<Dictionary<string, object>> list) { File.WriteAllText(App.VmsFile, Json.Serialize(list), new UTF8Encoding(true)); }
        public static List<Dictionary<string, object>> All() { return Locked(() => ReadRaw()); }
        public static Dictionary<string, object> Get(string name) { return All().FirstOrDefault(r => S(r, "name") == name); }
        public static void Add(Dictionary<string, object> rec) { Locked(() => { var l = ReadRaw(); l.Add(rec); WriteRaw(l); return 0; }); }
        public static void Remove(string name) { Locked(() => { var l = ReadRaw(); l.RemoveAll(r => S(r, "name") == name); WriteRaw(l); return 0; }); }
        public static void Set(string name, string key, object value)
        {
            Locked(() => { var l = ReadRaw(); foreach (var r in l) if (S(r, "name") == name) r[key] = value; WriteRaw(l); return 0; });
        }
        public static string S(Dictionary<string, object> r, string k) { object v; return r != null && r.TryGetValue(k, out v) && v != null ? v.ToString() : ""; }
        public static int I(Dictionary<string, object> r, string k) { int i; return int.TryParse(S(r, k), out i) ? i : 0; }
    }
}
