# Builds the installer from the already-signed driver package, then opens the MSI
# and checks that the catalog inside it is the one signed by the test certificate.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

$thumbprint = $env:TEST_CERT_THUMBPRINT
$project    = 'Installer\WinUHid Package\WinUHid Package.wixproj'

# Old installer outputs would make it impossible to tell which MSI this build produced.
Get-ChildItem -Path $RepoRoot -Recurse -Filter *.msi -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "$OutDir*" } | Remove-Item -Force

# Referenced projects are already built and signed; rebuilding them here could replace the signed catalog.
& "$PSScriptRoot/msbuild-project.ps1" -Project $project -LogName '04-msi' -Extra '/p:BuildProjectReferences=false'
if ($LASTEXITCODE -ne 0) {
    Add-Report '- MSI build without rebuilding references failed; retrying with references.'
    & "$PSScriptRoot/msbuild-project.ps1" -Project $project -LogName '04-msi-with-references' -Extra '/p:SignMode=Off'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$msi = Get-ChildItem -Path $RepoRoot -Recurse -Filter *.msi |
    Where-Object { $_.FullName -notlike "$OutDir*" } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $msi) {
    Write-Host '::error::The build finished but no MSI was produced.'
    exit 1
}
$finalMsi = Join-Path $KitDir 'WinUHid-dev-test-x64.msi'
Copy-Item -Path $msi.FullName -Destination $finalMsi -Force
Add-Report "## Installer"
Add-Report "- Built: $($msi.FullName) ($($msi.Length) bytes)"

# Administrative install = unpack only; no custom actions, nothing is installed.
$extract = Join-Path $env:RUNNER_TEMP 'msi-extract'
Remove-Item -Path $extract -Recurse -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath msiexec.exe -ArgumentList '/a', "`"$finalMsi`"", '/qn', "TARGETDIR=`"$extract`"" -Wait -PassThru
if ($p.ExitCode -ne 0) {
    Add-Notice 'MSI content check' "could not unpack the MSI (msiexec exit $($p.ExitCode))"
    exit 1
}

$files = Get-ChildItem -Path $extract -Recurse -File | Where-Object { $_.Extension -ne '.msi' }
$files | ForEach-Object { Add-Report "- in MSI: $($_.Name) ($($_.Length) bytes)" }
$cat = $files | Where-Object { $_.Extension -eq '.cat' } | Select-Object -First 1
if (-not $cat) {
    Add-Notice 'MSI content check' 'no catalog file inside the MSI'
    exit 1
}
$sig = Get-AuthenticodeSignature -FilePath $cat.FullName
$match = ($sig.SignerCertificate.Thumbprint -eq $thumbprint)
Add-Notice 'MSI content check' "catalog in MSI: status=$($sig.Status), signed by this build's test certificate=$match"
if (-not $match) { exit 1 }
exit 0
