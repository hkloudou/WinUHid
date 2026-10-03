# Records what the build machine looks like, so a failed build can be diagnosed from the report alone.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

Add-MachineReport

Add-Report "## Toolchain"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $instances = & $vswhere -all -products * -format json | ConvertFrom-Json
    foreach ($i in $instances) {
        Add-Report "- Visual Studio: $($i.displayName) $($i.installationVersion) at $($i.installationPath)"
        $toolsets = Get-ChildItem -Path "$($i.installationPath)\MSBuild\Microsoft\VC\*\Platforms\x64\PlatformToolsets\*" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name } | Sort-Object -Unique
        Add-Report "  - x64 platform toolsets: $($toolsets -join ', ')"
    }
} else {
    Add-Report "- vswhere.exe not found"
}

$kits = "${env:ProgramFiles(x86)}\Windows Kits\10"
$sdks = Get-ChildItem -Path "$kits\Include" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
Add-Report "- Windows Kits include versions: $($sdks -join ', ')"
$umdf = Get-ChildItem -Path "$kits\Include\wdf\umdf" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
Add-Report "- UMDF header versions: $($umdf -join ', ')"
foreach ($tool in 'signtool.exe', 'Inf2Cat.exe', 'stampinf.exe') {
    $arch = if ($tool -eq 'Inf2Cat.exe') { 'x86' } else { 'x64' }
    Add-Report "- ${tool}: $(Find-KitTool $tool $arch)"
}

$state = Test-DriverToolchain
Add-Notice 'Driver toolchain present' "toolset=$($state.Toolset), umdf headers=$($state.Headers)"
