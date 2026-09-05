# windows/ci.ps1 — Continuous integration script for Windows.
# Builds both products (one --product per invocation per CLAUDE.md) and runs the test suite.
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    . (Join-Path $PSScriptRoot "env.ps1")

    Write-Host "==> Building infinitus-win..."
    swift build --product infinitus-win
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "==> Building infinitus-tray-win..."
    swift build --product infinitus-tray-win
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "==> Running test suite..."
    swift test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "==> CI completed successfully."
    exit 0
}
finally {
    Pop-Location
}
