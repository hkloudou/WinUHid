# Puts together the folder a tester downloads: installer, certificate, scripts, libraries, headers.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Stop'

$configuration = if ($env:CONFIGURATION) { $env:CONFIGURATION } else { 'Release' }
$platform      = if ($env:PLATFORM) { $env:PLATFORM } else { 'x64' }
$bin           = Join-Path $RepoRoot "build\$configuration\$platform"

Copy-Item -Path (Join-Path $PSScriptRoot 'kit\*') -Destination $KitDir -Force

New-Item -ItemType Directory -Force -Path (Join-Path $KitDir 'lib'), (Join-Path $KitDir 'include') | Out-Null
foreach ($name in 'WinUHid.dll', 'WinUHid.lib', 'WinUHidDevs.dll', 'WinUHidDevs.lib') {
    Copy-Item -Path (Join-Path $bin $name) -Destination (Join-Path $KitDir 'lib')
}
Copy-Item -Path (Join-Path $RepoRoot 'WinUHid\WinUHid.h') -Destination (Join-Path $KitDir 'include')
Get-ChildItem -Path (Join-Path $RepoRoot 'WinUHidDevs') -Filter 'WinUHid*.h' |
    Copy-Item -Destination (Join-Path $KitDir 'include')

# Lets a test report be matched to the exact build it came from.
@(
    "commit $env:GITHUB_SHA",
    "run    $env:GITHUB_RUN_ID",
    "built  $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC",
    'TEST-SIGNED BUILD - FOR TEST MACHINES ONLY'
) | Set-Content -Path (Join-Path $KitDir 'BUILD.txt') -Encoding ascii

$required = 'WinUHid-dev-test-x64.msi', 'WinUHid-dev-test.cer', 'cert-thumbprint.txt', 'install.cmd', 'selftest.cmd',
            'selftest.ps1', 'uninstall.cmd', 'README.txt', 'lib\WinUHid.dll', 'lib\WinUHidDevs.dll', 'include\WinUHid.h'
$missing = $required | Where-Object { -not (Test-Path (Join-Path $KitDir $_)) }
if ($missing) { throw "Kit is incomplete, missing: $($missing -join ', ')" }

Add-Report "## Tester kit"
Get-ChildItem -Path $KitDir -Recurse -File | ForEach-Object {
    Add-Report "- $($_.FullName.Substring($KitDir.Length + 1)) ($($_.Length) bytes)"
}
