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

function Invoke-KitScript {
    # Runs one of the kit's .cmd files, keeps its output as a log, returns its exit code.
    param([string]$Name, [string]$LogName)
    $logPath = Join-Path $LogDir $LogName
    & cmd.exe /c (Join-Path $KitDir $Name) 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $logPath | Out-Host
    return $LASTEXITCODE
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

# --- 1. install.cmd -------------------------------------------------------------------------
Add-Report "## Install (install.cmd)"
$rc = Invoke-KitScript 'install.cmd' '10-install-cmd.txt'
Add-Notice 'install.cmd' "exit code $rc"
if ($rc -ne 0) { $failed = $true }
Copy-Item (Join-Path $KitDir 'install.log') (Join-Path $LogDir '11-msi-install.log') -ErrorAction SilentlyContinue

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
Add-Report "## Self test (selftest.cmd)"
$rc = Invoke-KitScript 'selftest.cmd' '20-selftest.txt'
Add-Report '```'
Get-Content (Join-Path $LogDir '20-selftest.txt') -ErrorAction SilentlyContinue | ForEach-Object { Add-Report $_ }
Add-Report '```'
$selftest = @(Get-Content (Join-Path $LogDir '20-selftest.txt') -ErrorAction SilentlyContinue)
$summary = "exit code $rc; pass=$(@($selftest -match '^\[PASS\]').Count), warn=$(@($selftest -match '^\[WARN\]').Count), fail=$(@($selftest -match '^\[FAIL\]').Count)"
Add-Notice 'selftest.cmd' $summary
if ($rc -ne 0) { $failed = $true }

# --- 3. Evidence for diagnosis --------------------------------------------------------------
$setupLog = 'C:\Windows\INF\setupapi.dev.log'
if (Test-Path $setupLog) {
    Get-Content -Path $setupLog -Tail 400 | Out-File -FilePath (Join-Path $LogDir '30-setupapi-dev-tail.log') -Encoding utf8
}
& pnputil /enum-drivers 2>&1 | Out-File -FilePath (Join-Path $LogDir '30-pnputil-drivers.txt') -Encoding utf8

# --- 4. uninstall.cmd -----------------------------------------------------------------------
Add-Report "## Uninstall (uninstall.cmd)"
$rc = Invoke-KitScript 'uninstall.cmd' '40-uninstall-cmd.txt'
Copy-Item (Join-Path $KitDir 'uninstall.log') (Join-Path $LogDir '41-msi-uninstall.log') -ErrorAction SilentlyContinue
$deviceLeft = [bool](Get-ControlDevice)
$rootLeft   = Test-CertInStore 'Root'
$pubLeft    = Test-CertInStore 'TrustedPublisher'
Add-Notice 'uninstall.cmd' "exit code $rc; control device left=$deviceLeft; test certificate left in Root=$rootLeft, in TrustedPublisher=$pubLeft"
if ($rc -ne 0 -or $deviceLeft -or $rootLeft -or $pubLeft) { $failed = $true }

# --- 5. What if the tester skips the certificate step? (informational) ----------------------
Add-Report "## Install without trusting the certificate"
$log = Join-Path $LogDir '50-msi-install-untrusted.log'
$p = Start-Process -FilePath msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"" -Wait -PassThru
$verdict = if ($p.ExitCode -eq 0) { 'INSTALLED even though the certificate is not trusted' } else { 'refused' }
Add-Notice 'Install without trusting the certificate' "msiexec exit code $($p.ExitCode): $verdict"
if ($p.ExitCode -eq 0) {
    $p = Start-Process -FilePath msiexec.exe -ArgumentList '/x', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
    Add-Report "- cleanup uninstall: msiexec exit code $($p.ExitCode)"
}
if (Test-Path $setupLog) {
    Get-Content -Path $setupLog -Tail 150 | Out-File -FilePath (Join-Path $LogDir '51-setupapi-dev-tail-untrusted.log') -Encoding utf8
}
if (Get-ControlDevice) {
    Add-Notice 'Leftover' 'control device still present after the untrusted attempt'
    $failed = $true
}

Add-Notice 'Install test result' $(if ($failed) { 'FAILED - see the checks above' } else { 'all checks passed' })
if ($failed) { exit 1 }
exit 0
