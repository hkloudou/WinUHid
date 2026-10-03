# Shared helpers for the dev CI scripts. Dot-source this file.

$script:RepoRoot   = Split-Path -Parent $PSScriptRoot
$script:OutDir     = Join-Path $RepoRoot 'out'
$script:LogDir     = Join-Path $OutDir 'logs'
$script:KitDir     = Join-Path $OutDir 'kit'      # what a tester downloads: MSI, certificate, libraries, scripts
$script:ReportFile = Join-Path $OutDir 'report.md'

New-Item -ItemType Directory -Force -Path $OutDir, $LogDir, $KitDir | Out-Null

function Add-Report {
    param([string]$Text)
    Add-Content -Path $ReportFile -Value $Text -Encoding utf8
    Write-Host $Text
}

# A notice is shown as an annotation on the workflow run and recorded in the report.
function Add-Notice {
    param([string]$Title, [string]$Message)
    $escaped = $Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::notice title=$Title::$escaped"
    Add-Content -Path $ReportFile -Value "- **${Title}**: $Message" -Encoding utf8
}

# Finds the newest copy of a Windows Kits tool (signtool.exe, Inf2Cat.exe, stampinf.exe ...).
function Find-KitTool {
    param([string]$Name, [string]$PreferArch = 'x64')
    $root = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    if (-not (Test-Path $root)) { return $null }
    $all = Get-ChildItem -Path $root -Recurse -Filter $Name -ErrorAction SilentlyContinue
    $preferred = $all | Where-Object { $_.FullName -match "\\$PreferArch\\" }
    $pick = if ($preferred) { $preferred } else { $all }
    $pick | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Get-VsInstallPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }
    & $vswhere -latest -products * -property installationPath
}

# True when both halves of the WDK are present: the MSBuild driver toolset and the UMDF headers.
function Test-DriverToolchain {
    $vs = Get-VsInstallPath
    $toolset = $null
    if ($vs) {
        $toolset = Get-ChildItem -Path "$vs\MSBuild\Microsoft\VC\*\Platforms\x64\PlatformToolsets\WindowsUserModeDriver10.0" -ErrorAction SilentlyContinue
    }
    $headers = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\Include\wdf\umdf\2.*\wdf.h" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Toolset = [bool]$toolset
        Headers = [bool]$headers
        Ok      = ([bool]$toolset -and [bool]$headers)
    }
}

# Adds a certificate (public part only) to a LocalMachine store without relying on the PKI module.
function Add-CertToMachineStore {
    param([string]$CerPath, [string]$StoreName)
    $cert  = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CerPath)
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($StoreName, 'LocalMachine')
    $store.Open('ReadWrite')
    try { $store.Add($cert) } finally { $store.Close() }
}

# Records the facts about this machine that matter for driver installation.
function Add-MachineReport {
    $os = Get-CimInstance Win32_OperatingSystem
    Add-Report "## Machine"
    Add-Report "- Runner image: ImageOS=$env:ImageOS, ImageVersion=$env:ImageVersion"
    Add-Report "- OS: $($os.Caption), build $($os.BuildNumber)"
    # A machine in test-signing mode cannot prove that the package installs on a normal machine.
    $bcd = (& bcdedit /enum '{current}' 2>&1 | Out-String)
    $testSigning = if ($bcd -match '(?im)^\s*testsigning\s+(\S+)') { $Matches[1] } else { 'not set (off)' }
    Add-Notice 'Test-signing boot option' $testSigning
    try {
        Add-Report "- Secure Boot: $(Confirm-SecureBootUEFI)"
    } catch {
        Add-Report "- Secure Boot: unknown ($($_.Exception.Message))"
    }
}
