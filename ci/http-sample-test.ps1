# Tests the HTTP sample (examples\go-nodll\winuhid-http.exe) end to end, twice:
#   - started by an administrator in the desktop session,
#   - started as SYSTEM outside the desktop session (the way a service would run).
# A small window on the desktop records what really reaches it: clicks, double clicks,
# right clicks, wheel turns and typed text. The driver must already be installed.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

$exe      = Join-Path $KitDir 'examples\go-nodll\winuhid-http.exe'
$base     = 'http://127.0.0.1:8765'
$taskName = 'WinUHidHttpSampleTest'
$script:failed = $false

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $mark = if ($Ok) { 'PASS' } else { 'FAIL'; $script:failed = $true }
    Add-Report "- [$mark] ${Name}: $Detail"
}

function Invoke-Api {
    # Returns the JSON answer with the HTTP status code added as .status (0 = no answer at all).
    param([string]$Path)
    try {
        $response = Invoke-WebRequest -Uri "$base$Path" -TimeoutSec 15 -SkipHttpErrorCheck -ErrorAction Stop
        $answer = $response.Content | ConvertFrom-Json
        $answer | Add-Member -NotePropertyName status -NotePropertyValue ([int]$response.StatusCode) -Force
        $answer
    } catch {
        [pscustomobject]@{ ok = $false; status = 0; error = $_.Exception.Message }
    }
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$Seconds = 10)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return [bool](& $Condition)
}

# --- what this script can observe from the desktop --------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Probe
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    public static string Cursor() { POINT p; return GetCursorPos(out p) ? p.X + "," + p.Y : "none"; }
    public static bool IsDown(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
    public static string Screen() { return GetSystemMetrics(0) + "x" + GetSystemMetrics(1); }
    [DllImport("user32.dll")] public static extern bool BlockInput(bool block);

    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window, System.Text.StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, System.Text.StringBuilder text, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);

    static string Describe(IntPtr window)
    {
        if (window == IntPtr.Zero) return "(none)";
        var title = new System.Text.StringBuilder(200); var cls = new System.Text.StringBuilder(200); uint pid;
        GetWindowTextW(window, title, 200); GetClassNameW(window, cls, 200); GetWindowThreadProcessId(window, out pid);
        return "'" + title + "' [" + cls + "] pid " + pid;
    }
    // The top-level window that would receive a click at this point.
    public static string WindowAt(int x, int y)
    {
        POINT p; p.X = x; p.Y = y;
        return Describe(GetAncestor(WindowFromPoint(p), 2));
    }
    public static string Foreground() { return Describe(GetForegroundWindow()); }
    public static void BringToFront(IntPtr window)
    {
        SetWindowPos(window, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040); // topmost; keep size and place; show
        SetForegroundWindow(window);
    }
}
'@

function Get-InputDevices {
    try {
        @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.Class -in 'Mouse', 'Keyboard', 'HIDClass' } |
            ForEach-Object { $_.InstanceId })
    } catch { @() }
}

# --- a window on the desktop that records what arrives ---------------------------------------
$ui = [hashtable]::Synchronized(@{ Ready = $false; Close = $false; Down = 0; RightDown = 0; Double = 0; Wheel = 0; Text = ''; Events = ''; Errors = '' })
$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'STA'
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('ui', $ui)
$window = [powershell]::Create()
$window.Runspace = $runspace
[void]$window.AddScript({
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WinUHid HTTP test window'
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(60, 60)
    $form.Size = New-Object System.Drawing.Size(440, 320)
    $form.TopMost = $true

    $pad = New-Object System.Windows.Forms.Panel
    $pad.Location = New-Object System.Drawing.Point(20, 20)
    $pad.Size = New-Object System.Drawing.Size(380, 140)
    $pad.BackColor = [System.Drawing.Color]::LightSteelBlue

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(20, 190)
    $box.Size = New-Object System.Drawing.Size(380, 30)

    # Handlers use $_ (the event's arguments) and never let an error escape into the window's message loop.
    $pad.Add_MouseDown({
        try {
            $ui.Events += "down:$($_.Button) "
            if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $ui.Down++ }
            if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $ui.RightDown++ }
        } catch { $ui.Errors += "MouseDown: $($_.Exception.Message); " }
    })
    $pad.Add_MouseDoubleClick({ try { $ui.Events += 'double '; $ui.Double++ } catch { $ui.Errors += "DoubleClick: $($_.Exception.Message); " } })
    $wheel = { try { $ui.Events += "wheel:$($_.Delta) "; $ui.Wheel += $_.Delta } catch { $ui.Errors += "Wheel: $($_.Exception.Message); " } }
    $form.Add_MouseWheel($wheel)
    $pad.Add_MouseWheel($wheel)
    $box.Add_MouseWheel($wheel)
    $box.Add_TextChanged({ try { $ui.Text = $box.Text } catch { $ui.Errors += "TextChanged: $($_.Exception.Message); " } })

    $form.Controls.Add($pad)
    $form.Controls.Add($box)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({ if ($ui.Close) { $timer.Stop(); $form.Close() } })
    $timer.Start()

    $form.Add_Shown({
        $p = $pad.PointToScreen((New-Object System.Drawing.Point(190, 70)))
        $b = $box.PointToScreen((New-Object System.Drawing.Point(190, 10)))
        $ui.PadX = $p.X; $ui.PadY = $p.Y; $ui.BoxX = $b.X; $ui.BoxY = $b.Y
        $ui.Handle = $form.Handle
        $ui.Bounds = "$($form.Bounds)"
        $form.Activate()
        $ui.Ready = $true
    })
    [System.Windows.Forms.Application]::Run($form)
})
$windowRun = $window.BeginInvoke()

Add-Report "## HTTP sample (examples\go-nodll\winuhid-http.exe)"
if (-not (Wait-Until { $ui.Ready } 20)) {
    Add-Report "- [FAIL] the test window did not appear; nothing can be observed."
    exit 1
}
Add-Report "- test window on the desktop: click area centre ($($ui.PadX),$($ui.PadY)), text box ($($ui.BoxX),$($ui.BoxY)); screen $([Probe]::Screen())"

function Save-Desktop {
    # A picture of the desktop, to see what the test saw.
    param([string]$Name)
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save((Join-Path $LogDir $Name), [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
    } catch {
        Add-Report "- screenshot failed: $($_.Exception.Message)"
    }
}

function Show-TestWindow {
    # Puts the test window in front and says what a click at the test points would hit.
    [Probe]::BringToFront([IntPtr]$ui.Handle)
    Start-Sleep -Milliseconds 300
    Add-Report "- window $($ui.Bounds); at the click point: $([Probe]::WindowAt($ui.PadX, $ui.PadY)); at the text box: $([Probe]::WindowAt($ui.BoxX, $ui.BoxY)); in front: $([Probe]::Foreground())"
}
Show-TestWindow
Save-Desktop '64-http-desktop-before.png'

# --- the checks that are the same for both ways of starting the program ----------------------
function Test-Api {
    param([string]$Label)
    $px = $ui.PadX; $py = $ui.PadY; $bx = $ui.BoxX; $by = $ui.BoxY

    # Windows needs a moment to set up new devices: repeat the first move until it shows.
    $moved = Wait-Until { [void](Invoke-Api "/mouse/move/$px/$py"); Start-Sleep -Milliseconds 150; [Probe]::Cursor() -eq "$px,$py" } 10
    Check "$Label /mouse/move/$px/$py" $moved "pointer is at $([Probe]::Cursor())"
    Start-Sleep -Milliseconds 700

    $before = $ui.Clone()
    $r = Invoke-Api "/mouse/click/$px/$py"; Start-Sleep -Milliseconds 400
    Check "$Label /mouse/click" ($r.ok -and ($ui.Down - $before.Down) -eq 1 -and ($ui.Double - $before.Double) -eq 0) `
        "window saw $($ui.Down - $before.Down) press(es), $($ui.Double - $before.Double) double click(s) $($r.error)"
    Start-Sleep -Milliseconds 800   # so the next click is not taken as the second half of a double click

    $before = $ui.Clone()
    $r = Invoke-Api "/mouse/dblclick/$px/$py"; Start-Sleep -Milliseconds 500
    Check "$Label /mouse/dblclick" ($r.ok -and ($ui.Down - $before.Down) -eq 2 -and ($ui.Double - $before.Double) -eq 1) `
        "window saw $($ui.Down - $before.Down) press(es), $($ui.Double - $before.Double) double click(s) $($r.error)"
    Start-Sleep -Milliseconds 800

    $before = $ui.Clone()
    $r = Invoke-Api "/mouse/rclick/$px/$py"; Start-Sleep -Milliseconds 400
    Check "$Label /mouse/rclick" ($r.ok -and ($ui.RightDown - $before.RightDown) -eq 1 -and ($ui.Down - $before.Down) -eq 0) `
        "window saw $($ui.RightDown - $before.RightDown) right press(es), $($ui.Down - $before.Down) left press(es) $($r.error)"

    [void](Invoke-Api "/mouse/down/$px/$py"); Start-Sleep -Milliseconds 300
    $held = [Probe]::IsDown(0x01)
    [void](Invoke-Api "/mouse/up/$px/$py"); Start-Sleep -Milliseconds 300
    $released = -not [Probe]::IsDown(0x01)
    Check "$Label /mouse/down + /mouse/up" ($held -and $released) "left button held=$held, then released=$released"

    $before = $ui.Clone()
    $r = Invoke-Api '/mouse/scroll/-1'; Start-Sleep -Milliseconds 400
    Check "$Label /mouse/scroll/-1" ($r.ok -and ($ui.Wheel - $before.Wheel) -eq -120) "window saw wheel delta $($ui.Wheel - $before.Wheel) (one notch down is -120) $($r.error)"

    $here = [Probe]::Cursor()
    $r = Invoke-Api '/mouse/rel/40/0'; Start-Sleep -Milliseconds 300
    Check "$Label /mouse/rel/40/0" ($r.ok -and [Probe]::Cursor() -ne $here) "pointer went from $here to $([Probe]::Cursor()) $($r.error)"

    Start-Sleep -Milliseconds 700
    [void](Invoke-Api "/mouse/click/$bx/$by"); Start-Sleep -Milliseconds 400
    $r = Invoke-Api '/type/Hello%20123'; Start-Sleep -Milliseconds 500
    Check "$Label /type/Hello 123" ($r.ok -and $ui.Text -ceq 'Hello 123') "text box contains '$($ui.Text)' $($r.error)"

    [void](Invoke-Api '/key/tap/ctrl+a'); Start-Sleep -Milliseconds 200
    $r = Invoke-Api '/key/tap/delete'; Start-Sleep -Milliseconds 400
    Check "$Label /key/tap/ctrl+a then /key/tap/delete" ($r.ok -and $ui.Text -eq '') "text box contains '$($ui.Text)' $($r.error)"

    [void](Invoke-Api '/key/down/shift'); Start-Sleep -Milliseconds 300
    $held = [Probe]::IsDown(0xA0)
    [void](Invoke-Api '/key/up/shift'); Start-Sleep -Milliseconds 300
    $released = -not [Probe]::IsDown(0xA0)
    Check "$Label /key/down/shift + /key/up/shift" ($held -and $released) "Left Shift held=$held, then released=$released"

    # Error feedback. A URL that makes no sense must be refused...
    $r = Invoke-Api '/mouse/move/abc/1'
    Check "$Label nonsense URL is refused" ($r.status -eq 400) "HTTP $($r.status): $($r.error)"

    # ...and input that is sent but has no effect must be reported, promptly, not retried forever.
    # Windows is told to ignore all keyboard and mouse input for a moment to create that situation.
    [void](Invoke-Api "/mouse/move/$px/$py"); Start-Sleep -Milliseconds 300
    $here = [Probe]::Cursor()
    $blocked = [Probe]::BlockInput($true)
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Api "/mouse/click/$($px + 40)/$py"
        $watch.Stop()
        $stayed = ([Probe]::Cursor() -eq $here)
    } finally {
        [void][Probe]::BlockInput($false)
    }
    if ($blocked -and $stayed) {
        Check "$Label input without effect is reported" ($r.status -eq 403 -and $watch.ElapsedMilliseconds -lt 5000) `
            "with input blocked: HTTP $($r.status) after $($watch.ElapsedMilliseconds) ms: $($r.error)"
    } else {
        Add-Report "- [INFO] $Label input-without-effect check skipped: input could not be blocked on this machine (blocked=$blocked, pointer stayed=$stayed, HTTP $($r.status))"
    }
    Start-Sleep -Milliseconds 300

    [void](Invoke-Api "/mouse/move/$px/$py"); Start-Sleep -Milliseconds 300
    $status = Invoke-Api '/status'
    $seen = "$($status.pointer.x),$($status.pointer.y)"
    $size = "$($status.screen.width)x$($status.screen.height)"
    Check "$Label /status" ($status.ok -and $seen -eq [Probe]::Cursor() -and $size -eq [Probe]::Screen()) `
        "user=$($status.user), session=$($status.session), console session=$($status.console_session); it reports pointer $seen and screen $size ($($status.screen.how)$($status.screen_error)); the desktop says $([Probe]::Cursor()) and $([Probe]::Screen())"
    return $status
}

$baseline = Get-InputDevices

# --- A. started by an administrator in the desktop session ------------------------------------
Add-Report "### Started by an administrator in the desktop session"
$log = Join-Path $LogDir '60-http-admin.log'
$first = Start-Process -FilePath $exe -ArgumentList '-log', $log -PassThru -WindowStyle Hidden
$up = Wait-Until { (Invoke-Api '/status').ok } 15
Check 'start' $up "pid $($first.Id)"
if ($up) {
    $status = Test-Api 'admin:'
    Add-Report "- the window recorded: $($ui.Events)$(if ($ui.Errors) { " errors: $($ui.Errors)" })"
    Save-Desktop '65-http-desktop-after-admin.png'
    $withOne = @(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count
    Check 'devices created' ($withOne -gt 0) "$withOne new device entries in Windows"

    # A second copy must make the first one quit and take over, without doubling the devices.
    $second = Start-Process -FilePath $exe -ArgumentList '-log', (Join-Path $LogDir '61-http-admin-second.log') -PassThru -WindowStyle Hidden
    $tookOver = Wait-Until { $first.HasExited -and (Invoke-Api '/status').pid -eq $second.Id } 20
    Start-Sleep -Seconds 2
    $withSecond = @(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count
    Check 'second copy takes over' ($tookOver -and $withSecond -eq $withOne) `
        "first copy exited=$($first.HasExited); now answering: pid $((Invoke-Api '/status').pid) (second copy is $($second.Id)); device entries $withOne -> $withSecond"

    # /quit must remove the devices.
    [void](Invoke-Api '/quit')
    $gone = Wait-Until { $second.HasExited -and @(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count -eq 0 } 15
    Check '/quit removes the devices' $gone "process exited=$($second.HasExited); leftover device entries: $(@(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count)"

    # Killing the process must remove them too.
    $third = Start-Process -FilePath $exe -ArgumentList '-log', (Join-Path $LogDir '62-http-admin-killed.log') -PassThru -WindowStyle Hidden
    [void](Wait-Until { (Invoke-Api '/status').ok } 15)
    [void](Wait-Until { @(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count -ge $withOne } 10)
    Stop-Process -Id $third.Id -Force
    $gone = Wait-Until { @(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count -eq 0 } 15
    Check 'killing the process removes the devices' $gone "leftover device entries: $(@(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count)"
}
Get-Process -Name 'winuhid-http' -ErrorAction SilentlyContinue | Stop-Process -Force

# --- B. started as SYSTEM, outside the desktop session ----------------------------------------
Add-Report "### Started as SYSTEM outside the desktop session (as a service would run)"
$log = Join-Path $LogDir '63-http-system.log'
& schtasks.exe /create /tn $taskName /tr "$exe -log $log" /sc once /st 23:59 /ru SYSTEM /rl HIGHEST /f 2>&1 | Out-Host
& schtasks.exe /run /tn $taskName 2>&1 | Out-Host
$up = Wait-Until { (Invoke-Api '/status').ok } 20
Check 'start' $up 'started through a scheduled task that runs as SYSTEM'
$ui.Events = ''
Show-TestWindow
if ($up) {
    $status = Test-Api 'SYSTEM:'
    Add-Report "- the window recorded: $($ui.Events)$(if ($ui.Errors) { " errors: $($ui.Errors)" })"
    # S-1-5-18 is the SYSTEM account; its name shows up as the machine account (NAME$).
    Check 'really SYSTEM and really outside the desktop session' `
        ($status.sid -eq 'S-1-5-18' -and $status.session -eq 0 -and -not $status.in_console_session) `
        "user=$($status.user) ($($status.sid)), session=$($status.session), in the desktop session=$($status.in_console_session)"
    [void](Invoke-Api '/quit')
    $gone = Wait-Until { @(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count -eq 0 } 15
    Check '/quit removes the devices' $gone "leftover device entries: $(@(Get-InputDevices | Where-Object { $_ -notin $baseline }).Count)"
}
& schtasks.exe /end /tn $taskName 2>&1 | Out-Null
& schtasks.exe /delete /tn $taskName /f 2>&1 | Out-Host

# --- done --------------------------------------------------------------------------------------
$ui.Close = $true
[void](Wait-Until { $windowRun.IsCompleted } 5)
Add-Notice 'HTTP sample' $(if ($script:failed) { 'FAILED - see the checks in the report' } else { 'all checks passed, as administrator and as SYSTEM' })
if ($script:failed) { exit 1 }
exit 0
