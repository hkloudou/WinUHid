# Runs on a clean machine that did not build anything: takes the tester kit exactly as a
# tester would download it and goes through install.cmd -> selftest.cmd -> uninstall.cmd.
# Every check is recorded; a failing check does not hide the later ones.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

$failed = $false
$msi    = Join-Path $KitDir 'WinUHid-dev-test-x64.msi'
$thumb  = (Get-Content -Path (Join-Path $KitDir 'cert-thumbprint.txt') -Raw).Trim()
$build  = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber

Add-MachineReport
if (Test-Path (Join-Path $KitDir 'BUILD.txt')) {
    Get-Content (Join-Path $KitDir 'BUILD.txt') | ForEach-Object { Add-Report "- kit: $_" }
}

function Save-HangEvidence {
    # When something does not return, record what is running and what is on screen.
    param([string]$Tag)
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -match '^(msiexec|cmd|powershell|pwsh|certutil|rundll32|drvinst|pnputil|WUDFHost|consent|dllhost)\.exe$' } |
        ForEach-Object { "$($_.ProcessId) (parent $($_.ParentProcessId), session $($_.SessionId)) $($_.Name): $($_.CommandLine)" } |
        Out-File -FilePath (Join-Path $LogDir "$Tag-processes.txt") -Encoding utf8
    Get-Process | Where-Object { $_.MainWindowTitle } |
        ForEach-Object { "$($_.Id) $($_.ProcessName): $($_.MainWindowTitle)" } |
        Out-File -FilePath (Join-Path $LogDir "$Tag-windows.txt") -Encoding utf8
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save((Join-Path $LogDir "$Tag-screen.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
    } catch {
        Add-Report "- screenshot failed: $($_.Exception.Message)"
    }
}

function Invoke-WithTimeout {
    # Runs a program with its output going to a file, and gives up after the timeout.
    # Returns the exit code, or -1 when it had to be stopped.
    param([string]$FilePath, [string[]]$Arguments, [string]$LogName, [int]$TimeoutSeconds = 240, [string]$InputFile)
    $logPath = Join-Path $LogDir $LogName
    $start = @{ FilePath = $FilePath; ArgumentList = $Arguments; NoNewWindow = $true; PassThru = $true
                RedirectStandardOutput = $logPath; RedirectStandardError = "$logPath.stderr" }
    if ($InputFile) { $start.RedirectStandardInput = $InputFile }
    $p = Start-Process @start
    $null = $p.Handle   # keeps the exit code readable after the process ends
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        $tag = [System.IO.Path]::GetFileNameWithoutExtension($LogName) + '-hang'
        Save-HangEvidence -Tag $tag
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        Add-Content -Path $logPath -Value "TIMED OUT after $TimeoutSeconds seconds and was stopped."
        Get-Content -Path $logPath -ErrorAction SilentlyContinue | Out-Host
        return -1
    }
    $p.WaitForExit()
    Get-Content -Path $logPath -ErrorAction SilentlyContinue | Out-Host
    if ((Test-Path "$logPath.stderr") -and (Get-Item "$logPath.stderr").Length -eq 0) { Remove-Item "$logPath.stderr" }
    return $p.ExitCode
}

function Invoke-KitScript {
    # Runs one of the kit's .cmd files, keeps its output as a log, returns its exit code.
    # By default with /y (unattended). With -PressKeys it runs the way a person starts it, and
    # the key presses it waits for are supplied as input.
    param([string]$Name, [string]$LogName, [switch]$PressKeys)
    $script = Join-Path $KitDir $Name
    if ($PressKeys) {
        $keys = Join-Path $env:RUNNER_TEMP 'key-presses.txt'
        Set-Content -Path $keys -Value '', '', '', '' -Encoding ascii
        return Invoke-WithTimeout -FilePath 'cmd.exe' -Arguments '/c', "`"$script`"" -LogName $LogName -InputFile $keys
    }
    return Invoke-WithTimeout -FilePath 'cmd.exe' -Arguments '/c', "`"`"$script`" /y`"" -LogName $LogName
}

function Copy-MsiLog {
    # Windows Installer writes UTF-16 logs; keep a UTF-8 copy so the tail of it stays readable.
    param([string]$Source, [string]$LogName)
    if (Test-Path $Source) {
        Get-Content -Path $Source -Encoding Unicode -ErrorAction SilentlyContinue |
            Set-Content -Path (Join-Path $LogDir $LogName) -Encoding utf8
    }
}

function Get-ControlDevice {
    try {
        Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.HardwareID -contains 'Root\WinUHid' } | Select-Object -First 1
    } catch {
        Add-Report "- Get-PnpDevice failed: $($_.Exception.Message)"
    }
}

function Test-CertInStore {
    param([string]$StoreName)
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($StoreName, 'LocalMachine')
    $store.Open('ReadOnly')
    try { return [bool]($store.Certificates | Where-Object { $_.Thumbprint -eq $thumb }) } finally { $store.Close() }
}

# --- 1a. install.cmd the way a person runs it: notice, key press, install; then remove again ----
Add-Report "## Install with the confirmation prompt (install.cmd, key presses supplied)"
$rc = Invoke-KitScript 'install.cmd' '08-install-with-prompt.txt' -PressKeys
$shown = @(Get-Content (Join-Path $LogDir '08-install-with-prompt.txt') -ErrorAction SilentlyContinue)
$asked = [bool]($shown -match 'Press any key to install')
$warned = [bool]($shown -match 'Do NOT distribute it to users')
Add-Notice 'install.cmd (prompted)' "exit code $rc; notice shown=$warned; asked for a key press=$asked; control device present=$([bool](Get-ControlDevice))"
if ($rc -ne 0 -or -not $asked -or -not $warned -or -not (Get-ControlDevice)) { $failed = $true }
$rc = Invoke-KitScript 'uninstall.cmd' '09-uninstall-after-prompted.txt'
Add-Notice 'uninstall.cmd (between the two installs)' "exit code $rc; control device left=$([bool](Get-ControlDevice))"
if ($rc -ne 0 -or (Get-ControlDevice)) { $failed = $true }

# --- 1b. install.cmd /y: unattended ------------------------------------------------------------
Add-Report "## Install unattended (install.cmd /y)"
$rc = Invoke-KitScript 'install.cmd' '10-install-cmd.txt'
$shown = @(Get-Content (Join-Path $LogDir '10-install-cmd.txt') -ErrorAction SilentlyContinue)
$asked = [bool]($shown -match 'Press any key to install')
$warned = [bool]($shown -match 'Do NOT distribute it to users')
Add-Notice 'install.cmd /y' "exit code $rc; notice shown=$warned; asked for a key press=$asked (must not)"
if ($rc -ne 0 -or $asked -or -not $warned) { $failed = $true }
Copy-MsiLog (Join-Path $KitDir 'install.log') '11-msi-install.log'

$device = Get-ControlDevice
if ($device) {
    $section = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_DriverInfSection' -ErrorAction SilentlyContinue).Data
    $expected = if ($build -ge 22000) { 'WinUHid_Win11' } else { 'WinUHid_Win10' }
    Add-Notice 'Control device' "$($device.FriendlyName) / status=$($device.Status) / $($device.InstanceId)"
    Add-Notice 'INF rules used' "$section on OS build $build (expected $expected*)"
    if ($device.Status -ne 'OK') { $failed = $true }
    if ("$section" -notlike "$expected*") { $failed = $true }
} else {
    Add-Notice 'Control device' 'Root\WinUHid device not found'
    $failed = $true
}

# --- 2. selftest.cmd (Windows PowerShell 5.1, as on a tester's machine) ---------------------
Add-Report "## Self test (selftest.cmd /y)"
$rc = Invoke-KitScript 'selftest.cmd' '20-selftest.txt'
Add-Report '```'
Get-Content (Join-Path $LogDir '20-selftest.txt') -ErrorAction SilentlyContinue | ForEach-Object { Add-Report $_ }
Add-Report '```'
$selftest = @(Get-Content (Join-Path $LogDir '20-selftest.txt') -ErrorAction SilentlyContinue)
$summary = "exit code $rc; pass=$(@($selftest -match '^\[PASS\]').Count), warn=$(@($selftest -match '^\[WARN\]').Count), fail=$(@($selftest -match '^\[FAIL\]').Count)"
Add-Notice 'selftest.cmd' $summary
if ($rc -ne 0) { $failed = $true }

# --- 2b. Go sample: a real program calling WinUHid.dll and WinUHidDevs.dll -------------------
# -strict: this is the console session, so input that cannot be seen arriving is a failure.
# -click:  also checks that a left button press arrives as the left button.
Add-Report "## Go sample (examples\go\winuhid-sample.exe -click -strict)"
$rc = Invoke-WithTimeout -FilePath (Join-Path $KitDir 'examples\go\winuhid-sample.exe') -Arguments '-click', '-strict' -LogName '25-go-sample.txt' -TimeoutSeconds 120
$goSample = @(Get-Content (Join-Path $LogDir '25-go-sample.txt') -ErrorAction SilentlyContinue)
Add-Report '```'
$goSample | ForEach-Object { Add-Report $_ }
Add-Report '```'
Add-Notice 'Go sample' "exit code $rc; pass=$(@($goSample -match '^\[PASS\]').Count), warn=$(@($goSample -match '^\[WARN\]').Count), fail=$(@($goSample -match '^\[FAIL\]').Count)"
if ($rc -ne 0) { $failed = $true }

# --- 2c. Go sample without any DLL: talks to the driver directly -----------------------------
# Run from a folder that holds nothing but the program, so it cannot be picking up a DLL.
Add-Report "## Go sample without DLLs (examples\go-nodll\winuhid-nodll-sample.exe -click -strict)"
$alone = Join-Path $env:RUNNER_TEMP 'nodll-alone'
Remove-Item -Path $alone -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $alone | Out-Null
Copy-Item -Path (Join-Path $KitDir 'examples\go-nodll\winuhid-nodll-sample.exe') -Destination $alone
Add-Report "- run from $alone, which contains: $((Get-ChildItem $alone | ForEach-Object Name) -join ', ')"
$rc = Invoke-WithTimeout -FilePath (Join-Path $alone 'winuhid-nodll-sample.exe') -Arguments '-click', '-strict' -LogName '26-go-nodll-sample.txt' -TimeoutSeconds 120
$goNoDll = @(Get-Content (Join-Path $LogDir '26-go-nodll-sample.txt') -ErrorAction SilentlyContinue)
Add-Report '```'
$goNoDll | ForEach-Object { Add-Report $_ }
Add-Report '```'
Add-Notice 'Go sample without DLLs' "exit code $rc; pass=$(@($goNoDll -match '^\[PASS\]').Count), warn=$(@($goNoDll -match '^\[WARN\]').Count), fail=$(@($goNoDll -match '^\[FAIL\]').Count)"
if ($rc -ne 0) { $failed = $true }

# --- 2d. HTTP reference server, as administrator and as SYSTEM ------------------------------
& "$PSScriptRoot/http-sample-test.ps1"
if ($LASTEXITCODE -ne 0) { $failed = $true }

# --- 3. Evidence for diagnosis --------------------------------------------------------------
$setupLog = 'C:\Windows\INF\setupapi.dev.log'
if (Test-Path $setupLog) {
    Get-Content -Path $setupLog -Tail 400 | Out-File -FilePath (Join-Path $LogDir '30-setupapi-dev-tail.log') -Encoding utf8
}
& pnputil /enum-drivers 2>&1 | Out-File -FilePath (Join-Path $LogDir '30-pnputil-drivers.txt') -Encoding utf8

# --- 4. uninstall.cmd -----------------------------------------------------------------------
Add-Report "## Uninstall (uninstall.cmd /y)"
$rc = Invoke-KitScript 'uninstall.cmd' '40-uninstall-cmd.txt'
Copy-MsiLog (Join-Path $KitDir 'uninstall.log') '41-msi-uninstall.log'
$deviceLeft = [bool](Get-ControlDevice)
$rootLeft   = Test-CertInStore 'Root'
$pubLeft    = Test-CertInStore 'TrustedPublisher'
Add-Notice 'uninstall.cmd' "exit code $rc; control device left=$deviceLeft; test certificate left in Root=$rootLeft, in TrustedPublisher=$pubLeft"
if ($rc -ne 0 -or $deviceLeft -or $rootLeft -or $pubLeft) { $failed = $true }

Add-Notice 'Install test result' $(if ($failed) { 'FAILED - see the checks above' } else { 'all checks passed' })

# --- 5. What if the certificate step is skipped? --------------------------------------------
# Informational and deliberately last: without the certificate step the installer does not
# fail, it stops inside its driver install step and never returns, so it has to be abandoned.
# That leaves this (throwaway) machine half-installed.
Add-Report "## Install without trusting the certificate (informational)"
$log = Join-Path $env:RUNNER_TEMP 'msi-install-untrusted.log'
$rc = Invoke-WithTimeout -FilePath 'msiexec.exe' -Arguments '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"" `
    -LogName '50-msiexec-untrusted.txt' -TimeoutSeconds 60
$verdict = switch ($rc) {
    0       { 'INSTALLED silently even though the certificate is not trusted' }
    -1      { 'did not complete within 60 seconds and was abandoned' }
    default { 'refused' }
}
Add-Notice 'Install without trusting the certificate' "msiexec exit code ${rc}: $verdict"
Copy-MsiLog $log '50-msi-install-untrusted.log'
if (Test-Path $setupLog) {
    Get-Content -Path $setupLog -Tail 150 | Out-File -FilePath (Join-Path $LogDir '51-setupapi-dev-tail-untrusted.log') -Encoding utf8
}

if ($failed) { exit 1 }
exit 0
