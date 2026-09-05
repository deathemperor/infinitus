# Build the Windows daemon. Works from any directory; run unblocked:
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    . (Join-Path $PSScriptRoot "env.ps1")
    # ONE --product per invocation — SwiftPM builds only the last of two.
    swift build --product infinitus-win
    exit $LASTEXITCODE
}
finally { Pop-Location }
