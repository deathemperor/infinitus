# Release build + install for Infinitus Windows binaries.
# Usage:
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 [-Autostart] [-Uninstall]
#
# Copies infinitus-win.exe, infinitus-tray-win.exe, and required Swift runtime DLLs
# into $env:LOCALAPPDATA\Infinitus\bin so the binaries run without sourcing env.ps1.

[CmdletBinding()]
param(
    [switch]$Autostart,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$installDir = Join-Path $env:LOCALAPPDATA "Infinitus\bin"
$runRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueName = "Infinitus Tray"
$trayInstalledExe = Join-Path $installDir "infinitus-tray-win.exe"

# Stop running processes originating from the target install directory or debug tray
function Stop-InstalledProcesses {
    param([string]$TargetDir)

    # Always check for running infinitus-tray-win (safe to restart)
    $trayProcs = Get-Process -Name "infinitus-tray-win" -ErrorAction SilentlyContinue
    foreach ($p in $trayProcs) {
        Write-Host "Stopping running tray process (PID $($p.Id))..."
        Stop-Process -Id $p.Id -Force
        $p.WaitForExit(5000)
    }

    # For infinitus-win, stop only if running from the target install directory
    if (Test-Path $TargetDir) {
        $daemonProcs = Get-Process -Name "infinitus-win" -ErrorAction SilentlyContinue
        foreach ($p in $daemonProcs) {
            try {
                $procPath = $p.MainModule.FileName
                if ($procPath -like "$TargetDir\*") {
                    Write-Host "Stopping installed daemon process (PID $($p.Id))..."
                    Stop-Process -Id $p.Id -Force
                    $p.WaitForExit(5000)
                }
            } catch {
                # In case MainModule is inaccessible, leave it alone
            }
        }
    }
}

if ($Uninstall) {
    Write-Host "Uninstalling Infinitus..."
    Stop-InstalledProcesses -TargetDir $installDir

    # Remove Run key if present
    $prop = Get-ItemProperty -Path $runRegPath -Name $runValueName -ErrorAction SilentlyContinue
    if ($null -ne $prop) {
        Remove-ItemProperty -Path $runRegPath -Name $runValueName -ErrorAction SilentlyContinue
        Write-Host "Removed HKCU Run key: $runValueName"
    }

    # Remove install dir
    if (Test-Path $installDir) {
        Remove-Item -Recurse -Force $installDir
        Write-Host "Removed install directory: $installDir"
    }

    # Clean up parent directory if empty
    $parentDir = Split-Path $installDir -Parent
    if ((Test-Path $parentDir) -and ((Get-ChildItem $parentDir).Count -eq 0)) {
        Remove-Item -Force $parentDir -ErrorAction SilentlyContinue
    }

    Write-Host "Uninstall complete."
    exit 0
}

# Locate Swift runtime bin dir
$runtimeBin = $null
$possibleRuntimeDirs = @(
    "C:\Users\BM\AppData\Local\Programs\Swift\Runtimes\6.3.3\usr\bin",
    (Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes\6.3.3\usr\bin")
)

# Also check any installed Swift versions
$baseRuntime = Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes"
if (Test-Path $baseRuntime) {
    $found = Get-ChildItem $baseRuntime -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($found) {
        $possibleRuntimeDirs += (Join-Path $found.FullName "usr\bin")
    }
}

foreach ($dir in $possibleRuntimeDirs) {
    if (Test-Path (Join-Path $dir "swiftCore.dll")) {
        $runtimeBin = $dir
        break
    }
}

if (-not $runtimeBin) {
    throw "Swift runtime directory not found. Please verify Swift toolchain installation."
}

# Build release binaries
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    Write-Host "Sourcing Swift environment..."
    . (Join-Path $PSScriptRoot "env.ps1")

    Write-Host "Building release infinitus-win..."
    # ONE --product per invocation — SwiftPM builds only the last of two.
    swift build -c release --product infinitus-win
    if ($LASTEXITCODE -ne 0) { throw "Build failed for infinitus-win" }

    Write-Host "Building release infinitus-tray-win..."
    swift build -c release --product infinitus-tray-win
    if ($LASTEXITCODE -ne 0) { throw "Build failed for infinitus-tray-win" }
}
finally {
    Pop-Location
}

# Ensure target directory exists
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# Stop any running tray or installed daemon before copying
Stop-InstalledProcesses -TargetDir $installDir

Write-Host "Copying release binaries to $installDir..."
$releaseDir = Join-Path $root ".build\release"
Copy-Item (Join-Path $releaseDir "infinitus-win.exe") $installDir -Force
Copy-Item (Join-Path $releaseDir "infinitus-tray-win.exe") $installDir -Force

Write-Host "Copying Swift runtime DLLs from $runtimeBin..."
& (Join-Path $PSScriptRoot "stage-dlls.ps1") -RuntimeBin $runtimeBin -TargetDir $installDir

if ($Autostart) {
    Write-Host "Configuring autostart in HKCU Run..."
    $quotedVal = "`"$trayInstalledExe`""
    Set-ItemProperty -Path $runRegPath -Name $runValueName -Value $quotedVal -Type String
    Write-Host "Autostart configured: $runValueName -> $quotedVal"
}

Write-Host "`nInstall completed successfully to $installDir"
