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

# Go samples: source plus ready-built programs, so they can be tried without installing Go.
#   go        calls WinUHid.dll and WinUHidDevs.dll
#   go-nodll  talks to the driver directly and needs no DLL
$env:CGO_ENABLED = '0'
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'
$goVersion = (& go version) -join ' '
foreach ($sample in @{ Dir = 'go'; Exe = 'winuhid-sample.exe' }, @{ Dir = 'go-nodll'; Exe = 'winuhid-nodll-sample.exe' }) {
    $src = Join-Path $RepoRoot "examples\$($sample.Dir)"
    $dst = Join-Path $KitDir "examples\$($sample.Dir)"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    Push-Location $src
    try {
        & go vet ./... | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "go vet failed for examples\$($sample.Dir)." }
        & go test ./... | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "go test failed for examples\$($sample.Dir)." }
        & go build -trimpath -o (Join-Path $dst $sample.Exe) . | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "go build failed for examples\$($sample.Dir)." }
    } finally {
        Pop-Location
    }
}
Add-Notice 'Go samples' "built with $goVersion"

# Lets a test report be matched to the exact build it came from.
@(
    "commit $env:GITHUB_SHA",
    "run    $env:GITHUB_RUN_ID",
    "built  $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC",
    'TEST-SIGNED BUILD - FOR TEST MACHINES ONLY'
) | Set-Content -Path (Join-Path $KitDir 'BUILD.txt') -Encoding ascii

$required = 'WinUHid-dev-test-x64.msi', 'WinUHid-dev-test.cer', 'cert-thumbprint.txt', 'install.cmd', 'selftest.cmd',
            'selftest.ps1', 'uninstall.cmd', 'README.txt', 'lib\WinUHid.dll', 'lib\WinUHidDevs.dll', 'include\WinUHid.h',
            'examples\go\winuhid-sample.exe', 'examples\go\main.go', 'examples\go\winuhid\winuhid.go',
            'examples\go-nodll\winuhid-nodll-sample.exe', 'examples\go-nodll\main.go', 'examples\go-nodll\vhid\device.go'
$missing = $required | Where-Object { -not (Test-Path (Join-Path $KitDir $_)) }
if ($missing) { throw "Kit is incomplete, missing: $($missing -join ', ')" }

Add-Report "## Tester kit"
Get-ChildItem -Path $KitDir -Recurse -File | ForEach-Object {
    Add-Report "- $($_.FullName.Substring($KitDir.Length + 1)) ($($_.Length) bytes)"
}
