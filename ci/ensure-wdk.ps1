# Makes sure the machine can build a UMDF driver: WDK headers/libs plus the Visual Studio driver toolset.
# Hosted runner images differ: some ship the WDK, newer ones intentionally do not.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

$state = Test-DriverToolchain
if ($state.Ok) {
    Add-Report "- WDK: already present, nothing installed"
    exit 0
}

Add-Report "## Installing WDK (toolset=$($state.Toolset), headers=$($state.Headers))"

if (-not $state.Headers) {
    $installed = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'Trying winget ...'
        & winget install --source winget --exact --id Microsoft.WindowsWDK.10.0.26100 --accept-source-agreements --accept-package-agreements --silent
        Add-Report "- winget WDK install exit code: $LASTEXITCODE"
        $installed = (Test-DriverToolchain).Headers
    }
    if (-not $installed) {
        Write-Host 'Trying direct download of wdksetup.exe ...'
        $url = 'https://download.microsoft.com/download/41fb59c2-1723-45f9-a270-96b73ad58233/KIT_BUNDLE_WDK_MEDIACREATION/wdksetup.exe'
        $exe = Join-Path $env:RUNNER_TEMP 'wdksetup.exe'
        try {
            Invoke-WebRequest -Uri $url -OutFile $exe
            $p = Start-Process -FilePath $exe -ArgumentList '/quiet', '/norestart', '/ceip', 'off' -Wait -PassThru
            Add-Report "- wdksetup.exe exit code: $($p.ExitCode)"
        } catch {
            Add-Report "- wdksetup.exe download/install failed: $($_.Exception.Message)"
        }
    }
}

if (-not (Test-DriverToolchain).Toolset) {
    $vs = Get-VsInstallPath
    $setup = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
    foreach ($component in 'Component.Microsoft.Windows.DriverKit', 'Microsoft.VisualStudio.Component.WDK') {
        if ((Test-DriverToolchain).Toolset) { break }
        if (-not ($vs -and (Test-Path $setup))) { break }
        Write-Host "Adding Visual Studio component $component ..."
        $p = Start-Process -FilePath $setup -ArgumentList 'modify', '--installPath', "`"$vs`"", '--add', $component, '--quiet', '--norestart' -Wait -PassThru
        Add-Report "- VS installer add ${component}: exit code $($p.ExitCode)"
    }
    if (-not (Test-DriverToolchain).Toolset) {
        # Older WDK releases ship the Visual Studio integration as a VSIX next to the kit.
        $vsix = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\Vsix" -Recurse -Filter 'WDK.vsix' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        $vsixInstaller = if ($vs) { Join-Path $vs 'Common7\IDE\VSIXInstaller.exe' } else { $null }
        if ($vsix -and $vsixInstaller -and (Test-Path $vsixInstaller)) {
            Write-Host "Installing $($vsix.FullName) ..."
            $p = Start-Process -FilePath $vsixInstaller -ArgumentList '/q', '/a', "`"$($vsix.FullName)`"" -Wait -PassThru
            Add-Report "- WDK.vsix install exit code: $($p.ExitCode)"
        }
    }
}

$state = Test-DriverToolchain
Add-Notice 'Driver toolchain after install' "toolset=$($state.Toolset), umdf headers=$($state.Headers)"
if (-not $state.Ok) {
    Write-Host '::error::The WDK could not be made available on this runner image.'
    exit 1
}
exit 0
