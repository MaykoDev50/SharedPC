// SharedPC Manager - the windows (dark, modern dashboard)
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace SharedPC
{
    // ================= theme =================
    static class T
    {
        public static readonly Color Bg = Color.FromArgb(11, 15, 25), Panel = Color.FromArgb(19, 25, 40), Card = Color.FromArgb(26, 34, 53),
            CardHover = Color.FromArgb(33, 43, 66), Border = Color.FromArgb(45, 56, 82), Text = Color.FromArgb(236, 240, 247), Muted = Color.FromArgb(143, 155, 179),
            Accent = Color.FromArgb(99, 102, 241), Accent2 = Color.FromArgb(56, 189, 248), Green = Color.FromArgb(34, 197, 94), Yellow = Color.FromArgb(250, 204, 21),
            Red = Color.FromArgb(239, 68, 68), Gray = Color.FromArgb(100, 116, 139);
        public static Font F(float size, bool bold = false) { return new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular); }
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            var p = new GraphicsPath(); int d = radius * 2;
            if (radius <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure();
            return p;
        }
        public const TextFormatFlags RTL = TextFormatFlags.RightToLeft | TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
        public const TextFormatFlags LTR = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
        public static void Dark(Form f)
        {
            f.BackColor = Bg; f.ForeColor = Text; f.Font = F(10.5f);
            f.RightToLeft = RightToLeft.Yes; f.RightToLeftLayout = true; f.StartPosition = FormStartPosition.CenterScreen;
            f.AutoScaleDimensions = new SizeF(96F, 96F); f.AutoScaleMode = AutoScaleMode.Dpi;
            try { f.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        }
        public static Label Lbl(string text, float size = 10, bool bold = false, Color? color = null)
        {
            return new Label { Text = text, AutoSize = true, ForeColor = color ?? Muted, Font = F(size, bold), BackColor = Color.Transparent };
        }
        public static Color Under(Control c) { var p = c.Parent; return p is Card ? ((Card)p).Fill : p != null ? p.BackColor : Bg; }
        public static TextBox Box(int width, bool ltr = true)
        {
            return new TextBox { Width = width, BackColor = Card, ForeColor = Text, BorderStyle = BorderStyle.FixedSingle, Font = F(12), RightToLeft = ltr ? RightToLeft.No : RightToLeft.Yes };
        }
        public static NumericUpDown Num(int min, int max, int val, int width = 110)
        {
            return new NumericUpDown { Minimum = min, Maximum = max, Value = Math.Max(min, Math.Min(max, val)), Width = width, BackColor = Card, ForeColor = Text, Font = F(12), RightToLeft = RightToLeft.No, BorderStyle = BorderStyle.FixedSingle };
        }
    }

    // ================= controls =================
    class Btn : Button
    {
        public Color Base; bool hover, down;
        public Btn(string text, Color baseColor, int w = 140, int h = 40)
        {
            Text = text; Base = baseColor; Size = new Size(w, h); FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
            ForeColor = Color.White; Font = T.F(10.5f, true); Cursor = Cursors.Hand; Margin = new Padding(5); AccessibleName = text;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            MouseEnter += (s, e) => { hover = true; Invalidate(); }; MouseLeave += (s, e) => { hover = false; down = false; Invalidate(); };
            MouseDown += (s, e) => { down = true; Invalidate(); }; MouseUp += (s, e) => { down = false; Invalidate(); };
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(T.Under(this));
            var c = !Enabled ? T.Gray : down ? ControlPaint.Dark(Base, 0.1f) : hover ? ControlPaint.Light(Base, 0.25f) : Base;
            using (var p = T.Round(new Rectangle(0, 0, Width - 1, Height - 1), 9)) using (var b = new SolidBrush(c)) g.FillPath(b, p);
            if (Focused && ShowFocusCues) using (var p = T.Round(new Rectangle(1, 1, Width - 3, Height - 3), 8)) using (var pen = new Pen(Color.FromArgb(180, 255, 255, 255), 1.5f)) g.DrawPath(pen, p);
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, Enabled ? ForeColor : Color.FromArgb(200, 210, 220), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.RightToLeft);
        }
    }

    class Card : Panel
    {
        public int Radius = 14; public Color Fill = T.Panel; public Color? Stroke = T.Border;
        public Card() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true); BackColor = T.Bg; Padding = new Padding(18); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(Parent != null ? Parent.BackColor : T.Bg);
            using (var p = T.Round(new Rectangle(0, 0, Width - 1, Height - 1), Radius)) using (var b = new SolidBrush(Fill))
            {
                g.FillPath(b, p);
                if (Stroke.HasValue) using (var pen = new Pen(Stroke.Value)) g.DrawPath(pen, p);
            }
        }
    }

    class Chip : Control
    {
        public string Icon = "", Value = "", Caption = ""; public Color Tint = T.Accent;
        public Chip() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true); Size = new Size(190, 58); Margin = new Padding(6); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(Parent != null ? Parent.BackColor : T.Bg);
            using (var p = T.Round(new Rectangle(0, 0, Width - 1, Height - 1), 12)) using (var b = new SolidBrush(T.Card)) g.FillPath(b, p);
            using (var b = new SolidBrush(Color.FromArgb(40, Tint))) g.FillEllipse(b, Width - 48, 11, 36, 36);
            TextRenderer.DrawText(g, Icon, T.F(14), new Rectangle(Width - 48, 11, 36, 36), Tint, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            TextRenderer.DrawText(g, Value, T.F(12.5f, true), new Rectangle(8, 6, Width - 64, 26), T.Text, T.RTL);
            TextRenderer.DrawText(g, Caption, T.F(8.5f), new Rectangle(8, 31, Width - 64, 20), T.Muted, T.RTL);
        }
    }

    class Bar : Control
    {
        public double Value, Max = 1; public Color Tint = T.Accent2;
        public Bar() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true); Height = 10; }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(T.Under(this));
            using (var p = T.Round(new Rectangle(0, 0, Width - 1, Height - 1), Height / 2)) using (var b = new SolidBrush(T.Card)) g.FillPath(b, p);
            var frac = Max > 0 ? Math.Max(0, Math.Min(1, Value / Max)) : 0;
            var w = (int)((Width - 1) * frac); if (w < Height && frac > 0) w = Height;
            if (w > 0)
            {
                var c = frac > 0.9 ? T.Red : frac > 0.75 ? T.Yellow : Tint;
                // fills from the right (RTL)
                using (var p = T.Round(new Rectangle(Width - 1 - w, 0, w, Height - 1), Height / 2)) using (var b = new SolidBrush(c)) g.FillPath(b, p);
            }
        }
    }

    class VmTile : Control
    {
        public string VmName = "", User = "", StateText = "", Port = ""; public Color Dot = T.Gray; public bool Selected; bool hover;
        public event Action<string> Picked;
        public VmTile()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.Selectable, true);
            Height = 78; Margin = new Padding(0, 0, 0, 10); Cursor = Cursors.Hand; TabStop = true;
            MouseEnter += (s, e) => { hover = true; Invalidate(); }; MouseLeave += (s, e) => { hover = false; Invalidate(); };
            Click += (s, e) => { Focus(); if (Picked != null) Picked(VmName); };
            KeyDown += (s, e) => { if ((e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) && Picked != null) Picked(VmName); };
            GotFocus += (s, e) => Invalidate(); LostFocus += (s, e) => Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            AccessibleName = VmName + " " + StateText;
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(Parent != null ? Parent.BackColor : T.Bg);
            var fill = Selected ? Color.FromArgb(40, 44, 92) : hover ? T.CardHover : T.Card;
            using (var p = T.Round(new Rectangle(0, 0, Width - 1, Height - 1), 12)) using (var b = new SolidBrush(fill))
            {
                g.FillPath(b, p);
                if (Selected || Focused) using (var pen = new Pen(T.Accent, 2)) g.DrawPath(pen, p);
            }
            // avatar
            var av = new Rectangle(Width - 60, 15, 46, 46);
            using (var br = new LinearGradientBrush(av, T.Accent, T.Accent2, 45f)) g.FillEllipse(br, av);
            TextRenderer.DrawText(g, VmName.Length > 0 ? VmName.Substring(0, 1).ToUpper() : "?", T.F(15, true), av, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            using (var b = new SolidBrush(Dot)) g.FillEllipse(b, Width - 24, 50, 12, 12);
            using (var pen = new Pen(fill, 2)) g.DrawEllipse(pen, Width - 24, 50, 12, 12);
            TextRenderer.DrawText(g, VmName, T.F(12, true), new Rectangle(12, 12, Width - 84, 26), T.Text, T.RTL);
            TextRenderer.DrawText(g, StateText, T.F(9), new Rectangle(12, 40, Width - 84, 22), T.Muted, T.RTL);
            TextRenderer.DrawText(g, ":" + Port, T.F(9, true), new Rectangle(12, 12, 70, 26), T.Accent2, T.LTR);
        }
    }

    // ================= main window =================
    class MainForm : Form
    {
        // header
        Chip chipCount = new Chip { Icon = "🖥️", Tint = T.Accent }, chipRam = new Chip { Icon = "🧠", Tint = T.Accent2 }, chipDisk = new Chip { Icon = "💾", Tint = T.Green };
        Label routerLbl = T.Lbl("🌐 בודק את הראוטר…", 10, true, T.Yellow);
        Label siteLbl = T.Lbl("🌍 אתר ללקוחות: …", 10, true, T.Accent2);
        FlowLayoutPanel siteRow = new FlowLayoutPanel();
        string SiteUrl() { return "http://" + publicIp + ":" + App.WebPort; }
        // list
        FlowLayoutPanel list = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, BackColor = T.Bg, Padding = new Padding(0, 4, 8, 4) };
        Label listEmpty = T.Lbl("עדיין אין מחשבים.\nלחץ \"מחשב חדש\" כדי להתחיל.", 11, false, T.Muted);
        // details
        Panel details = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = T.Bg, Padding = new Padding(20, 6, 20, 20) };
        Label dName = T.Lbl("", 22, true, T.Text), dState = T.Lbl("", 10.5f, true, T.Muted), dMeta = T.Lbl("", 9.5f);
        Label cHome = T.Lbl("", 13, true, T.Text), cAddr = T.Lbl("", 13, true, T.Text), cUser = T.Lbl("", 13, true, T.Text), cPass = T.Lbl("", 13, true, T.Text);
        Bar usageBar = new Bar { Width = 560 }; Label usageLbl = T.Lbl("", 10, false, T.Muted);
        NumericUpDown gbNum = T.Num(App.MinDiskGB, 2000, 50), ramNum = T.Num(2, 64, 4);
        TextBox pwBox = T.Box(250); CheckBox adminChk = new CheckBox { Text = "הרשאות מנהל (התקנת תוכנות)", AutoSize = true, ForeColor = T.Text, Font = T.F(10.5f), BackColor = Color.Transparent };
        Label agentNote = T.Lbl("", 9.5f, false, T.Yellow);
        Btn bStart, bStop, bRestart, bConnect;
        bool passShown;

        string publicIp = "…", lanIp = App.LanIp();
        string selected;
        Dictionary<string, VmTile> tiles = new Dictionary<string, VmTile>();
        Dictionary<string, string> states = new Dictionary<string, string>();
        Dictionary<string, string> working = new Dictionary<string, string>();   // name -> "starting"/"stopping" while a power action runs
        Dictionary<string, Tuple<double, DateTime>> usage = new Dictionary<string, Tuple<double, DateTime>>();
        Dictionary<string, double> driveSize = new Dictionary<string, double>();
        Dictionary<string, DateTime> wpTried = new Dictionary<string, DateTime>();   // desktop picture: last attempt per computer   // real size of C: inside
        System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 8000 };
        bool loading; string lastPorts; DateTime lastSync = DateTime.MinValue;

        public MainForm()
        {
            T.Dark(this);
            Text = App.Title + "  ·  גרסה " + App.Version; Size = new Size(1240, 800); MinimumSize = new Size(1040, 680);

            // ---------- header ----------
            var header = new Panel { Dock = DockStyle.Top, Height = 216, BackColor = T.Bg, Padding = new Padding(22, 16, 22, 0) };
            var titleRow = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 54, BackColor = T.Bg, WrapContents = false };
            titleRow.Controls.Add(T.Lbl("SharedPC", 22, true, T.Text));
            var sub = T.Lbl("ניהול מחשבים וירטואליים", 11, false, T.Muted); sub.Margin = new Padding(10, 14, 0, 0); titleRow.Controls.Add(sub);
            var bNew = new Btn("＋  מחשב חדש", T.Accent, 170, 44); bNew.Font = T.F(11.5f, true);
            bNew.Click += (s, e) => NewComputer();
            var newWrap = new Panel { Dock = DockStyle.Left, Width = 190, BackColor = T.Bg }; newWrap.Controls.Add(bNew); bNew.Location = new Point(0, 4);
            var chips = new FlowLayoutPanel { Dock = DockStyle.Fill, BackColor = T.Bg, WrapContents = false, Padding = new Padding(0, 6, 0, 0) };
            chips.Controls.AddRange(new Control[] { chipCount, chipRam, chipDisk });
            var chipRow = new Panel { Dock = DockStyle.Top, Height = 70, BackColor = T.Bg };
            chipRow.Controls.Add(chips); chipRow.Controls.Add(newWrap);
            routerLbl.Dock = DockStyle.Top; routerLbl.AutoSize = false; routerLbl.Height = 24; routerLbl.TextAlign = ContentAlignment.MiddleRight;
            siteRow.Dock = DockStyle.Top; siteRow.Height = 34; siteRow.BackColor = T.Bg; siteRow.WrapContents = false;
            siteLbl.Margin = new Padding(0, 8, 0, 0);
            var openSite = new Btn("פתח", T.Card, 64, 28); openSite.Font = T.F(9, true); openSite.Click += (s, e) => Process.Start("http://127.0.0.1:" + App.WebPort + "/");
            var copySite = new Btn("העתק", T.Card, 64, 28); copySite.Font = T.F(9, true); copySite.Click += (s, e) => CopyText(SiteUrl());
            var remote = new Btn("🛡️ ניהול מרחוק", T.Accent, 140, 28); remote.Font = T.F(9, true);
            remote.Click += (s, e) =>
            {
                var pw = App.AdminPassword();
                var txt = "פאנל ניהול מרחוק (לך ולשותפים בלבד):\r\n" + SiteUrl() + "/admin\r\nסיסמת ניהול: " + pw;
                Clipboard.SetText(txt);
                App.Say(txt + "\n\n✅ הועתק. שלח לשותף יחד עם התוכנה SharedPC-Admin.\nמי שיש לו את הסיסמה הזו יכול ליצור ולמחוק מחשבים – אל תשלח אותה ללקוחות.");
            };
            var wall = new Btn("🖼️ תמונת רקע", T.Card, 120, 28); wall.Font = T.F(9, true);
            wall.Click += (s, e) => PickWallpaper();
            siteRow.Controls.AddRange(new Control[] { siteLbl, copySite, openSite, remote, wall });
            header.Controls.Add(siteRow); header.Controls.Add(routerLbl); header.Controls.Add(chipRow); header.Controls.Add(titleRow);

            // ---------- list (right side) ----------
            var left = new Panel { Dock = DockStyle.Left, Width = 330, BackColor = T.Bg, Padding = new Padding(22, 10, 0, 20) };
            var listHead = T.Lbl("המחשבים שלך", 11, true, T.Muted); listHead.Dock = DockStyle.Top; listHead.AutoSize = false; listHead.Height = 30;
            left.Controls.Add(list); left.Controls.Add(listHead);
            listEmpty.Margin = new Padding(10, 20, 10, 0);

            BuildDetails();
            Controls.Add(details); Controls.Add(left); Controls.Add(header);

            timer.Tick += (s, e) => Reload();
            Shown += (s, e) => { Reload(); timer.Start(); FetchPublicIp(); };
            // while open: look for a new version every 2 hours
            var upd = new System.Windows.Forms.Timer { Interval = 2 * 60 * 60 * 1000 }; bool asked = false;
            upd.Tick += (s, e) => Task.Run(() => { string v; return App.NewerAvailable(out v) ? v : null; }).ContinueWith(t =>
            {
                if (t.Result == null || asked || !IsHandleCreated) return;
                BeginInvoke((Action)(() =>
                {
                    asked = true;
                    if (App.Ask("יש גרסה חדשה של התוכנה (" + t.Result + ").\nלעדכן עכשיו? התוכנה תיסגר ותיפתח מחדש תוך כמה שניות.\n(המחשבים של הלקוחות ממשיכים לעבוד כרגיל)"))
                    { if (App.SelfUpdate()) Application.Exit(); else App.Say("העדכון לא הצליח עכשיו – הוא ינסה שוב בפתיחה הבאה."); }
                }));
            });
            upd.Start();
            KeyPreview = true;
            KeyDown += (s, e) => { if (e.Control && e.KeyCode == Keys.N) NewComputer(); if (e.KeyCode == Keys.F5) Reload(); };
        }

        void PickWallpaper()
        {
            using (var d = new OpenFileDialog { Title = "תמונת רקע לכל המחשבים", Filter = "תמונות|*.jpg;*.jpeg;*.png;*.bmp;*.webp|הכל|*.*" })
            {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                try
                {
                    using (var img = Image.FromFile(d.FileName))
                    using (var bmp = new Bitmap(img.Width, img.Height))
                    {
                        using (var g = Graphics.FromImage(bmp)) { g.Clear(Color.Black); g.DrawImage(img, 0, 0, img.Width, img.Height); }
                        bmp.Save(App.WallpaperFile + ".tmp", System.Drawing.Imaging.ImageFormat.Jpeg);
                    }
                    if (File.Exists(App.WallpaperFile)) File.Delete(App.WallpaperFile);
                    File.Move(App.WallpaperFile + ".tmp", App.WallpaperFile);
                }
                catch (Exception ex) { App.Say("לא הצלחתי לפתוח את התמונה:\n" + ex.Message); return; }
                lock (wpTried) wpTried.Clear();
                Reload();
                App.Say("✅ התמונה נשמרה.\nתוך דקה היא תיכנס לכל המחשבים הדלוקים (וגם לכל מחשב חדש ולכל מחשב שיידלק).\nהלקוחות יראו אותה מהכניסה הבאה שלהם – וגם אם מישהו מחליף אותה, בכניסה הבאה היא חוזרת.");
            }
        }

        // ---------- details panel ----------
        Card Section(string title, int height)
        {
            var c = new Card { Height = height, Dock = DockStyle.Top };
            var t = T.Lbl(title, 11.5f, true, T.Text); t.Location = new Point(18, 14); t.BackColor = T.Panel;
            c.Controls.Add(t);
            return c;
        }
        static Panel Gap(int h) { return new Panel { Height = h, Dock = DockStyle.Top, BackColor = T.Bg }; }
        Control Place(Control parent, Control c, int x, int y) { c.Location = new Point(x, y); if (c is Label) c.BackColor = T.Panel; parent.Controls.Add(c); return c; }

        void BuildDetails()
        {
            // top: name + state + quick actions
            var top = new Panel { Dock = DockStyle.Top, Height = 118, BackColor = T.Bg };
            var nameBox = new Panel { Dock = DockStyle.Fill, BackColor = T.Bg };
            dName.Location = new Point(0, 0); dState.Location = new Point(4, 48); dMeta.Location = new Point(4, 76);
            nameBox.Controls.AddRange(new Control[] { dName, dState, dMeta });
            var qa = new FlowLayoutPanel { Location = new Point(0, 0), AutoSize = true, BackColor = T.Bg, Anchor = AnchorStyles.Top | AnchorStyles.Left };
            bStart = new Btn("▶  הפעל", T.Green, 110); bStop = new Btn("⏻  כבה", T.Gray, 100); bRestart = new Btn("↻  הפעל מחדש", T.Gray, 140); bConnect = new Btn("🖱️  התחבר", T.Accent, 120);
            bStart.Click += (s, e) => Power("start"); bStop.Click += (s, e) => Power("stop"); bRestart.Click += (s, e) => Power("restart"); bConnect.Click += (s, e) => ConnectMyself();
            qa.Controls.AddRange(new Control[] { bConnect, bStart, bRestart, bStop });
            var qaWrap = new Panel { Dock = DockStyle.Right, Width = 530, BackColor = T.Bg }; qaWrap.Controls.Add(qa); qa.Location = new Point(0, 20);
            top.Controls.Add(nameBox); top.Controls.Add(qaWrap);

            // connection details
            var conn = Section("🔗  פרטי חיבור", 264);
            Place(conn, T.Lbl("🌍 כתובת ללקוח – מחוץ לבית (חיבור לשולחן עבודה מרוחק)", 9.5f), 18, 50); Place(conn, cAddr, 18, 70);
            Place(conn, T.Lbl("🏠 כתובת בתוך הבית – מהמחשב הזה או מכל מכשיר ברשת הביתית (הכתובת החיצונית לא עובדת מתוך הבית)", 9.5f, false, T.Yellow), 18, 104); Place(conn, cHome, 18, 124);
            Place(conn, T.Lbl("שם משתמש", 9.5f), 18, 158); Place(conn, cUser, 18, 178);
            Place(conn, T.Lbl("סיסמה", 9.5f), 18, 212); Place(conn, cPass, 18, 230);
            var copyAll = new Btn("📋  העתק הכל", T.Accent, 150, 40); copyAll.Click += (s, e) => CopyAll();
            var copyAddr = new Btn("העתק", T.Card, 74, 30); copyAddr.Font = T.F(9, true); copyAddr.Click += (s, e) => CopyText(cAddr.Text);
            var copyHome = new Btn("העתק", T.Card, 74, 30); copyHome.Font = T.F(9, true); copyHome.Click += (s, e) => CopyText(cHome.Text);
            var copyUser = new Btn("העתק", T.Card, 74, 30); copyUser.Font = T.F(9, true); copyUser.Click += (s, e) => CopyText(cUser.Text);
            var showPw = new Btn("👁  הצג", T.Card, 74, 30); showPw.Font = T.F(9, true); showPw.Click += (s, e) => { passShown = !passShown; ShowSelected(); };
            var copyPw = new Btn("העתק", T.Card, 74, 30); copyPw.Font = T.F(9, true); copyPw.Click += (s, e) => { var r = Store.Get(selected); if (r != null) CopyText(Store.S(r, "password")); };
            conn.Resize += (s, e) =>
            {
                int w = conn.Width; copyAll.Location = new Point(w - 170, 14);
                copyAddr.Location = new Point(w - 94, 68); copyHome.Location = new Point(w - 94, 122); copyUser.Location = new Point(w - 94, 176);
                copyPw.Location = new Point(w - 94, 226); showPw.Location = new Point(w - 174, 226);
            };
            conn.Controls.AddRange(new Control[] { copyAll, copyAddr, copyHome, copyUser, showPw, copyPw });

            // usage
            var use = Section("💾  נפח אחסון", 120);
            Place(use, usageBar, 18, 58); Place(use, usageLbl, 18, 78);
            var refUse = new Btn("↻  בדוק", T.Card, 90, 30); refUse.Font = T.F(9, true); refUse.Click += (s, e) => FetchUsage(selected, true);
            use.Resize += (s, e) => { refUse.Location = new Point(use.Width - 110, 12); usageBar.Width = use.Width - 40; };
            use.Controls.Add(refUse);

            // settings
            var set = Section("⚙️  הגדרות", 250);
            Place(set, T.Lbl("כונן C: (GB, כולל Windows)", 10), 18, 54); Place(set, gbNum, 18, 78);
            var saveGb = new Btn("שמור", T.Accent, 80, 32); saveGb.Font = T.F(9.5f, true); Place(set, saveGb, 136, 76); saveGb.Click += (s, e) => SaveGb();
            Place(set, T.Lbl("זיכרון RAM (GB)", 10), 250, 54); Place(set, ramNum, 250, 78);
            var saveRam = new Btn("שמור", T.Accent, 80, 32); saveRam.Font = T.F(9.5f, true); Place(set, saveRam, 368, 76); saveRam.Click += (s, e) => SaveRam();
            Place(set, T.Lbl("סיסמה חדשה", 10), 18, 124); Place(set, pwBox, 18, 148);
            var gen = new Btn("🎲", T.Card, 44, 32); Place(set, gen, 276, 146); gen.Click += (s, e) => pwBox.Text = App.RandomPassword();
            var savePw = new Btn("שנה סיסמה", T.Accent, 120, 32); savePw.Font = T.F(9.5f, true); Place(set, savePw, 328, 146); savePw.Click += (s, e) => SavePassword();
            adminChk.Location = new Point(18, 196); set.Controls.Add(adminChk); adminChk.BackColor = T.Panel;
            var saveAdm = new Btn("שמור", T.Accent, 80, 32); saveAdm.Font = T.F(9.5f, true); Place(set, saveAdm, 290, 192); saveAdm.Click += (s, e) => SaveAdmin();
            agentNote.MaximumSize = new Size(560, 0); Place(set, agentNote, 18, 228);

            // tools
            var tools = Section("🧰  כלים", 110);
            var shot = new Btn("📷  מה רואים במסך", T.Card, 170); var log = new Btn("📄  יומן הקמה", T.Card, 140); var del = new Btn("🗑  מחק מחשב", T.Red, 140);
            shot.Click += (s, e) => Screenshot(); log.Click += (s, e) => OpenLog(); del.Click += (s, e) => Delete();
            var tf = new FlowLayoutPanel { Location = new Point(12, 48), AutoSize = true, BackColor = T.Panel }; tf.Controls.AddRange(new Control[] { shot, log, del }); tools.Controls.Add(tf);

            // empty state
            var empty = new Card { Dock = DockStyle.Top, Height = 220, Name = "empty" };
            var e1 = T.Lbl("👋  ברוך הבא ל-SharedPC", 18, true, T.Text); e1.Location = new Point(26, 30); e1.BackColor = T.Panel;
            var e2 = T.Lbl("כל מחשב כאן הוא מחשב Windows נפרד ללקוח אחד.\nהלקוח מתחבר מכל מקום עם כתובת, שם משתמש וסיסמה.", 11, false, T.Muted); e2.Location = new Point(28, 76); e2.BackColor = T.Panel;
            var e3 = new Btn("＋  צור את המחשב הראשון", T.Accent, 240, 46); e3.Location = new Point(28, 140); e3.Click += (s, e) => NewComputer();
            empty.Controls.AddRange(new Control[] { e1, e2, e3 });

            // stack (reverse order because of Dock.Top)
            foreach (var c in new Control[] { tools, Gap(14), set, Gap(14), use, Gap(14), conn, Gap(6), top, empty })
                details.Controls.Add(c);
            ShowSelected();
        }

        // ---------- data refresh ----------
        void FetchPublicIp()
        {
            Task.Run(() => { try { using (var wc = new WebClient()) return wc.DownloadString("https://api.ipify.org").Trim(); } catch { return "?"; } })
                .ContinueWith(t => { publicIp = t.Result; if (IsHandleCreated) BeginInvoke((Action)Reload); });
        }

        void Reload()
        {
            if (loading) return; loading = true;
            Task.Run(() =>
            {
                var recs = Store.All();
                var st = new Dictionary<string, string>(); int ramOn = 0, running = 0;
                foreach (var r in recs)
                {
                    var n = Store.S(r, "name"); var s = App.VmState(n); st[n] = s;
                    if (s == "running") { running++; ramOn += Store.I(r, "ramGB"); }
                }
                // desktop picture: push it into every running computer that doesn't have the current one yet
                var wp = App.WallpaperHash();
                if (wp != "")
                    foreach (var r in recs)
                    {
                        var n = Store.S(r, "name"); DateTime last;
                        if (Store.S(r, "status") != "ready" || !App.HasAgent(r) || st[n] != "running" || Store.S(r, "wallpaper") == wp) continue;
                        lock (wpTried) { if (wpTried.TryGetValue(n, out last) && (DateTime.Now - last).TotalMinutes < 3) continue; wpTried[n] = DateTime.Now; }
                        var rec = r; Task.Run(() => { var res = App.ApplyWallpaper(rec); if (res != "OK") App.Log("wallpaper " + Store.S(rec, "name") + ": " + res.Trim()); });
                    }
                var ready = recs.Where(r => Store.S(r, "status") == "ready").Select(r => Store.I(r, "port")).Where(p => p > 0).ToList(); ready.Add(App.WebPort);
                var key = string.Join(",", ready.OrderBy(p => p));
                if (publicIp != "…" && (key != lastPorts || (DateTime.Now - lastSync).TotalMinutes > 10))
                { Router.Sync(lanIp, publicIp, ready); lastPorts = key; lastSync = DateTime.Now; }
                return Tuple.Create(recs, st, ramOn, running);
            }).ContinueWith(t =>
            {
                if (!IsHandleCreated) return;
                BeginInvoke((Action)(() =>
                {
                    loading = false;
                    if (t.IsFaulted) { App.Log("reload: " + t.Exception); return; }
                    var recs = t.Result.Item1; states = t.Result.Item2;
                    foreach (var w in working) states[w.Key] = w.Value;
                    UpdateList(recs);
                    chipCount.Value = t.Result.Item4 + " / " + recs.Count; chipCount.Caption = "מחשבים פועלים";
                    chipRam.Value = t.Result.Item3 + " / " + App.TotalRamGB() + " GB"; chipRam.Caption = "זיכרון בשימוש";
                    chipDisk.Value = App.FreeDiskGB() + " GB"; chipDisk.Caption = "פנוי בדיסק";
                    foreach (var c in new[] { chipCount, chipRam, chipDisk }) c.Invalidate();
                    routerLbl.Text = "🌐  " + Router.Status + "     ·     IP: " + publicIp;
                    routerLbl.ForeColor = Router.Ok ? T.Green : T.Yellow;
                    siteLbl.Text = "🌍 אתר ללקוחות:  " + SiteUrl() + "   (הלקוח נכנס עם שם המשתמש והסיסמה שלו)";
                    ShowSelected();
                }));
            });
        }

        static string StateText(Dictionary<string, object> r, string state)
        {
            var status = Store.S(r, "status");
            if (status == "creating") return "⏳ בהקמה · " + Store.S(r, "step");
            if (status == "failed") return "❌ נכשל · " + Store.S(r, "step");
            return state == "running" ? "פועל" : state == "missing" ? "לא נמצא" : state == "starting" ? "עולה…" : state == "stopping" ? "נכבה…" : "כבוי";
        }
        static Color StateColor(Dictionary<string, object> r, string state)
        {
            var status = Store.S(r, "status");
            if (status == "creating") return T.Yellow; if (status == "failed") return T.Red;
            return state == "running" ? T.Green : state == "missing" ? T.Red : T.Gray;
        }

        void UpdateList(List<Dictionary<string, object>> recs)
        {
            var names = recs.Select(r => Store.S(r, "name")).ToList();
            if (!names.SequenceEqual(tiles.Keys))
            {
                list.SuspendLayout(); list.Controls.Clear(); tiles.Clear();
                foreach (var n in names) { var tile = new VmTile { VmName = n, Width = list.ClientSize.Width - 14 }; tile.Picked += Select; tiles[n] = tile; list.Controls.Add(tile); }
                if (names.Count == 0) list.Controls.Add(listEmpty);
                list.ResumeLayout();
            }
            foreach (var r in recs)
            {
                var n = Store.S(r, "name"); var tile = tiles[n]; string s; states.TryGetValue(n, out s);
                tile.User = Store.S(r, "user"); tile.Port = Store.S(r, "port");
                tile.StateText = StateText(r, s) + " · " + Store.S(r, "user"); tile.Dot = StateColor(r, s); tile.Selected = n == selected;
                tile.Width = list.ClientSize.Width - 14; tile.Invalidate();
            }
            if (selected == null || !tiles.ContainsKey(selected)) selected = names.FirstOrDefault();
        }

        void Select(string name)
        {
            selected = name; passShown = false; pwBox.Text = "";
            foreach (var kv in tiles) { kv.Value.Selected = kv.Key == name; kv.Value.Invalidate(); }
            var r = Store.Get(name);
            if (r != null) { gbNum.Value = Math.Max(gbNum.Minimum, Math.Min(gbNum.Maximum, Store.I(r, "diskGB"))); ramNum.Value = Math.Max(ramNum.Minimum, Math.Min(ramNum.Maximum, Store.I(r, "ramGB"))); adminChk.Checked = Store.S(r, "admin").ToLower() == "true"; }
            ShowSelected();
            FetchUsage(name, false);
        }

        void ShowSelected()
        {
            var r = selected != null ? Store.Get(selected) : null;
            var empty = details.Controls["empty"];
            foreach (Control c in details.Controls) c.Visible = (r == null) == (c == empty);
            if (r == null) return;
            if (gbNum.Tag as string != selected) { gbNum.Tag = selected; Select(selected); return; }
            string s; states.TryGetValue(selected, out s);
            dName.Text = selected; dState.Text = "●  " + StateText(r, s); dState.ForeColor = StateColor(r, s);
            dMeta.Text = "נוצר: " + Store.S(r, "created").Replace("T", " ") + "     ·     זיכרון: " + Store.S(r, "ramGB") + " GB     ·     פורט: " + Store.S(r, "port");
            cAddr.Text = publicIp + ":" + Store.S(r, "port");
            cHome.Text = lanIp + ":" + Store.S(r, "port");
            cUser.Text = App.FullUser(r);
            cPass.Text = passShown ? Store.S(r, "password") : "••••••••••";
            var ready = Store.S(r, "status") == "ready";
            var busy = working.ContainsKey(selected);
            // buttons stay clickable - if something can't be done right now, the click explains why
            foreach (var b in new[] { bStart, bStop, bRestart, bConnect }) b.Enabled = !busy && ready;
            bStart.Base = s == "running" ? T.Gray : T.Green; bStop.Base = s == "running" ? T.Red : T.Gray; bRestart.Base = s == "running" ? T.Card : T.Gray;
            foreach (var b in new[] { bStart, bStop, bRestart }) b.Invalidate();
            agentNote.Text = App.HasAgent(r) ? "" : "⚠️ המחשב הזה נוצר בגרסה ישנה: שינוי נפח, סיסמה והרשאות לא זמין בו. מחשבים חדשים תומכים בכל ההגדרות.";
            Tuple<double, DateTime> u; var limit = Store.I(r, "diskGB");
            double real; var hasReal = driveSize.TryGetValue(selected, out real);
            var mismatch = hasReal && Math.Abs(real - limit) > 1 ? "   ⚠️ הכונן בפועל: " + real + " GB – לחץ \"שמור\" בנפח כדי להתאים" : "";
            if (usage.TryGetValue(selected, out u)) { usageBar.Value = u.Item1; usageBar.Max = hasReal ? real : limit; usageLbl.Text = "כונן C:  בשימוש " + u.Item1.ToString("0.0") + " GB מתוך " + (hasReal ? real : limit) + " GB (כולל Windows)   · נבדק " + u.Item2.ToString("HH:mm") + mismatch; }
            else { usageBar.Value = 0; usageBar.Max = limit; usageLbl.Text = App.HasAgent(r) ? "כונן C: " + limit + " GB (כולל Windows) · לחץ \"בדוק\" כדי לראות כמה בשימוש" : "כונן C: " + limit + " GB"; }
            usageBar.Invalidate();
        }

        // ---------- guest operations ----------
        void Busy(string what, Func<string> work, Action<string> done)
        {
            Cursor = Cursors.WaitCursor; var old = Text; Text = "⏳ " + what + "…";
            Task.Run(work).ContinueWith(t => BeginInvoke((Action)(() =>
            {
                Cursor = Cursors.Default; Text = old;
                if (t.IsFaulted) { working.Clear(); App.Error(t.Exception.InnerException ?? t.Exception); Reload(); return; }
                done(t.Result);
            })));
        }
        Dictionary<string, object> NeedAgent()
        {
            var r = Store.Get(selected); if (r == null) return null;
            if (!App.HasAgent(r)) { App.Say("המחשב הזה נוצר בגרסה ישנה של התוכנה, ולכן אי אפשר לשנות בו את זה מכאן.\nאפשר ליצור אותו מחדש (מחשב חדש) – אז כל ההגדרות יעבדו."); return null; }
            string s; states.TryGetValue(selected, out s);
            if (s != "running") { App.Say("המחשב צריך להיות דלוק כדי לשנות את זה. הפעל אותו ונסה שוב."); return null; }
            return r;
        }

        void FetchUsage(string name, bool userAsked)
        {
            var r = Store.Get(name); if (r == null) return;
            if (!App.HasAgent(r)) { if (userAsked) App.Say("המחשב הזה נוצר בגרסה ישנה, ולכן אי אפשר לבדוק בו כמה נפח בשימוש."); return; }
            string s; states.TryGetValue(name, out s);
            if (s != "running") { if (userAsked) App.Say("המחשב כבוי – הדלק אותו כדי לבדוק כמה נפח בשימוש."); return; }
            Tuple<double, DateTime> u; if (!userAsked && usage.TryGetValue(name, out u) && (DateTime.Now - u.Item2).TotalMinutes < 5) return;
            var full = App.FullUser(r);
            if (userAsked && selected == name) usageLbl.Text = "⏳ בודק…";
            Task.Run(() => App.GuestPs(r, App.UsageScript, 60000)).ContinueWith(t =>
            {
                if (!IsHandleCreated) return;
                var outp = t.IsFaulted ? t.Exception.InnerException.Message : t.Result;
                var pu = t.IsFaulted ? null : App.ParseUsage(outp);
                double gb = pu == null ? -1 : pu.Item1;
                if (pu != null) driveSize[name] = pu.Item2;
                BeginInvoke((Action)(() =>
                {
                    if (gb >= 0) { usage[name] = Tuple.Create(gb, DateTime.Now); if (selected == name) ShowSelected(); return; }
                    App.Log("usage failed for " + name + ": " + outp);
                    if (selected == name) ShowSelected();
                    if (userAsked) App.Say("לא הצלחתי לבדוק:\n" + App.GuestProblem(outp));
                }));
            });
        }
        static double ParseUsage(string output, string fullUser, string user)
        {
            // blocks separated by blank lines; find the one for our user, read "Quota Used"
            foreach (var block in Regex.Split(output.Replace("\r", ""), "\n\\s*\n"))
            {
                if (block.IndexOf("\\" + user, StringComparison.OrdinalIgnoreCase) < 0) continue;
                var m = Regex.Match(block, @"Quota Used\s*[:=]\s*([\d,\.]+)", RegexOptions.IgnoreCase);
                
                long bytes; if (m.Success && long.TryParse(m.Groups[1].Value.Replace(",", "").Replace(".", ""), out bytes)) return Math.Round(bytes / 1073741824.0, 2);
            }
            return -1;
        }

        void SaveGb()
        {
            var r = NeedAgent(); if (r == null) return;
            var gb = (int)gbNum.Value; var name = selected;
            Busy("משנה את גודל הכונן של " + name + " (עד כמה דקות)", () => App.GuestPs(r, App.ResizeScript(gb), 900000), o =>
            {
                App.Log("disk " + name + " " + gb + "GB: " + o.Trim());
                var msg = App.ResizeMessage(name, gb, o);
                if (msg.StartsWith("✅")) { Store.Set(name, "diskGB", gb); usage.Remove(name); FetchUsage(name, false); }
                App.Say(msg, msg.StartsWith("✅") ? MessageBoxIcon.Information : MessageBoxIcon.Warning); ShowSelected();
            });
        }
        void SavePassword()
        {
            var r = NeedAgent(); if (r == null) return;
            var pw = pwBox.Text.Trim(); var bad = App.CheckPassword(pw, Store.S(r, "user")); if (bad != null) { App.Say(bad); return; }
            Busy("משנה סיסמה", () =>
            {
                var res = App.Guest(r, "net user " + Store.S(r, "user") + " " + pw);
                if (res.Contains("successfully")) App.Log("login check " + Store.S(r, "name") + ":\r\n" + App.GuestPs(r, App.RepairLoginScript(Store.S(r, "user")), 60000).Trim());
                return res;
            }, o =>
            {
                App.Log("password " + selected + ": " + o.Trim());
                if (!o.Contains("successfully") && !o.Contains("בהצלחה")) { App.Say("השינוי נכשל:\n" + App.GuestProblem(o), MessageBoxIcon.Warning); return; }
                Store.Set(selected, "password", pw); pwBox.Text = ""; Clipboard.SetText(pw);
                App.Say("✅ הסיסמה של " + selected + " שונתה (והועתקה ללוח)."); ShowSelected();
            });
        }
        void SaveAdmin()
        {
            var r = NeedAgent(); if (r == null) return;
            var on = adminChk.Checked;
            Busy("משנה הרשאות", () => App.Guest(r, "net localgroup Administrators " + Store.S(r, "user") + (on ? " /add" : " /delete")), o =>
            {
                App.Log("admin " + selected + " " + on + ": " + o.Trim());
                if (!App.GuestOk(o)) { App.Say("השינוי נכשל:\n" + App.GuestProblem(o), MessageBoxIcon.Warning); return; }
                Store.Set(selected, "admin", on); App.Say(on ? "✅ " + selected + " קיבל הרשאות מנהל." : "✅ ההרשאות של " + selected + " הוסרו."); ShowSelected();
            });
        }
        void SaveRam()
        {
            var r = Store.Get(selected); if (r == null) return; var gb = (int)ramNum.Value;
            string s; states.TryGetValue(selected, out s); var name = selected;
            if (s == "running" && !App.Ask("כדי לשנות זיכרון צריך להפעיל את " + name + " מחדש. מי שמחובר יתנתק לדקה.\nלהמשיך?")) return;
            Busy("משנה זיכרון", () =>
            {
                if (s == "running") { App.VBox("controlvm \"PC-" + name + "\" acpipowerbutton"); for (int i = 0; i < 60 && App.VmState(name) == "running"; i++) Thread.Sleep(2000); if (App.VmState(name) == "running") App.VBox("controlvm \"PC-" + name + "\" poweroff"); Thread.Sleep(2000); }
                var o = App.VBox("modifyvm \"PC-" + name + "\" --memory " + (gb * 1024));
                if (s == "running") App.VBox("startvm \"PC-" + name + "\" --type headless");
                return o;
            }, o => { App.Log("ram " + name + ": " + o.Trim()); Store.Set(name, "ramGB", gb); App.Say("✅ הזיכרון של " + name + " עודכן ל-" + gb + " GB."); Reload(); });
        }

        // ---------- actions ----------
        void NewComputer()
        {
            using (var f = new NewVmForm())
            {
                if (f.ShowDialog(this) != DialogResult.OK) return;
                var used = new HashSet<int>(Store.All().Select(r => Store.I(r, "port")));
                int port = 3390; while (used.Contains(port)) port++;
                Store.Add(new Dictionary<string, object> {
                    { "name", f.VmName }, { "user", f.User }, { "password", f.Password }, { "diskGB", f.DiskGB }, { "ramGB", f.RamGB },
                    { "port", port }, { "admin", f.Admin }, { "status", "creating" }, { "step", "מתחיל" }, { "created", DateTime.Now.ToString("s") } });
                var pf = Path.Combine(Path.GetTempPath(), "spc-" + f.VmName + ".json");
                File.WriteAllText(pf, new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "password", f.Password } }), new UTF8Encoding(true));
                var args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(App.ScriptDir, "create-vm.ps1") + "\" -Name " + f.VmName +
                           " -User " + f.User + " -PasswordFile \"" + pf + "\" -DiskGB " + f.DiskGB + " -RamGB " + f.RamGB + " -Port " + port + (f.Admin ? " -Admin" : "");
                var p = new Process { StartInfo = new ProcessStartInfo("powershell.exe", args) { UseShellExecute = false, CreateNoWindow = true }, EnableRaisingEvents = true };
                var name = f.VmName;
                p.Exited += (s, e) => { var r = Store.Get(name); if (r != null && Store.S(r, "status") == "creating") { Store.Set(name, "status", "failed"); Store.Set(name, "step", "התהליך נעצר (ראה יומן הקמה)"); } };
                p.Start();
                App.Log("Creating " + name + " port " + port);
                selected = name; Reload();
                App.Say("המחשב " + name + " בהקמה ⏳\nזה לוקח בערך 8–15 דקות, ואפשר להמשיך לעבוד בינתיים.\n\nכשהנקודה תהיה ירוקה – לחץ \"העתק הכל\" ושלח ללקוח.");
            }
        }

        void CopyText(string s) { if (!string.IsNullOrEmpty(s)) { Clipboard.SetText(s); Text = "✅ הועתק"; var t = new System.Windows.Forms.Timer { Interval = 1200 }; t.Tick += (a, b) => { t.Stop(); Text = App.Title + "  ·  גרסה " + App.Version; }; t.Start(); } }
        void CopyAll()
        {
            var r = Store.Get(selected); if (r == null) return;
            if (Store.S(r, "status") != "ready") { App.Say("המחשב עוד לא מוכן."); return; }
            var txt = "חיבור לשולחן עבודה מרוחק (mstsc)\r\nכתובת: " + publicIp + ":" + Store.S(r, "port") + "\r\nשם משתמש: " + App.FullUser(r) + "\r\nסיסמה: " + Store.S(r, "password") +
                      "\r\n\r\nאתר לניהול המחשב שלך: " + SiteUrl() + "\r\n(נכנסים עם אותו שם משתמש וסיסמה)";
            Clipboard.SetText(txt); App.Say(txt + "\n\n✅ הועתק – הדבק (Ctrl+V) ושלח ללקוח.");
        }
        void ConnectMyself()
        {
            var r = Store.Get(selected); if (r == null) return;
            string cur; states.TryGetValue(selected, out cur);
            if (cur != "running") { if (App.Ask(selected + " כבוי. להדליק אותו עכשיו?\n(אחרי שיידלק, חכה דקה ולחץ שוב \"התחבר\")")) Power("start"); return; }
            App.Run("cmdkey.exe", "/delete:TERMSRV/127.0.0.2");
            var dir = Path.Combine(App.HostDir, "vms", selected); Directory.CreateDirectory(dir);
            var rdp = Path.Combine(dir, selected + ".rdp");
            File.WriteAllText(rdp, "full address:s:127.0.0.2:" + Store.S(r, "port") + "\r\nusername:s:" + App.FullUser(r) + "\r\nprompt for credentials:i:1\r\nauthentication level:i:0\r\nscreen mode id:i:2\r\ndisable wallpaper:i:0\r\nconnection type:i:6\r\nnetworkautodetect:i:0\r\n", Encoding.ASCII);
            Clipboard.SetText(Store.S(r, "password"));
            Process.Start("mstsc.exe", "\"" + rdp + "\"");
            App.Say("נפתח חלון התחברות.\nשם המשתמש: " + App.FullUser(r) + "\nהסיסמה הועתקה – הדבק (Ctrl+V) ולחץ אישור.");
        }
        void Power(string what)
        {
            var name = selected; if (name == null) return;
            var r = Store.Get(name); if (r == null) return;
            string cur; states.TryGetValue(name, out cur);
            if (what == "stop" && cur != "running") { App.Say(name + " כבר כבוי."); return; }
            if (what == "start" && cur == "running") { App.Say(name + " כבר דלוק. לחץ \"התחבר\" כדי להיכנס אליו."); return; }
            if (what == "restart" && cur != "running") what = "start";
            if (what != "start" && !App.Ask((what == "stop" ? "לכבות את " : "להפעיל מחדש את ") + name + "?\nמי שמחובר אליו יתנתק.")) return;
            // show it right away in the list, so it is clear the click worked
            working[name] = what == "stop" ? "stopping" : "starting"; states[name] = working[name]; ShowSelected(); UpdateTile(name);
            Busy(what == "start" ? "מדליק את " + name : what == "stop" ? "מכבה את " + name + " (עד דקה וחצי)" : "מפעיל מחדש את " + name, () =>
            {
                if (what == "start") return App.StartVm(name);
                if (what == "stop") return App.StopVm(r);
                return App.RestartVm(r);
            }, o => { working.Remove(name); App.Log(what + " " + name + ": " + o.Replace("\n", " ")); Reload(); App.Say(o, o.StartsWith("❌") ? MessageBoxIcon.Error : MessageBoxIcon.Information); });
        }
        void UpdateTile(string name)
        {
            VmTile t; var r = Store.Get(name); if (r == null || !tiles.TryGetValue(name, out t)) return;
            string s; states.TryGetValue(name, out s);
            t.StateText = StateText(r, s) + " · " + Store.S(r, "user"); t.Dot = StateColor(r, s); t.Invalidate();
        }
        void Screenshot()
        {
            var name = selected; if (name == null) return;
            var png = Path.Combine(App.HostDir, "vms", name, "screen.png");
            try { File.Delete(png); } catch { }
            var o = App.VBox("controlvm \"PC-" + name + "\" screenshotpng \"" + png + "\"");
            if (!File.Exists(png)) { App.Say("לא הצלחתי לצלם את המסך (המחשב כבוי?)."); return; }
            var f = new Form { Text = "המסך של " + name, Size = new Size(1100, 850), StartPosition = FormStartPosition.CenterScreen, BackColor = T.Bg };
            f.Controls.Add(new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Image = Image.FromStream(new MemoryStream(File.ReadAllBytes(png))) });
            f.Show(this);
        }
        void OpenLog()
        {
            var l = Path.Combine(App.HostDir, "vms", selected ?? "", "create.log");
            if (File.Exists(l)) Process.Start("notepad.exe", "\"" + l + "\""); else App.Say("אין יומן עדיין.");
        }
        void Delete()
        {
            var n = selected; if (n == null) return;
            if (!App.Ask("למחוק את המחשב " + n + " לגמרי?\nכל הקבצים שבו יימחקו ולא יהיה אפשר לשחזר.")) return;
            var port = Store.I(Store.Get(n), "port");
            Busy("מוחק", () =>
            {
                App.VBox("controlvm \"PC-" + n + "\" poweroff"); Thread.Sleep(3000);
                App.VBox("unregistervm \"PC-" + n + "\" --delete");
                App.Run("netsh.exe", "advfirewall firewall delete rule name=\"SharedPC PC-" + n + "\"");
                try { Directory.Delete(Path.Combine(App.HostDir, "vms", n), true); } catch (Exception ex) { App.Log("delete dir: " + ex.Message); }
                if (port > 0) Router.Remove(lanIp, port);
                Store.Remove(n); return "";
            }, o => { selected = null; Reload(); App.Say(n + " נמחק."); });
        }
    }

    // ================= new computer =================
    class NewVmForm : Form
    {
        TextBox name = T.Box(380), user = T.Box(380), pass = T.Box(320);
        NumericUpDown disk = T.Num(App.MinDiskGB, 2000, 60, 140), ram = T.Num(2, 64, 4, 140);
        CheckBox admin = new CheckBox { Text = "הרשאות מנהל (יוכל להתקין תוכנות)", AutoSize = true, ForeColor = T.Text, Font = T.F(10.5f), Margin = new Padding(3, 14, 3, 3) };
        Label capacity = T.Lbl("", 9.5f);
        public string VmName { get { return name.Text.Trim().ToLower(); } }
        public string User { get { return user.Text.Trim(); } }
        public string Password { get { return pass.Text.Trim(); } }
        public int DiskGB { get { return (int)disk.Value; } }
        public int RamGB { get { return (int)ram.Value; } }
        public bool Admin { get { return admin.Checked; } }

        public NewVmForm()
        {
            T.Dark(this);
            Text = "מחשב חדש"; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink; Padding = new Padding(26);
            var p = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, BackColor = T.Bg };
            Action<string> L = s => { var l = T.Lbl(s, 10); l.Margin = new Padding(3, 12, 3, 4); p.Controls.Add(l); };
            var h = T.Lbl("＋  מחשב חדש", 18, true, T.Text); p.Controls.Add(h);
            p.Controls.Add(T.Lbl("מחשב Windows נפרד ללקוח אחד", 10, false, T.Muted));
            L("שם המחשב (באנגלית, למשל dani)"); p.Controls.Add(name);
            L("שם משתמש להתחברות (באנגלית)"); p.Controls.Add(user);
            L("סיסמה");
            var pw = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0), BackColor = T.Bg };
            pass.Text = App.RandomPassword();
            var gen = new Btn("🎲", T.Card, 50, 32); gen.Click += (s, e) => pass.Text = App.RandomPassword();
            pw.Controls.Add(pass); pw.Controls.Add(gen); p.Controls.Add(pw);
            var nums = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 10, 0, 0), BackColor = T.Bg };
            var c1 = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, BackColor = T.Bg, Margin = new Padding(0, 0, 30, 0) };
            c1.Controls.Add(T.Lbl("כונן C: (GB, כולל Windows)", 10)); c1.Controls.Add(disk);
            var c2 = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, BackColor = T.Bg };
            c2.Controls.Add(T.Lbl("זיכרון RAM (GB)", 10)); c2.Controls.Add(ram);
            nums.Controls.Add(c1); nums.Controls.Add(c2); p.Controls.Add(nums);
            p.Controls.Add(admin);
            capacity.MaximumSize = new Size(390, 0); capacity.Margin = new Padding(3, 12, 3, 3); p.Controls.Add(capacity);
            var buttons = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 18, 0, 0), BackColor = T.Bg };
            var ok = new Btn("צור מחשב", T.Accent, 200, 46); var cancel = new Btn("ביטול", T.Card, 120, 46);
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

        int PlannedRam() { return Store.All().Where(r => Store.S(r, "status") != "failed").Sum(r => Store.I(r, "ramGB")) + RamGB; }
        void UpdateCapacity()
        {
            int planned = PlannedRam(); double total = App.TotalRamGB(), free = App.FreeDiskGB();
            capacity.Text = "💾 פנוי בדיסק: " + free + " GB      🧠 זיכרון של כל המחשבים יחד: " + planned + " / " + total + " GB";
            capacity.ForeColor = (planned > total - 6 || DiskGB + 25 > free) ? T.Yellow : T.Muted;
        }
        bool Valid()
        {
            if (!Regex.IsMatch(VmName, "^[a-z0-9-]{2,12}$")) { App.Say("שם המחשב: באנגלית, 2–12 תווים (אותיות, ספרות, מקף)."); return false; }
            if (Store.Get(VmName) != null) { App.Say("כבר יש מחשב בשם הזה."); return false; }
            if (!Regex.IsMatch(User, "^[A-Za-z0-9._-]{3,20}$")) { App.Say("שם משתמש: באנגלית, 3–20 תווים."); return false; }
            var bad = App.CheckPassword(Password, User); if (bad != null) { App.Say(bad); return false; }
            if (DiskGB + 25 > App.FreeDiskGB()) { App.Say("אין מספיק מקום פנוי בדיסק."); return false; }
            int planned = PlannedRam();
            if (planned > App.TotalRamGB() - 6 && !App.Ask("כל המחשבים יחד צריכים " + planned + " GB זיכרון, ובמחשב יש " + App.TotalRamGB() + " GB.\nאפשר ליצור, אבל לא כולם יוכלו לפעול בו-זמנית.\n\nלהמשיך?")) return false;
            return true;
        }
    }
}
