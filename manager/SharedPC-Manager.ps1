# SharedPC Manager - only on your computer.
# Create virtual computers (one person each), choose how many GB each gets,
# and give people an address + username + password for Remote Desktop.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'common.ps1')
$Title   = 'ניהול מחשבים וירטואליים'
$HostDir = 'C:\SharedPC-Host'

# ---------- start all ready computers whenever you log in ----------
$startAll = Join-Path $HostDir 'start-all.ps1'
@'
$vbm = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
$f = 'C:\SharedPC-Host\vms.json'
$names = @('SharedPC')
if (Test-Path $f) { $names += @((Get-Content $f -Raw | ConvertFrom-Json) | Where-Object { $_.status -eq 'ready' } | ForEach-Object { "PC-$($_.name)" }) }
$running = (& $vbm list runningvms) -join "`n"
foreach ($n in $names) { if ($running -notmatch "`"$n`"") { & $vbm startvm $n --type headless 2>&1 | Out-Null } }
'@ | Set-Content $startAll -Encoding UTF8
$me = "$env:USERDOMAIN\$env:USERNAME"
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startAll`""
$trg = New-ScheduledTaskTrigger -AtLogOn -User $me; $trg.Delay = 'PT30S'
$prn = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'SharedPC - start VMs at login' -Action $act -Trigger $trg -Principal $prn -Force | Out-Null
Unregister-ScheduledTask -TaskName 'SharedPC - start VM at login' -Confirm:$false -ErrorAction SilentlyContinue   # replaced by the task above

# ---------- addresses ----------
$script:PublicIp = try { (Invoke-WebRequest 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 8).Content.Trim() } catch { '?' }
$script:LanIp = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress

# ---------- look ----------
$C = @{
    bg = [Drawing.Color]::FromArgb(15, 23, 42); card = [Drawing.Color]::FromArgb(30, 41, 59)
    fg = [Drawing.Color]::FromArgb(226, 232, 240); muted = [Drawing.Color]::FromArgb(148, 163, 184)
    blue = [Drawing.Color]::FromArgb(37, 99, 235); red = [Drawing.Color]::FromArgb(127, 29, 29)
}
function Say($text) { [Windows.Forms.MessageBox]::Show($text, $Title, 'OK', 'Information', 'Button1', [Windows.Forms.MessageBoxOptions]::RtlReading -bor [Windows.Forms.MessageBoxOptions]::RightAlign) | Out-Null }
function Ask($text) { [Windows.Forms.MessageBox]::Show($text, $Title, 'YesNo', 'Question', 'Button2', [Windows.Forms.MessageBoxOptions]::RtlReading -bor [Windows.Forms.MessageBoxOptions]::RightAlign) -eq 'Yes' }
function Input($prompt, $default = '') { [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $Title, $default) }
function Add-Button($form, $text, $x, $y, $w, $h = 40, $color = $null) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, $h)
    $b.BackColor = $(if ($color) { $color } else { $C.card }); $b.ForeColor = [Drawing.Color]::White
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $form.Controls.Add($b); $b
}

$form = New-Object Windows.Forms.Form
$form.Text = $Title; $form.Size = New-Object Drawing.Size(900, 600); $form.StartPosition = 'CenterScreen'
$form.BackColor = $C.bg; $form.ForeColor = $C.fg; $form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false

$hdr = New-Object Windows.Forms.Label
$hdr.Text = '🖥️ ' + $Title; $hdr.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$hdr.Location = New-Object Drawing.Point(20, 12); $hdr.Size = New-Object Drawing.Size(840, 36)
$form.Controls.Add($hdr)
$info = New-Object Windows.Forms.Label
$info.Location = New-Object Drawing.Point(20, 50); $info.Size = New-Object Drawing.Size(840, 40); $info.ForeColor = $C.muted
$form.Controls.Add($info)

$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(20, 95); $grid.Size = New-Object Drawing.Size(845, 330)
$grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
$grid.RowHeadersVisible = $false; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = $C.card
$grid.DefaultCellStyle.BackColor = $C.card; $grid.DefaultCellStyle.ForeColor = $C.fg; $grid.DefaultCellStyle.SelectionBackColor = $C.blue
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = $C.bg; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $C.muted
foreach ($col in 'שם', 'מצב', 'שם משתמש', 'נפח לקבצים (GB)', 'זיכרון (GB)', 'כתובת לחיבור') { [void]$grid.Columns.Add($col, $col) }
$form.Controls.Add($grid)

function Load-Vms {
    $sel = if ($grid.SelectedRows.Count) { [string]$grid.SelectedRows[0].Cells[0].Value } else { $null }
    $grid.Rows.Clear()
    $ramUsed = 0
    foreach ($r in @(Get-VmRecords)) {
        $state = Get-VmState "PC-$($r.name)"
        $txt = switch ($r.status) {
            'creating' { "⏳ בהקמה: $($r.step)" }
            'failed'   { "❌ נכשל: $($r.step)" }
            default    { if ($state -eq 'running') { '🟢 פועל' } elseif ($state -eq 'missing') { '⚠️ לא נמצא' } else { '⚪ כבוי' } }
        }
        if ($state -eq 'running') { $ramUsed += [int]$r.ramGB }
        $i = $grid.Rows.Add($r.name, $txt, $r.user, $r.diskGB, $r.ramGB, "$($script:PublicIp):$($r.port)")
        if ($r.name -eq $sel) { $grid.Rows[$i].Selected = $true }
    }
    $totalRam = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $free = [math]::Round((Get-PSDrive C).Free / 1GB)
    $info.Text = "IP ציבורי: $($script:PublicIp)   ·   IP ברשת הביתית: $($script:LanIp)   ·   פנוי בכונן C: $free GB   ·   זיכרון בשימוש של מחשבים פועלים: $ramUsed מתוך $totalRam GB`n" +
                 'כדי שיתחברו מחוץ לבית: בראוטר מעבירים כל פורט (המספר אחרי ":") למחשב הזה, ' + $script:LanIp + '.'
}
function Selected { if ($grid.SelectedRows.Count) { [string]$grid.SelectedRows[0].Cells[0].Value } else { Say 'בחר מחשב מהרשימה.'; $null } }
function Rec($name) { Get-VmRecords | Where-Object { $_.name -eq $name } | Select-Object -First 1 }
function Details($r) { "כתובת (חיבור לשולחן עבודה מרוחק): $($script:PublicIp):$($r.port)`r`nשם משתמש: $($r.user)`r`nסיסמה: $($r.password)" }

# ---------- buttons ----------
$bNew   = Add-Button $form '➕ מחשב חדש' 20 440 150 44 $C.blue
$bInfo  = Add-Button $form '📋 העתק פרטי חיבור' 180 440 160 44
$bStart = Add-Button $form '▶ הפעלה' 350 440 110 44
$bStop  = Add-Button $form '⏹ כיבוי' 470 440 110 44
$bLog   = Add-Button $form '📄 יומן הקמה' 590 440 130 44
$bDel   = Add-Button $form '🗑️ מחיקה' 730 440 135 44 $C.red
$bRef   = Add-Button $form 'רענון' 20 495 100 32
$note = New-Object Windows.Forms.Label
$note.Text = 'כל מחשב = אדם אחד. הנפח שבוחרים הוא לקבצים של האדם, Windows עצמו לא נספר. המחשבים עולים לבד כשאתה מתחבר ל-Windows.'
$note.Location = New-Object Drawing.Point(130, 500); $note.Size = New-Object Drawing.Size(735, 40); $note.ForeColor = $C.muted
$form.Controls.Add($note)

$bNew.Add_Click({
    $name = (Input 'שם למחשב (באנגלית, למשל dani):').Trim().ToLower(); if (-not $name) { return }
    if ($name -notmatch '^[a-z0-9-]{2,12}$') { Say 'שם באנגלית, 2–12 תווים (אותיות, ספרות, מקף).'; return }
    if (Rec $name) { Say 'כבר יש מחשב בשם הזה.'; return }
    $user = (Input 'שם משתמש להתחברות (באנגלית):' $name).Trim(); if (-not $user) { return }
    if ($user -notmatch '^[A-Za-z0-9._-]{3,20}$') { Say 'שם משתמש באנגלית, 3–20 תווים.'; return }
    $pw = Input "סיסמה ל-${user} (הצעה אקראית, אפשר לשנות):" (New-RandomPassword); if (-not $pw) { return }
    if ($pw.Length -lt 8 -or $pw -cnotmatch '[A-Z]' -or $pw -cnotmatch '[a-z]' -or $pw -notmatch '\d') { Say 'סיסמה: 8 תווים לפחות, עם אות גדולה, אות קטנה וספרה.'; return }
    $gb = Input 'כמה GB לקבצים? (Windows עצמו לא נספר)' '50'; if ($gb -notmatch '^\d+$' -or [int]$gb -lt 5) { Say 'מספר שלם, לפחות 5.'; return }
    $ram = Input 'כמה GB זיכרון (RAM)? 4 מספיק לרוב' '4'; if ($ram -notmatch '^\d+$' -or [int]$ram -lt 2) { Say 'מספר שלם, לפחות 2.'; return }
    $adm = Ask "לתת ל-${user} הרשאות מנהל במחשב שלו? (יוכל להתקין תוכנות)"
    # capacity check: memory and disk of this computer
    $totalRam = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $planned  = (@(Get-VmRecords | Where-Object { $_.status -ne 'failed' }) | Measure-Object -Property ramGB -Sum).Sum + [int]$ram
    $freeDisk = [math]::Round((Get-PSDrive C).Free / 1GB)
    $needDisk = [int]$gb + 25
    if ($needDisk -gt $freeDisk) { Say "אין מספיק מקום בכונן C: צריך עד $needDisk GB ויש $freeDisk GB."; return }
    if ($planned -gt ($totalRam - 6)) {
        if (-not (Ask "שים לב: כל המחשבים יחד צריכים $planned GB זיכרון, ובמחשב שלך יש $totalRam GB (וגם Windows שלך צריך בערך 6GB).`nאפשר ליצור, אבל לא כולם יוכלו לפעול בו-זמנית. מחשבים שלא נכנסים פשוט לא יעלו עד שתכבה אחרים.`n`nלהמשיך?")) { return }
    }

    $used = @(Get-VmRecords | ForEach-Object { [int]$_.port })
    $port = 3390; while ($port -in $used) { $port++ }
    Add-VmRecord ([pscustomobject]@{ name = $name; user = $user; password = $pw; diskGB = [int]$gb; ramGB = [int]$ram; port = $port; admin = $adm; status = 'creating'; step = 'מתחיל'; created = (Get-Date).ToString('s') })

    $pf = Join-Path $env:TEMP "spc-$name.json"
    @{ password = $pw } | ConvertTo-Json | Set-Content $pf -Encoding UTF8
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'create-vm.ps1')`" -Name $name -User $user -PasswordFile `"$pf`" -DiskGB $gb -RamGB $ram -Port $port"
    if ($adm) { $argList += ' -Admin' }
    Start-Process powershell.exe -ArgumentList $argList -WindowStyle Minimized
    Load-Vms
    Say "המחשב $name בהקמה. זה לוקח בערך 10–15 דקות, ואפשר להמשיך לעבוד בינתיים.`n`nכשהמצב יהיה 🟢 פועל, לחץ 'העתק פרטי חיבור' ושלח לו."
})
$bInfo.Add_Click({ $n = Selected; if (-not $n) { return }; $r = Rec $n
    if ($r.status -ne 'ready') { Say 'המחשב עוד לא מוכן.'; return }
    [Windows.Forms.Clipboard]::SetText((Details $r))
    Say ((Details $r) + "`n`n✅ הועתק. הדבק (Ctrl+V) ושלח.") })
$bStart.Add_Click({ $n = Selected; if (-not $n) { return }
    try { VBox startvm "PC-$n" --type headless | Out-Null } catch { Say $_.Exception.Message }; Load-Vms })
$bStop.Add_Click({ $n = Selected; if (-not $n) { return }
    if (-not (Ask "לכבות את $n? מי שמחובר אליו יתנתק.")) { return }
    try { VBox controlvm "PC-$n" acpipowerbutton | Out-Null } catch { Say $_.Exception.Message }
    Start-Sleep -Seconds 3; Load-Vms })
$bLog.Add_Click({ $n = Selected; if (-not $n) { return }
    $l = Join-Path $HostDir "vms\$n\create.log"; if (Test-Path $l) { Start-Process notepad.exe $l } else { Say 'אין יומן.' } })
$bDel.Add_Click({ $n = Selected; if (-not $n) { return }
    if (-not (Ask "למחוק את המחשב $n לגמרי?`nכל הקבצים שבו יימחקו ולא יהיה אפשר לשחזר.")) { return }
    $ErrorActionPreference = 'Continue'
    & $script:VBM controlvm "PC-$n" poweroff 2>&1 | Out-Null; Start-Sleep -Seconds 3
    & $script:VBM unregistervm "PC-$n" --delete 2>&1 | Out-Null
    Get-NetFirewallRule -DisplayName "SharedPC PC-$n" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Remove-Item (Join-Path $HostDir "vms\$n") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-VmRecord $n
    $ErrorActionPreference = 'Stop'
    Load-Vms; Say "$n נמחק." })
$bRef.Add_Click({ Load-Vms })

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 15000; $timer.Add_Tick({ Load-Vms }); $timer.Start()
$form.Add_Shown({ Load-Vms })
[void]$form.ShowDialog()
