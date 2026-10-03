# Publishes the report and the tails of the logs to a results branch, one per runner image.
# This gives a way to read a run's outcome with plain git, without the Actions UI.
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Continue'

$label  = if ($env:RESULT_LABEL) { $env:RESULT_LABEL } else { 'local' }
$branch = "ci-results/$label"
$work   = Join-Path $env:RUNNER_TEMP 'ci-results'
Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work, (Join-Path $work 'logs') | Out-Null

$header = @(
    "# CI results: $label",
    '',
    "- Commit: $env:GITHUB_SHA",
    "- Branch: $env:GITHUB_REF_NAME",
    "- Run: $env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID (attempt $env:GITHUB_RUN_ATTEMPT)",
    "- Job status: $env:JOB_STATUS",
    "- Finished (UTC): $((Get-Date).ToUniversalTime().ToString('s'))",
    ''
)
$body = if (Test-Path $ReportFile) { Get-Content -Path $ReportFile } else { @('(no report was written)') }
($header + $body) | Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8

# Tails only: enough to diagnose a failure, small enough to read.
Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    Get-Content -Path $_.FullName -Tail 300 -ErrorAction SilentlyContinue |
        Set-Content -Path (Join-Path $work "logs\$($_.Name)") -Encoding utf8
}

Push-Location $work
try {
    git init -q -b results
    git add -A
    git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' `
        commit -q -m "CI results for $env:GITHUB_SHA on $label (run $env:GITHUB_RUN_ID)"
    $remote = "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$($env:GITHUB_REPOSITORY).git"
    git push --force --quiet $remote "HEAD:refs/heads/$branch"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::warning::Could not push results to $branch (exit $LASTEXITCODE)."
    } else {
        Write-Host "Results pushed to $branch"
    }
} finally {
    Pop-Location
}
exit 0
