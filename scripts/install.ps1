# Installs the Infinitus server (`infinitus`) from a GitHub Release archive on
# Windows. Needs only PowerShell 5.1+; no Node, npm, or compiler.
#
# Not yet: Infinitus publishes no Windows server archive, so this script
# says so and stops before fetching anything. The rest is kept for the day
# the release attaches one (#1192).
#
# Environment:
#   T3CODE_CHANNEL           release train to follow: stable, nightly, or preview
#                            (default: stable; preview is a maintainers' test train)
#   T3CODE_VERSION           exact version to install (overrides T3CODE_CHANNEL)
#   T3CODE_HOME              Infinitus home directory (default: ~\.infinitus)
#   T3CODE_INSTALL_BIN_DIR   where infinitus.exe is linked (default: ~\.local\bin)
#   T3CODE_RELEASE_BASE_URL  mirror for releases/download (default: GitHub)
#
# The archive is unpacked into $T3CODE_HOME\runtime\versions\<version>, the
# same layout `infinitus service install` uses, so the service reuses this download.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Fork registration point (INFINITUS.md, #1192): this repo's releases and the
# fork's home, re-applied after every upstream sync.
$repo = "deathemperor/infinitus"
$baseUrl = if ($env:T3CODE_RELEASE_BASE_URL) { $env:T3CODE_RELEASE_BASE_URL.TrimEnd("/") } else { "https://github.com/$repo/releases/download" }
$t3Home = if ($env:T3CODE_HOME) { $env:T3CODE_HOME } else { Join-Path $HOME ".infinitus" }
$binDir = if ($env:T3CODE_INSTALL_BIN_DIR) { $env:T3CODE_INSTALL_BIN_DIR } else { Join-Path $HOME ".local\bin" }

function Fail([string] $message) {
  Write-Error "infinitus install: $message"
  exit 1
}

Fail "Infinitus publishes no Windows server archive yet; use a Linux host (curl -fsSL https://infinitus.run/install.sh | sh) or the macOS desktop app"

# PROCESSOR_ARCHITEW6432 reports the real machine when a 32-bit PowerShell
# runs under WOW64; RuntimeInformation needs .NET 4.7.1+, which 5.1 hosts
# may lack.
$rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($rawArch) {
  "AMD64" { "x64" }
  "ARM64" { "arm64" }
  default { Fail "unsupported architecture $rawArch" }
}

$channel = if ($env:T3CODE_CHANNEL) { $env:T3CODE_CHANNEL } else { "stable" }
$version = $env:T3CODE_VERSION
if (-not $version) {
  # Tags are v<semver>; the channel is the prerelease identifier, or none for
  # stable. Only tags of the requested train are considered, so a stable
  # install can never pick up a nightly or preview build by accident.
  $tagPattern = switch ($channel) {
    "stable" { '^v\d+\.\d+\.\d+$' }
    "nightly" { '^v\d+\.\d+\.\d+-nightly\.\d+\.\d+$' }
    "preview" { '^v\d+\.\d+\.\d+-preview\.\d+\.\d+$' }
    default { Fail "T3CODE_CHANNEL must be stable, nightly, or preview" }
  }
  $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=100" -Headers @{ "User-Agent" = "infinitus-install" }
  $tag = ($releases | Where-Object { -not $_.draft -and $_.tag_name -match $tagPattern } | Select-Object -First 1).tag_name
  if (-not $tag) { Fail "could not find a $channel release; set T3CODE_VERSION" }
  $version = $tag.Substring(1)
}
if ($version -match '-preview\.') {
  Write-Warning "infinitus $version is a preview build. Preview builds are cut by maintainers from unreleased branches to exercise the release pipeline. They can be broken, receive no fixes, and are never offered as updates. Set T3CODE_CHANNEL=stable (the default) for a supported build."
  if ($channel -ne "preview" -and -not $env:T3CODE_VERSION) {
    Fail "refusing a preview build that was not explicitly requested"
  }
}

$stem = "infinitus-$version-win32-$arch"
$archive = "$stem.zip"
$versionsDir = Join-Path $t3Home "runtime\versions"
$targetDir = Join-Path $versionsDir $version
$marker = Join-Path $targetDir ".install-complete"

if ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $version)) {
  Write-Host "infinitus $version is already installed at $targetDir"
} else {
  New-Item -ItemType Directory -Force -Path $versionsDir | Out-Null
  $staging = Join-Path $versionsDir (".staging-" + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    Write-Host "Downloading $archive..."
    try {
      Invoke-WebRequest -Uri "$baseUrl/v$version/SHA256SUMS" -OutFile (Join-Path $staging "SHA256SUMS") -UseBasicParsing
    } catch {
      $status = $_.Exception.Response.StatusCode.value__
      if ($status -eq 404) {
        Fail "infinitus $version has no release archive for win32-$arch; releases before the self-contained CLI can only be installed with 'npm install -g infinitus@$version'"
      }
      throw
    }
    Invoke-WebRequest -Uri "$baseUrl/v$version/$archive" -OutFile (Join-Path $staging $archive) -UseBasicParsing

    $expected = (Get-Content (Join-Path $staging "SHA256SUMS") | Where-Object { $_ -match "\s\*?$([regex]::Escape($archive))$" } | Select-Object -First 1)
    if (-not $expected) { Fail "$archive is not listed in SHA256SUMS" }
    $expected = ($expected -split "\s+")[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $staging $archive)).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { Fail "checksum mismatch for $archive" }

    Expand-Archive -Path (Join-Path $staging $archive) -DestinationPath $staging -Force
    # The archive wraps everything in one directory named after its stem.
    Get-ChildItem (Join-Path $staging $stem) | Move-Item -Destination $staging
    Remove-Item (Join-Path $staging $stem), (Join-Path $staging $archive), (Join-Path $staging "SHA256SUMS") -Recurse -Force

    & (Join-Path $staging "infinitus.exe") --version | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "the downloaded executable does not run" }
    Set-Content -Path (Join-Path $staging ".install-complete") -Value $version -NoNewline

    if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
    Move-Item $staging $targetDir
  } catch {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    throw
  }
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$shim = Join-Path $binDir "infinitus.cmd"
# UTF-8 without a BOM: cmd.exe reads the shim as-is, and ASCII would corrupt
# non-ASCII characters in the user's home path.
[System.IO.File]::WriteAllText($shim, "@echo off`r`n`"$(Join-Path $targetDir 'infinitus.exe')`" %*", (New-Object System.Text.UTF8Encoding $false))
Write-Host "Installed infinitus $version"
Write-Host "  $shim -> $(Join-Path $targetDir 'infinitus.exe')"
if (($env:PATH -split ";") -notcontains $binDir) {
  Write-Host "Add $binDir to your PATH to run infinitus."
}
