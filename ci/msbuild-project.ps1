# Builds one project the way the solution would, and keeps a text log for the report.
param(
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$LogName,
    [string[]]$Extra = @()
)
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

$configuration = if ($env:CONFIGURATION) { $env:CONFIGURATION } else { 'Release' }
$platform      = if ($env:PLATFORM) { $env:PLATFORM } else { 'x64' }

$msbuildArgs = @(
    (Join-Path $RepoRoot $Project),
    "/p:Configuration=$configuration",
    "/p:Platform=$platform",
    "/p:SolutionDir=$RepoRoot\",
    '/m', '/nologo', '/v:minimal',
    "/flp:LogFile=$LogDir\$LogName.log;Verbosity=normal;Encoding=UTF-8"
) + $Extra

Write-Host "msbuild $($msbuildArgs -join ' ')"
& msbuild @msbuildArgs
$code = $LASTEXITCODE

if ($code -ne 0) {
    $errors = Select-String -Path "$LogDir\$LogName.log" -Pattern '(: |\s)(fatal )?error ' -ErrorAction SilentlyContinue |
        Select-Object -First 8 | ForEach-Object { $_.Line.Trim() }
    Add-Notice "Build $LogName" "FAILED (exit $code)`n$($errors -join "`n")"
    exit $code
}
Add-Notice "Build $LogName" 'ok'
exit 0
