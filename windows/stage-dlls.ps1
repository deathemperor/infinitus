# Stages the Swift runtime DLLs a built binary needs next to it, so the
# .exe runs without env.ps1 on PATH.
#
# Used by install.ps1 for a release install, and directly against
# .build\debug for the dev loop — a debug binary that is not staged dies
# with 0xC0000135 (STATUS_DLL_NOT_FOUND) and no message at all.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File windows\stage-dlls.ps1 `
#       -TargetDir .build\debug [-RuntimeBin <path>] [-Debug]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [string]$RuntimeBin,
    # Adds the unoptimized-stdlib shim. Inferred from the target path when
    # not passed, so `-TargetDir .build\debug` needs no second flag.
    [switch]$DebugBuild
)

$ErrorActionPreference = "Stop"

if (-not $RuntimeBin) {
    $candidates = @(
        "C:\Users\BM\AppData\Local\Programs\Swift\Runtimes\6.3.3\usr\bin",
        (Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes\6.3.3\usr\bin")
    )
    $RuntimeBin = $candidates | Where-Object { Test-Path (Join-Path $_ "swiftCore.dll") } | Select-Object -First 1
    if (-not $RuntimeBin) {
        $base = Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"
        if (Test-Path $base) {
            $RuntimeBin = Get-ChildItem $base -Directory |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "usr\bin" } |
                Where-Object { Test-Path (Join-Path $_ "swiftCore.dll") } |
                Select-Object -First 1
        }
    }
}
if (-not $RuntimeBin -or -not (Test-Path $RuntimeBin)) {
    throw "Swift runtime bin not found. Pass -RuntimeBin explicitly."
}

# Transitive dependency closure determined via dumpbin /dependents.
$dlls = @(
    "_FoundationICU.dll",
    "BlocksRuntime.dll",
    "dispatch.dll",
    "Foundation.dll",
    "FoundationEssentials.dll",
    "FoundationInternationalization.dll",
    "FoundationNetworking.dll",
    "MSVCP140.dll",
    "swift_Concurrency.dll",
    "swift_RegexParser.dll",
    "swift_StringProcessing.dll",
    "swiftCore.dll",
    "swiftCRT.dll",
    "swiftDispatch.dll",
    "swiftWinSDK.dll",
    "VCRUNTIME140.dll",
    "VCRUNTIME140_1.dll"
)

# A debug build is -Onone and imports the unoptimized-stdlib shim; a
# release build never does. Verified by bisection 2026-09-04: with the 17
# release DLLs staged and this one absent, the debug daemon and tray both
# exit 0xC0000135 silently.
if ($DebugBuild -or (Split-Path $TargetDir -Leaf) -eq "debug") {
    $dlls += "swiftSwiftOnoneSupport.dll"
}

if (-not (Test-Path $TargetDir)) {
    throw "Target directory not found: $TargetDir"
}

$copied = 0
$same = 0
$locked = @()
$missing = @()
foreach ($dll in $dlls) {
    $src = Join-Path $RuntimeBin $dll
    if (-not (Test-Path $src)) { $missing += $dll; continue }
    $dst = Join-Path $TargetDir $dll
    # A running tray or daemon holds its DLLs open, so an unconditional
    # copy fails on a re-stage. The bytes never change for a given
    # toolchain, so an identical file is already staged — skip it, and
    # only report a lock when the content actually differs.
    if (Test-Path $dst) {
        $s = Get-Item $src; $d = Get-Item $dst
        if ($s.Length -eq $d.Length -and $s.LastWriteTimeUtc -eq $d.LastWriteTimeUtc) {
            $same++
            continue
        }
    }
    try {
        Copy-Item $src $dst -Force
        $copied++
    } catch [System.IO.IOException] {
        $locked += $dll
    }
}

Write-Host "Staged $copied DLLs into $TargetDir ($same already current)"
if ($locked.Count -gt 0) {
    Write-Warning ("In use, not replaced (stop infinitus-win / infinitus-tray-win first): " +
                   ($locked -join ", "))
}
if ($missing.Count -gt 0) {
    Write-Warning ("Runtime DLLs not found in ${RuntimeBin}: " + ($missing -join ", "))
}
