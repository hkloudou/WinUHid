# Creates a throwaway self-signed code signing certificate for this build only.
# It is valid for 100 years on purpose: a test build must never stop working because of a date,
# which would only confuse whoever picks this up later. It is still a test certificate.
# The private key stays in the runner's certificate store and disappears with the runner.
# The public certificate replaces the upstream author's certificate that the installer embeds.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Stop'

$runId   = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { 'local' }
$subject = "CN=WinUHid Dev Test $runId, O=Test signing only - not for production"

$created = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
    -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 3072 `
    -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(100)
$thumbprint = $created.Thumbprint

# Re-read through the provider so the rest does not depend on how the PKI module returned the object.
$cert  = Get-Item "Cert:\CurrentUser\My\$thumbprint"
$bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

$embedded = Join-Path $RepoRoot 'Installer\WinUHid Package\WinUHidCertificate.cer'
$public   = Join-Path $KitDir 'WinUHid-dev-test.cer'
[System.IO.File]::WriteAllBytes($embedded, $bytes)
[System.IO.File]::WriteAllBytes($public, $bytes)
# The tester's uninstall script uses this to remove exactly this certificate again.
Set-Content -Path (Join-Path $KitDir 'cert-thumbprint.txt') -Value $thumbprint -Encoding ascii

if ($env:GITHUB_ENV) {
    Add-Content -Path $env:GITHUB_ENV -Value "TEST_CERT_THUMBPRINT=$thumbprint"
}
$env:TEST_CERT_THUMBPRINT = $thumbprint

Add-Report "## Signing certificate"
Add-Notice 'Test certificate' "$($cert.Subject) / thumbprint $thumbprint / valid until $($cert.NotAfter.ToString('yyyy-MM-dd'))"
