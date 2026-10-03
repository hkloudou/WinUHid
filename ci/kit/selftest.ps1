# WinUHid dev test build - self test.
# Creates a virtual mouse and a virtual keyboard through the libraries next to this script,
# checks that Windows sees them and that their input really arrives, then removes them.
# Works with Windows PowerShell 5.1. Run from an administrator prompt (selftest.cmd does that check).
# ASCII only on purpose: Windows PowerShell reads BOM-less scripts with the system code page.
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
$script:failed = $false
function Pass([string]$m) { Write-Host "[PASS] $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:failed = $true }
function Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Info([string]$m) { Write-Host "[INFO] $m" }

$native = @'
using System;
using System.Runtime.InteropServices;

public static class WinUHidNative
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetDllDirectoryW(string directory);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_CODEINTEGRITY_INFORMATION { public uint Length; public uint CodeIntegrityOptions; }
    [DllImport("ntdll.dll")]
    public static extern int NtQuerySystemInformation(int infoClass, ref SYSTEM_CODEINTEGRITY_INFORMATION info, int length, out int returnLength);

    // The code integrity options Windows is running with right now, or -1 when they cannot be read.
    // Bit 0x02 is set while the machine runs in test-signing mode ("Test Mode").
    public static int CodeIntegrityOptions()
    {
        SYSTEM_CODEINTEGRITY_INFORMATION info = new SYSTEM_CODEINTEGRITY_INFORMATION();
        info.Length = 8;
        int returned;
        int status = NtQuerySystemInformation(103, ref info, 8, out returned);   // SystemCodeIntegrityInformation
        if (status != 0) return -1;
        return (int)info.CodeIntegrityOptions;
    }

    // True when this program runs inside a Remote Desktop session.
    public static bool IsRemoteSession()
    {
        return GetSystemMetrics(0x1000) != 0;   // SM_REMOTESESSION
    }

    // Returns {x, y}, or null when this session has no pointer to read.
    public static int[] CursorPosition()
    {
        POINT p;
        if (!GetCursorPos(out p)) return null;
        return new int[] { p.X, p.Y };
    }

    public static bool IsKeyDown(int virtualKey)
    {
        return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
    }

    [DllImport("WinUHid.dll", SetLastError = true)]
    public static extern uint WinUHidGetDriverInterfaceVersion();

    // WINUHID_PRESET_DEVICE_INFO (default packing)
    [StructLayout(LayoutKind.Sequential)]
    public struct PresetInfo
    {
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
        public Guid ContainerId;
        public IntPtr InstanceID;
        public IntPtr HardwareIDs;
    }

    [DllImport("WinUHidDevs.dll", SetLastError = true)]
    public static extern IntPtr WinUHidMouseCreate(ref PresetInfo info);
    [DllImport("WinUHidDevs.dll", SetLastError = true)]
    public static extern bool WinUHidMouseReportMotion(IntPtr mouse, short dx, short dy);
    [DllImport("WinUHidDevs.dll", SetLastError = true)]
    public static extern void WinUHidMouseDestroy(IntPtr mouse);

    // WINUHID_DEVICE_CONFIG (declared between pshpack1.h / poppack.h)
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct DeviceConfig
    {
        public uint SupportedEvents;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
        public ushort ReportDescriptorLength;
        public IntPtr ReportDescriptor;
        public Guid ContainerId;
        public IntPtr InstanceID;
        public IntPtr HardwareIDs;
        public uint ReadReportPeriodUs;
    }

    [DllImport("WinUHid.dll", SetLastError = true)]
    public static extern IntPtr WinUHidCreateDevice(ref DeviceConfig config);
    [DllImport("WinUHid.dll", SetLastError = true)]
    public static extern bool WinUHidStartDevice(IntPtr device, IntPtr callback, IntPtr context);
    [DllImport("WinUHid.dll", SetLastError = true)]
    public static extern bool WinUHidSubmitInputReport(IntPtr device, byte[] report, uint size);
    [DllImport("WinUHid.dll", SetLastError = true)]
    public static extern void WinUHidDestroyDevice(IntPtr device);
}
'@

function Get-InputDevices {
    try {
        @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.Class -eq 'Mouse' -or $_.Class -eq 'Keyboard' -or $_.Class -eq 'HIDClass' } |
            ForEach-Object { "$($_.Class): $($_.FriendlyName) [$($_.InstanceId)]" })
    } catch { @() }
}

function Wait-NewDevices {
    param([string[]]$Before, [int]$Seconds = 10)
    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Seconds 1
        $new = @(Get-InputDevices | Where-Object { $Before -notcontains $_ })
        if ($new.Count -gt 0) {
            Start-Sleep -Seconds 1
            return @(Get-InputDevices | Where-Object { $Before -notcontains $_ })
        }
    }
    return @()
}

function Wait-DevicesGone {
    param([string[]]$Before, [int]$Seconds = 10)
    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Seconds 1
        $left = @(Get-InputDevices | Where-Object { $Before -notcontains $_ })
        if ($left.Count -eq 0) { return @() }
    }
    return $left
}

$os = Get-CimInstance Win32_OperatingSystem
Info "$($os.Caption), build $($os.BuildNumber), PowerShell $($PSVersionTable.PSVersion)"
$buildFile = Join-Path $PSScriptRoot 'BUILD.txt'
if (Test-Path $buildFile) { Get-Content $buildFile | Select-Object -First 2 | ForEach-Object { Info "kit: $_" } }

try {
    foreach ($dll in 'WinUHid.dll', 'WinUHidDevs.dll') {
        if (-not (Test-Path (Join-Path $libDir $dll))) { throw "Missing $dll in $libDir" }
    }
    Add-Type -TypeDefinition $native
    $env:PATH = "$libDir;$env:PATH"
    [void][WinUHidNative]::SetDllDirectoryW($libDir)

    # Whether this machine can prove "installs on a normal machine": it must not be in test mode.
    $ci = [WinUHidNative]::CodeIntegrityOptions()
    if ($ci -lt 0) { Info 'Test mode: could not be determined.' }
    elseif ($ci -band 0x02) { Info 'Test mode: ON. This machine accepts test-signed drivers, so it does not prove a normal machine would.' }
    else { Info 'Test mode: off (normal machine).' }
    $secureBoot = 'unknown'
    try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $secureBoot = 'on' } else { $secureBoot = 'off' } }
    catch { $secureBoot = 'not available (legacy BIOS boot or not readable)' }
    Info "Secure Boot: $secureBoot."

    # Virtual devices behave like hardware plugged into the machine: their input goes to the
    # physical console session. A Remote Desktop session has its own input path and does not see it.
    $remote = [WinUHidNative]::IsRemoteSession()
    $remoteHint = ''
    if ($remote) {
        Info 'This is a Remote Desktop session. Devices can be created here, but their input goes to'
        Info 'the physical console, not to this session, so the pointer/key observations will not show it.'
        $remoteHint = ' Expected in a Remote Desktop session.'
    } else {
        Info 'This is the console session.'
    }

    # --- 1. Driver is installed and reachable --------------------------------------------------
    $GENERIC_READ_WRITE = [uint32]3221225472   # GENERIC_READ | GENERIC_WRITE
    $handle = [WinUHidNative]::CreateFileW('\\.\WinUHid', $GENERIC_READ_WRITE, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $openError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($handle -eq [IntPtr](-1)) {
        switch ($openError) {
            2       { Fail 'Control device \\.\WinUHid does not exist. Is the driver installed? Run install.cmd first.' }
            5       { Fail 'Access denied opening \\.\WinUHid. Only administrators may drive virtual devices: run this as administrator.' }
            default { Fail "Cannot open \\.\WinUHid, Win32 error $openError." }
        }
        throw 'The driver is not reachable; the remaining checks were skipped.'
    }
    [void][WinUHidNative]::CloseHandle($handle)
    Pass 'Control device \\.\WinUHid opened.'

    $version = [WinUHidNative]::WinUHidGetDriverInterfaceVersion()
    if ($version -eq 1) { Pass "Driver interface version $version." } else { Fail "Driver interface version $version, expected 1." }

    # --- 2. Virtual mouse ----------------------------------------------------------------------
    $before = Get-InputDevices
    $info = New-Object 'WinUHidNative+PresetInfo'
    $info.VendorID  = 0x1234     # placeholder test identifiers, not a real vendor's
    $info.ProductID = 0x5678
    $mouse = [WinUHidNative]::WinUHidMouseCreate([ref]$info)
    $mouseError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($mouse -eq [IntPtr]::Zero) {
        Fail "Virtual mouse could not be created, Win32 error $mouseError."
    } else {
        try {
            $new = Wait-NewDevices -Before $before
            if ($new.Count -gt 0) { Pass 'Virtual mouse created. Windows now lists:'; $new | ForEach-Object { Info "    $_" } }
            else { Fail 'Virtual mouse was created but Windows lists no new device.' }

            # Does the motion really reach the pointer?
            $p0 = [WinUHidNative]::CursorPosition()
            $dx = 60
            if ($p0 -and $p0[0] -gt 300) { $dx = -60 }
            $accepted = [WinUHidNative]::WinUHidMouseReportMotion($mouse, [int16]$dx, 0)
            Start-Sleep -Milliseconds 400
            $p1 = [WinUHidNative]::CursorPosition()
            if (-not $accepted) { Fail 'The driver rejected the motion report.' }
            elseif (-not $p0 -or -not $p1) { Warn 'Motion report accepted, but this session has no pointer to observe.' }
            elseif ($p1[0] -ne $p0[0]) { Pass "Pointer really moved: x $($p0[0]) -> $($p1[0])." }
            else { Warn "Motion report accepted, but the pointer did not move (x stayed at $($p0[0])).$remoteHint" }
            [void][WinUHidNative]::WinUHidMouseReportMotion($mouse, [int16](-$dx), 0)

            # Something to watch: the pointer draws a small square.
            Info 'Watch the pointer: it draws a small square.'
            $sides = @(@(8, 0), @(0, 8), @(-8, 0), @(0, -8))
            foreach ($side in $sides) {
                for ($i = 0; $i -lt 12; $i++) {
                    [void][WinUHidNative]::WinUHidMouseReportMotion($mouse, [int16]$side[0], [int16]$side[1])
                    Start-Sleep -Milliseconds 15
                }
            }
        } finally {
            [WinUHidNative]::WinUHidMouseDestroy($mouse)
        }
        $left = Wait-DevicesGone -Before $before
        if ($left.Count -eq 0) { Pass 'Virtual mouse removed again.' } else { Fail "Virtual mouse still listed after removal: $($left -join '; ')" }
    }

    # --- 3. Virtual keyboard (generic API, standard 8-byte keyboard report) --------------------
    [byte[]]$keyboardDescriptor = @(
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0
    )
    $pin = [System.Runtime.InteropServices.GCHandle]::Alloc($keyboardDescriptor, 'Pinned')
    try {
        $before = Get-InputDevices
        $config = New-Object 'WinUHidNative+DeviceConfig'
        $config.SupportedEvents = 0
        $config.VendorID  = 0x1234
        $config.ProductID = 0x5679
        $config.ReportDescriptorLength = [uint16]$keyboardDescriptor.Length
        $config.ReportDescriptor = $pin.AddrOfPinnedObject()
        $keyboard = [WinUHidNative]::WinUHidCreateDevice([ref]$config)
        $keyboardError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($keyboard -eq [IntPtr]::Zero) {
            Fail "Virtual keyboard could not be created, Win32 error $keyboardError."
        } else {
            [byte[]]$shiftDown = 0x02, 0, 0, 0, 0, 0, 0, 0     # Left Shift held; a lone modifier types nothing
            [byte[]]$allUp     = 0, 0, 0, 0, 0, 0, 0, 0
            try {
                $started = [WinUHidNative]::WinUHidStartDevice($keyboard, [IntPtr]::Zero, [IntPtr]::Zero)
                if (-not $started) { Fail "Virtual keyboard did not start, Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
                $new = Wait-NewDevices -Before $before
                if ($new.Count -gt 0) { Pass 'Virtual keyboard created. Windows now lists:'; $new | ForEach-Object { Info "    $_" } }
                else { Fail 'Virtual keyboard was created but Windows lists no new device.' }

                $VK_LSHIFT = 0xA0
                $idle = [WinUHidNative]::IsKeyDown($VK_LSHIFT)
                $sentDown = [WinUHidNative]::WinUHidSubmitInputReport($keyboard, $shiftDown, 8)
                Start-Sleep -Milliseconds 400
                $held = [WinUHidNative]::IsKeyDown($VK_LSHIFT)
                $sentUp = [WinUHidNative]::WinUHidSubmitInputReport($keyboard, $allUp, 8)
                Start-Sleep -Milliseconds 400
                $released = -not [WinUHidNative]::IsKeyDown($VK_LSHIFT)
                if (-not $sentDown -or -not $sentUp) { Fail 'The driver rejected a keyboard report.' }
                elseif ($idle) { Warn 'Keyboard reports accepted; Left Shift was already held, so the effect could not be observed.' }
                elseif ($held -and $released) { Pass 'Key press really arrived: Windows saw Left Shift go down and up.' }
                else { Warn "Keyboard reports accepted, but this session did not see the key (down seen=$held, up seen=$released).$remoteHint" }
            } finally {
                [void][WinUHidNative]::WinUHidSubmitInputReport($keyboard, $allUp, 8)
                [WinUHidNative]::WinUHidDestroyDevice($keyboard)
            }
            $left = Wait-DevicesGone -Before $before
            if ($left.Count -eq 0) { Pass 'Virtual keyboard removed again.' } else { Fail "Virtual keyboard still listed after removal: $($left -join '; ')" }
        }
    } finally {
        $pin.Free()
    }
} catch {
    Fail $_.Exception.Message
}

Write-Host ''
if ($script:failed) {
    Write-Host 'RESULT: FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: OK' -ForegroundColor Green
exit 0
