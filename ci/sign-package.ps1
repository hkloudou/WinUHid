# Signs the driver package (driver DLL + catalog) with the throwaway test certificate
# and checks that every file in the package is covered by the signed catalog.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Stop'

$configuration = if ($env:CONFIGURATION) { $env:CONFIGURATION } else { 'Release' }
$platform      = if ($env:PLATFORM) { $env:PLATFORM } else { 'x64' }
$thumbprint    = $env:TEST_CERT_THUMBPRINT
if (-not $thumbprint) { throw 'TEST_CERT_THUMBPRINT is not set; run new-test-cert.ps1 first.' }

$targetDir = Join-Path $RepoRoot "build\$configuration\$platform"
$pkgDir    = Join-Path $targetDir 'WinUHid Driver'

Add-Report "## Driver package"
if (-not (Test-Path $pkgDir)) {
    Add-Report "Package directory not found: $pkgDir"
    Get-ChildItem -Path $targetDir -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Add-Report "  $($_.FullName)" }
    throw 'Driver package directory is missing.'
}
Get-ChildItem -Path $pkgDir -Recurse -File | ForEach-Object { Add-Report "- $($_.Name) ($($_.Length) bytes)" }

$inf = Get-ChildItem -Path $pkgDir -Filter *.inf | Select-Object -First 1
if (-not $inf) { throw 'No INF in the driver package.' }
$infText = Get-Content -Path $inf.FullName -Raw
$umdfVersion = if ($infText -match '(?im)^\s*UmdfLibraryVersion\s*=\s*(\S+)') { $Matches[1] } else { '?' }
$driverVer   = if ($infText -match '(?im)^\s*DriverVer\s*=\s*([^;\r\n]+)') { $Matches[1].Trim() } else { '?' }
Add-Notice 'INF' "UmdfLibraryVersion=$umdfVersion, DriverVer=$driverVer"
if ($infText -match '\$(ARCH|UMDFVERSION|KMDFVERSION)\$') {
    Add-Notice 'INF warning' 'INF still contains unexpanded $...$ macros (stampinf did not run).'
}

$signtool = Find-KitTool 'signtool.exe' 'x64'
if (-not $signtool) { throw 'signtool.exe not found.' }

function Invoke-Sign {
    param([string]$File)
    & $signtool sign /fd SHA256 /sha1 $thumbprint /s My /tr http://timestamp.digicert.com /td SHA256 $File | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Timestamped signing failed for $File, retrying without a timestamp."
        & $signtool sign /fd SHA256 /sha1 $thumbprint /s My $File | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "signtool failed for $File" }
        return 'signed (no timestamp)'
    }
    return 'signed + timestamped'
}

function New-PackageCatalog {
    # Used only when the build did not leave a usable catalog behind.
    Get-ChildItem -Path $pkgDir -Filter *.cat | Remove-Item -Force
    $catName = if ($infText -match '(?im)^\s*CatalogFile(\.\w+)?\s*=\s*(\S+)') { $Matches[2] } else { 'WinUHidDriver.cat' }
    $inf2cat = Find-KitTool 'Inf2Cat.exe' 'x86'
    if ($inf2cat) {
        & $inf2cat "/driver:$pkgDir" /os:10_X64 /uselocaltime | Out-Host
        if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $pkgDir $catName))) { return 'Inf2Cat' }
        Write-Host "Inf2Cat failed (exit $LASTEXITCODE), falling back to New-FileCatalog."
    }
    $tmp = Join-Path $env:TEMP $catName
    Remove-Item $tmp -ErrorAction SilentlyContinue
    New-FileCatalog -Path $pkgDir -CatalogFilePath $tmp -CatalogVersion 2.0 | Out-Null
    Move-Item -Path $tmp -Destination (Join-Path $pkgDir $catName) -Force
    return 'New-FileCatalog'
}

# The test certificate must be a trusted root on this machine for verification to succeed.
# A tester has to do the same on the test machine before installing the MSI.
Add-CertToMachineStore -CerPath (Join-Path $OutDir 'WinUHid-dev-test.cer') -StoreName 'Root'

# 1. Binaries first: an embedded signature does not change the hash a catalog records for a PE file.
foreach ($dll in Get-ChildItem -Path $pkgDir -Recurse -Filter *.dll) {
    Add-Report "- $($dll.Name): $(Invoke-Sign $dll.FullName)"
}

# 2. Catalog: keep the one produced by the WDK build if there is one.
$cat = Get-ChildItem -Path $pkgDir -Filter *.cat | Select-Object -First 1
$catSource = 'WDK build'
if (-not $cat) {
    $catSource = New-PackageCatalog
    $cat = Get-ChildItem -Path $pkgDir -Filter *.cat | Select-Object -First 1
}
Add-Report "- $($cat.Name): $(Invoke-Sign $cat.FullName)"

function Test-PackageAgainstCatalog {
    $allOk = $true
    foreach ($file in Get-ChildItem -Path $pkgDir -Recurse -File | Where-Object { $_.Extension -ne '.cat' }) {
        & $signtool verify /pa /c $cat.FullName $file.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) { $allOk = $false; Write-Host "Not covered by catalog: $($file.Name)" }
    }
    return $allOk
}

$covered = Test-PackageAgainstCatalog
if (-not $covered) {
    Write-Host 'Catalog does not cover the package; regenerating it.'
    $catSource = New-PackageCatalog
    $cat = Get-ChildItem -Path $pkgDir -Filter *.cat | Select-Object -First 1
    Add-Report "- $($cat.Name) (regenerated): $(Invoke-Sign $cat.FullName)"
    $covered = Test-PackageAgainstCatalog
}

$sig = Get-AuthenticodeSignature -FilePath $cat.FullName
Add-Notice 'Catalog signature' "source=$catSource, status=$($sig.Status), signer=$($sig.SignerCertificate.Thumbprint), covers all files=$covered"
if (-not $covered -or $sig.SignerCertificate.Thumbprint -ne $thumbprint) {
    throw 'The driver package is not correctly signed.'
}
