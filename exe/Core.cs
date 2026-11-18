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
[assembly: AssemblyVersion("4.8.1.0")]

namespace SharedPC
{
    static partial class App
    {
        public const string Version = "4.8.1";
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
                if (SelfUpdate()) return;   // a newer version was downloaded and started instead of this one
                // first time on this computer: install VirtualBox + download Windows Server automatically
                if (!File.Exists(VBM) || !File.Exists(Iso) || new FileInfo(Iso).Length < 3L * 1024 * 1024 * 1024)
                {
                    var setup = new SetupForm();
                    Application.Run(setup);
                    if (!setup.Done) return;
                }
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

        // ---------- self-update: the program replaces itself with the newest version from GitHub ----------
        const string ExeUrl = "https://raw.githubusercontent.com/MaykoDev50/SharedPC/main/exe/";
        public static string LatestVersion()
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            using (var wc = new WebClient()) { wc.Headers.Add("Cache-Control", "no-cache"); return wc.DownloadString(ExeUrl + "manager-version.txt?t=" + DateTime.UtcNow.Ticks).Trim(); }
        }
        public static bool NewerAvailable(out string latest)
        {
            latest = ""; try { latest = LatestVersion(); return new System.Version(latest) > new System.Version(Version); } catch { return false; }
        }
        // downloads the new program next to this one, swaps them and starts the new one. true = caller must exit.
        public static bool SelfUpdate()
        {
            var exe = Application.ExecutablePath;
            try { File.Delete(exe + ".old"); } catch { }
            string latest; if (!NewerAvailable(out latest)) return false;
            try
            {
                var tmp = exe + ".new";
                using (var wc = new WebClient()) wc.DownloadFile(ExeUrl + "SharedPC-Manager.exe?t=" + DateTime.UtcNow.Ticks, tmp);
                var bytes = File.ReadAllBytes(tmp);
                if (bytes.Length < 100000 || bytes[0] != 'M' || bytes[1] != 'Z') { File.Delete(tmp); Log("update: bad download"); return false; }
                if (AssemblyName.GetAssemblyName(tmp).Version < new System.Version(latest)) { File.Delete(tmp); Log("update: downloaded file is older (GitHub cache) - later"); return false; }
                File.Move(exe, exe + ".old");          // a running program can be renamed, not overwritten
                File.Move(tmp, exe);
                Log("updated " + Version + " -> " + latest);
                Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe) });
                return true;
            }
            catch (Exception ex)
            {
                Log("update failed: " + ex.Message);
                try { if (!File.Exists(exe) && File.Exists(exe + ".old")) File.Move(exe + ".old", exe); } catch { }
                return false;
            }
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
        public static string VBox(string args)
        {
            for (int t = 1; ; t++)
            {
                var o = Run(VBM, args);
                // VirtualBox's background service stuck / started without admin rights (typical right after installing it)
                if (t > 3 || !Regex.IsMatch(o, "Failed to create the VirtualBox object|E_ACCESSDENIED|CO_E_SERVER_EXEC_FAILURE|0x80070005|0x80080005")) return o;
                if (Process.GetProcessesByName("VBoxHeadless").Length == 0 && Process.GetProcessesByName("VirtualBoxVM").Length == 0)
                    foreach (var n in new[] { "VirtualBox", "VBoxSVC", "VBoxSDS" }) foreach (var p in Process.GetProcessesByName(n)) try { p.Kill(); } catch { }
                Thread.Sleep(4000 * t);
            }
        }
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
        // run a PowerShell script inside (encoded, so no quoting problems)
        public static string GuestPs(Dictionary<string, object> r, string script, int timeoutMs = 90000)
        {
            var b64 = Convert.ToBase64String(Encoding.Unicode.GetBytes("$ProgressPreference='SilentlyContinue'; " + script));
            return Guest(r, "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + b64, timeoutMs);
        }
        // drive C: = exactly gb GB (Windows included). Grows or shrinks while the computer runs.
        public const int MinDiskGB = 20;
        public static string ResizeScript(int gb)
        {
            return "$t=[uint64]" + gb + "*1GB; $p=Get-Partition -DriveLetter C; $s=Get-PartitionSupportedSize -DriveLetter C; " +
                   "if([math]::Abs([double]$p.Size-[double]$t) -lt 64MB){'OK'} " +
                   "elseif($t -lt $s.SizeMin){'MIN '+[math]::Ceiling($s.SizeMin/1GB+1)} " +
                   "elseif($t -gt $s.SizeMax){'MAX '+[math]::Floor($s.SizeMax/1GB)} " +
                   "else{ try{ Resize-Partition -DriveLetter C -Size $t -ErrorAction Stop; 'OK' } catch { 'ERR '+$_.Exception.Message } }; " +
                   "fsutil quota disable C: | Out-Null";
        }
        public const string UsageScript = "$v=Get-Volume -DriveLetter C; 'USAGE {0} {1}' -f $v.Size,$v.SizeRemaining";
        // "USAGE <size> <free>" -> (usedGB, sizeGB)
        public static Tuple<double, double> ParseUsage(string output)
        {
            var m = Regex.Match(output, @"USAGE (\d+) (\d+)");
            if (!m.Success) return null;
            double size = double.Parse(m.Groups[1].Value), free = double.Parse(m.Groups[2].Value);
            return Tuple.Create(Math.Round((size - free) / 1073741824.0, 1), Math.Round(size / 1073741824.0));
        }
        public static string ResizeMessage(string name, int gb, string o)
        {
            var m = Regex.Match(o, @"\b(OK|MIN|MAX|ERR)\b ?(.*)");
            if (!GuestOk(o) || !m.Success) return "❌ השינוי נכשל:\n" + GuestProblem(o);
            switch (m.Groups[1].Value)
            {
                case "OK": return "✅ הכונן C: של " + name + " הוא עכשיו " + gb + " GB (כולל Windows).";
                case "MIN": return "❌ אי אפשר להקטין ל-" + gb + " GB: Windows והקבצים שכבר יש ב-" + name + " תופסים יותר.\nהכי קטן שאפשר עכשיו: " + m.Groups[2].Value.Trim() + " GB.";
                case "MAX": return "❌ אי אפשר להגדיל ל-" + gb + " GB. הכי גדול שאפשר: " + m.Groups[2].Value.Trim() + " GB.";
                default: return "❌ השינוי נכשל:\n" + m.Groups[2].Value.Trim();
            }
        }
        // ---------- desktop picture for all computers ----------
        public static readonly string WallpaperFile = Path.Combine(HostDir, "wallpaper.jpg");
        public static string WallpaperHash()
        {
            if (!File.Exists(WallpaperFile)) return "";
            using (var md5 = System.Security.Cryptography.MD5.Create()) return BitConverter.ToString(md5.ComputeHash(File.ReadAllBytes(WallpaperFile))).Replace("-", "").Substring(0, 12);
        }
        const string WallpaperSetup =
            "New-Item 'C:\\SharedPC' -ItemType Directory -Force | Out-Null; " +
            "$cmd = \"@echo off`r`nreg add `\"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System`\" /v Wallpaper /t REG_SZ /d `\"C:\\SharedPC\\wallpaper.jpg`\" /f >nul`r`n\" + " +
            "\"reg add `\"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System`\" /v WallpaperStyle /t REG_SZ /d 4 /f >nul`r`n\" + " +
            "\"reg add `\"HKCU\\Control Panel\\Desktop`\" /v Wallpaper /t REG_SZ /d `\"C:\\SharedPC\\wallpaper.jpg`\" /f >nul`r`n\" + " +
            "\"reg add `\"HKCU\\Control Panel\\Desktop`\" /v WallpaperStyle /t REG_SZ /d 10 /f >nul`r`n\" + " +
            "\"RUNDLL32.EXE user32.dll,UpdatePerUserSystemParameters 1, True`r`n\"; " +
            "Set-Content 'C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp\\sharedpc-wallpaper.cmd' $cmd -Encoding ASCII; " +
            "$pz = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization'; New-Item $pz -Force | Out-Null; " +
            "Set-ItemProperty $pz -Name LockScreenImage -Value 'C:\\SharedPC\\wallpaper.jpg'; Set-ItemProperty $pz -Name NoChangingLockScreen -Value 1 -Type DWord; " +
            "$ts = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services'; New-Item $ts -Force -ErrorAction SilentlyContinue | Out-Null; " +
            "Set-ItemProperty $ts -Name fNoRemoteDesktopWallpaper -Value 0 -Type DWord; 'WALLPAPER-OK'";
        // copy the picture into one computer and make it the desktop + lock screen for every user there
        public static string ApplyWallpaper(Dictionary<string, object> r)
        {
            if (!File.Exists(WallpaperFile)) return "no picture";
            var name = Store.S(r, "name");
            var o = GuestPs(r, "New-Item 'C:\\SharedPC' -ItemType Directory -Force | Out-Null; 'DIR-OK'", 60000);
            if (!o.Contains("DIR-OK")) return o;
            o = Run(VBM, "guestcontrol \"PC-" + name + "\" copyto --username \"" + Store.S(r, "adminName") + "\" --password \"" + Store.S(r, "adminPassword") +
                         "\" \"" + WallpaperFile + "\" \"C:\\SharedPC\\wallpaper.jpg\"", 120000);
            if (!GuestOk(o)) return o;
            o = GuestPs(r, WallpaperSetup, 60000);
            if (!o.Contains("WALLPAPER-OK")) return o;
            Store.Set(name, "wallpaper", WallpaperHash());
            Log("wallpaper applied to " + name);
            return "OK";
        }
        // makes sure the person can sign in over Remote Desktop, and reports why the last sign-ins failed
        public static string RepairLoginScript(string user)
        {
            return "$u='" + user + "'; 'HOST=' + $env:COMPUTERNAME; " +
                   "$a=[ADSI]\"WinNT://./$u,user\"; 'LOCKED=' + $a.IsAccountLocked; 'FLAGS=' + $a.UserFlags.Value; " +
                   "if ($a.IsAccountLocked) { $a.IsAccountLocked = $false; $a.SetInfo() }; " +
                   "net user $u /active:yes /passwordchg:yes | Out-Null; " +
                   "Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $u -ErrorAction SilentlyContinue; " +
                   "'RDPUSERS=' + ((Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object Name) -join ','); " +
                   "Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625} -MaxEvents 4 -ErrorAction SilentlyContinue | ForEach-Object { " +
                   "$x=[xml]$_.ToXml(); $d=@{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name]=$_.'#text' }; " +
                   "'FAIL ' + $_.TimeCreated.ToString('HH:mm:ss') + ' ' + $d.TargetDomainName + '\\' + $d.TargetUserName + ' status=' + $d.Status + ' sub=' + $d.SubStatus + ' type=' + $d.LogonType + ' from=' + $d.IpAddress }";
        }
        public static bool HasAgent(Dictionary<string, object> r) { return Store.S(r, "agent").ToLower() == "true"; }

        // ---------- power (always returns a clear message; never leaves the computer half-way) ----------
        static bool WaitState(string name, Func<string, bool> ok, int seconds)
        {
            for (int i = 0; i < seconds; i += 2) { if (ok(VmState(name))) return true; Thread.Sleep(2000); }
            return ok(VmState(name));
        }
        static bool IsOff(string s) { return s == "poweroff" || s == "aborted" || s == "saved" || s == "missing"; }
        public static string StartVm(string name)
        {
            var s = VmState(name);
            if (s == "missing") return "❌ המחשב " + name + " לא נמצא ב-VirtualBox.";
            if (s == "running") { Store.Set(name, "stopped", false); return "✅ " + name + " כבר דלוק."; }
            if (!IsOff(s)) WaitState(name, IsOff, 60);   // still shutting down - wait for it
            string o = "";
            for (int t = 0; t < 3; t++)
            {
                o = VBox("startvm \"PC-" + name + "\" --type headless");
                if (WaitState(name, x => x == "running", 20)) { Store.Set(name, "stopped", false); return "✅ " + name + " נדלק. עוד כדקה אפשר להתחבר."; }
                Thread.Sleep(5000);   // "already locked by a session" right after a shutdown - try again
            }
            Log("start " + name + " failed: " + o.Trim());
            return "❌ לא הצלחתי להדליק את " + name + ".\n\n" + o.Trim();
        }
        public static string StopVm(Dictionary<string, object> r)
        {
            var name = Store.S(r, "name"); var vm = "\"PC-" + name + "\"";
            if (VmState(name) != "running") { Store.Set(name, "stopped", true); return "✅ " + name + " כבר כבוי."; }
            Store.Set(name, "stopped", true);
            // 1) ask Windows inside to shut down (works even when nobody is logged in)
            if (HasAgent(r)) Guest(r, "shutdown /s /t 0 /f", 20000);
            if (WaitState(name, IsOff, 40)) return "✅ " + name + " כבוי.";
            // 2) the power button
            VBox("controlvm " + vm + " acpipowerbutton");
            if (WaitState(name, IsOff, 50)) return "✅ " + name + " כבוי.";
            // 3) pull the plug
            var o = VBox("controlvm " + vm + " poweroff");
            if (WaitState(name, IsOff, 20)) return "✅ " + name + " כבוי (כיבוי בכוח – Windows לא הגיב).";
            Log("stop " + name + " failed: " + o.Trim());
            return "❌ לא הצלחתי לכבות את " + name + ".\n\n" + o.Trim();
        }
        public static string RestartVm(Dictionary<string, object> r)
        {
            var name = Store.S(r, "name");
            if (VmState(name) != "running") return StartVm(name);
            if (HasAgent(r) && GuestStarted(Guest(r, "shutdown /r /t 0 /f", 20000))) { Store.Set(name, "stopped", false); return "✅ " + name + " מופעל מחדש. עוד כדקה אפשר להתחבר."; }
            var o = VBox("controlvm \"PC-" + name + "\" reset");
            Store.Set(name, "stopped", false);
            return o.Contains("error") ? "❌ ההפעלה מחדש נכשלה.\n\n" + o.Trim() : "✅ " + name + " מופעל מחדש. עוד כדקה אפשר להתחבר.";
        }
        // the command reached Windows inside (a reboot may cut the channel afterwards - that is fine)
        public static bool GuestStarted(string output) { return !output.Contains("not installed or not ready") && !output.Contains("CreateSession") && !output.Contains("not running"); }
        public static bool GuestOk(string output) { return output.IndexOf("VBoxManage.exe: error", StringComparison.OrdinalIgnoreCase) < 0; }
        // turn a guestcontrol error into something a person understands
        public static string GuestProblem(string output)
        {
            if (output.Contains("not installed or not ready")) return "המחשב עוד עולה ועדיין לא מוכן לפקודות.\nחכה דקה-שתיים (אחרי שהוא נדלק) ונסה שוב.";
            if (output.Contains("not running") || output.Contains("is not currently running")) return "המחשב כבוי. הדלק אותו ונסה שוב.";
            if (output.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 || output.Contains("logon")) return "ערוץ הניהול לא מצליח להיכנס למחשב.\n\n" + output.Trim();
            return output.Trim();
        }

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
