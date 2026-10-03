# Installs the freshly built MSI on this machine and checks that:
#   1. the test-signed UMDF driver installs and starts without test mode,
#   2. a program can create a virtual mouse and a virtual keyboard through the libraries.
# Every check is recorded; a failing check does not hide the later ones.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

$configuration = if ($env:CONFIGURATION) { $env:CONFIGURATION } else { 'Release' }
$platform      = if ($env:PLATFORM) { $env:PLATFORM } else { 'x64' }
$libDir        = Join-Path $RepoRoot "build\$configuration\$platform"
$msi           = Join-Path $OutDir 'WinUHid-dev-test-x64.msi'
$failed        = $false

Add-Report "## Smoke test on the build machine"

# --- 1. Install -----------------------------------------------------------------------------
$installLog = Join-Path $LogDir '05-msi-install.log'
$p = Start-Process -FilePath msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$installLog`"" -Wait -PassThru
Add-Notice 'MSI install' "msiexec exit code $($p.ExitCode)"
if ($p.ExitCode -ne 0) { $failed = $true }

& pnputil /enum-devices /class System 2>&1 | Out-File -FilePath (Join-Path $LogDir '06-pnputil-system-devices.txt') -Encoding utf8
& pnputil /enum-drivers 2>&1 | Out-File -FilePath (Join-Path $LogDir '06-pnputil-drivers.txt') -Encoding utf8

$device = $null
try {
    $device = Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.HardwareID -contains 'Root\WinUHid' } | Select-Object -First 1
} catch {
    Add-Report "- Get-PnpDevice failed: $($_.Exception.Message)"
}
if ($device) {
    Add-Notice 'Control device' "$($device.FriendlyName) / status=$($device.Status) / problem=$($device.Problem) / $($device.InstanceId)"
    if ($device.Status -ne 'OK') { $failed = $true }
} else {
    Add-Notice 'Control device' 'Root\WinUHid device not found'
    $failed = $true
}

# --- 2. Use it from a program ---------------------------------------------------------------
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

function Get-HidDeviceIds {
    try {
        Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.Class -in 'Mouse', 'Keyboard', 'HIDClass' } |
            ForEach-Object { "$($_.Class): $($_.FriendlyName) [$($_.InstanceId)]" }
    } catch { @() }
}

function Wait-NewDevices {
    param([string[]]$Before, [int]$Seconds = 10)
    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Seconds 1
        $new = @(Get-HidDeviceIds | Where-Object { $_ -notin $Before })
        if ($new.Count -gt 0) { Start-Sleep -Seconds 1; return @(Get-HidDeviceIds | Where-Object { $_ -notin $Before }) }
    }
    return @()
}

try {
    Add-Type -TypeDefinition $native -ErrorAction Stop
    $env:PATH = "$libDir;$env:PATH"
    [void][WinUHidNative]::SetDllDirectoryW($libDir)

    # 2a. Can the control device be opened at all?
    $GENERIC_READ_WRITE = [uint32]3221225472   # GENERIC_READ | GENERIC_WRITE
    $handle = [WinUHidNative]::CreateFileW('\\.\WinUHid', $GENERIC_READ_WRITE, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $openError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($handle -eq [IntPtr]::new(-1)) {
        Add-Notice 'Open \\.\WinUHid' "FAILED, Win32 error $openError"
        $failed = $true
    } else {
        [void][WinUHidNative]::CloseHandle($handle)
        Add-Notice 'Open \\.\WinUHid' 'ok'
    }

    $version = [WinUHidNative]::WinUHidGetDriverInterfaceVersion()
    Add-Notice 'Driver interface version' "$version (expected 1)"
    if ($version -ne 1) { $failed = $true }

    # 2b. Ready-made mouse, with our own (non-vendor) identifiers.
    $before = @(Get-HidDeviceIds)
    $info = New-Object 'WinUHidNative+PresetInfo'
    $info.VendorID = 0x1234
    $info.ProductID = 0x5678
    $mouse = [WinUHidNative]::WinUHidMouseCreate([ref]$info)
    $mouseError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($mouse -eq [IntPtr]::Zero) {
        Add-Notice 'Virtual mouse' "create FAILED, Win32 error $mouseError"
        $failed = $true
    } else {
        $new = Wait-NewDevices -Before $before
        $moved = [WinUHidNative]::WinUHidMouseReportMotion($mouse, 5, 5)
        Add-Notice 'Virtual mouse' "created; motion report accepted=$moved; new devices:`n$($new -join "`n")"
        if ($new.Count -eq 0 -or -not $moved) { $failed = $true }
        [WinUHidNative]::WinUHidMouseDestroy($mouse)
        Start-Sleep -Seconds 3
        $left = @(Get-HidDeviceIds | Where-Object { $_ -notin $before })
        Add-Notice 'Virtual mouse removal' "devices still present after destroy: $($left.Count)"
        if ($left.Count -ne 0) { $failed = $true }
    }

    # 2c. Keyboard through the generic API (standard 8-byte boot keyboard report, no LEDs).
    [byte[]]$keyboardDescriptor = @(
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0
    )
    $pin = [System.Runtime.InteropServices.GCHandle]::Alloc($keyboardDescriptor, 'Pinned')
    try {
        $before = @(Get-HidDeviceIds)
        $config = New-Object 'WinUHidNative+DeviceConfig'
        $config.SupportedEvents = 0
        $config.VendorID = 0x1234
        $config.ProductID = 0x5679
        $config.ReportDescriptorLength = [uint16]$keyboardDescriptor.Length
        $config.ReportDescriptor = $pin.AddrOfPinnedObject()
        $keyboard = [WinUHidNative]::WinUHidCreateDevice([ref]$config)
        $keyboardError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($keyboard -eq [IntPtr]::Zero) {
            Add-Notice 'Virtual keyboard' "create FAILED, Win32 error $keyboardError"
            $failed = $true
        } else {
            $started = [WinUHidNative]::WinUHidStartDevice($keyboard, [IntPtr]::Zero, [IntPtr]::Zero)
            $new = Wait-NewDevices -Before $before
            # Left Shift down, then everything released. A lone modifier types nothing on the machine.
            [byte[]]$down = 0x02, 0, 0, 0, 0, 0, 0, 0
            [byte[]]$up   = 0, 0, 0, 0, 0, 0, 0, 0
            $sentDown = [WinUHidNative]::WinUHidSubmitInputReport($keyboard, $down, 8)
            $sentUp   = [WinUHidNative]::WinUHidSubmitInputReport($keyboard, $up, 8)
            Add-Notice 'Virtual keyboard' "created; started=$started; reports accepted=$sentDown/$sentUp; new devices:`n$($new -join "`n")"
            if (-not $started -or $new.Count -eq 0 -or -not $sentDown -or -not $sentUp) { $failed = $true }
            [WinUHidNative]::WinUHidDestroyDevice($keyboard)
            Start-Sleep -Seconds 3
            $left = @(Get-HidDeviceIds | Where-Object { $_ -notin $before })
            Add-Notice 'Virtual keyboard removal' "devices still present after destroy: $($left.Count)"
            if ($left.Count -ne 0) { $failed = $true }
        }
    } finally {
        $pin.Free()
    }
} catch {
    Add-Notice 'Program test' "exception: $($_.Exception.Message)"
    $failed = $true
}

# --- 3. Evidence for diagnosis --------------------------------------------------------------
$setupLog = 'C:\Windows\INF\setupapi.dev.log'
if (Test-Path $setupLog) {
    Get-Content -Path $setupLog -Tail 400 | Out-File -FilePath (Join-Path $LogDir '07-setupapi-dev-tail.log') -Encoding utf8
}
try {
    Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 40 -ErrorAction Stop |
        ForEach-Object { "$($_.TimeCreated.ToString('s')) [$($_.Id)] $($_.Message)" } |
        Out-File -FilePath (Join-Path $LogDir '07-umdf-events.log') -Encoding utf8
} catch {
    Add-Report "- UMDF event log not readable: $($_.Exception.Message)"
}

# --- 4. Uninstall ---------------------------------------------------------------------------
$uninstallLog = Join-Path $LogDir '08-msi-uninstall.log'
$p = Start-Process -FilePath msiexec.exe -ArgumentList '/x', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$uninstallLog`"" -Wait -PassThru
$stillThere = $null
try { $stillThere = Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.HardwareID -contains 'Root\WinUHid' } } catch { }
Add-Notice 'MSI uninstall' "msiexec exit code $($p.ExitCode); control device still present=$([bool]$stillThere)"
if ($p.ExitCode -ne 0 -or $stillThere) { $failed = $true }

Add-Notice 'Smoke test result' $(if ($failed) { 'FAILED - see the checks above' } else { 'all checks passed' })
if ($failed) { exit 1 }
exit 0
