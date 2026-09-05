# windows/smoke.ps1 — Scripted integration acceptance for Infinitus on Windows (W18).
# Runs against a dedicated daemon instance on a spare port (default 47832) to ensure
# any running daemon on 47824 is never disturbed.

param(
    [int]$Port = 47832
)

$ErrorActionPreference = "Stop"

# Ensure Swift toolchain and SDK environment are available in this session
$envScript = Join-Path $PSScriptRoot "env.ps1"
if (Test-Path $envScript) {
    . $envScript
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$exePath = Join-Path $repoRoot ".build\debug\infinitus-win.exe"

if (-not (Test-Path $exePath)) {
    Write-Error "infinitus-win.exe not found at $exePath. Run windows\build.ps1 first."
    exit 1
}

Add-Type -AssemblyName System.Net.Http

$passCount = 0
$failCount = 0

function Report-Pass([string]$name) {
    $script:passCount++
    Write-Host "PASS: $name"
}

function Report-Fail([string]$name, [string]$reason) {
    $script:failCount++
    Write-Host "FAIL: $name - $reason"
}

# Use an isolated pairing token so the test doesn't mutate or depend on the user's token file
$testToken = "SMOKETESTTOKEN0123456789"
$tokenFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tokenFile -Value $testToken -NoNewline

$daemonProc = $null
$httpClient = [System.Net.Http.HttpClient]::new()

try {
    # -------------------------------------------------------------------------
    # 1. Daemon startup on spare port
    # -------------------------------------------------------------------------
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exePath
    $psi.Arguments = "serve --port $Port --token-file `"$tokenFile`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Ensure subprocess inherits PATH with Swift runtimes
    $psi.EnvironmentVariables["Path"] = $env:Path

    $daemonProc = [System.Diagnostics.Process]::Start($psi)

    # Wait for daemon to bind and listen (up to 5 seconds)
    $listening = $false
    $deadline = [System.DateTime]::UtcNow.AddSeconds(5)
    while ([System.DateTime]::UtcNow -lt $deadline) {
        if ($daemonProc.HasExited) {
            break
        }
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $connectAsync = $tcp.ConnectAsync("127.0.0.1", $Port)
            if ($connectAsync.Wait(200)) {
                $listening = $true
                $tcp.Close()
                break
            }
            $tcp.Close()
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($listening -and -not $daemonProc.HasExited) {
        Report-Pass "Daemon started and listening on spare port $Port (PID $($daemonProc.Id))"
    } else {
        $errOut = if ($daemonProc.HasExited) { $daemonProc.StandardError.ReadToEnd() } else { "timed out" }
        Report-Fail "Daemon started and listening on spare port $Port" "Failed to start: $errOut"
        exit 1
    }

    $baseURL = "http://127.0.0.1:$Port"

    # -------------------------------------------------------------------------
    # 2. Authentication: 401 without token; 200 with Bearer header and ?t= query
    # -------------------------------------------------------------------------
    $noAuthResp = $httpClient.GetAsync("$baseURL/snapshot").Result
    $noAuthStatus = [int]$noAuthResp.StatusCode

    $reqHeader = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$baseURL/snapshot")
    $reqHeader.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
    $authHeaderResp = $httpClient.SendAsync($reqHeader).Result
    $authHeaderStatus = [int]$authHeaderResp.StatusCode

    $authQueryResp = $httpClient.GetAsync("$baseURL/snapshot?t=$testToken").Result
    $authQueryStatus = [int]$authQueryResp.StatusCode

    if ($noAuthStatus -eq 401 -and $authHeaderStatus -eq 200 -and $authQueryStatus -eq 200) {
        Report-Pass "Authentication: 401 without token, 200 with Authorization: Bearer, 200 with ?t= query"
    } else {
        Report-Fail "Authentication" "Expected (401, 200, 200) got ($noAuthStatus, $authHeaderStatus, $authQueryStatus)"
    }

    # -------------------------------------------------------------------------
    # 3. Snapshot: decodes, has machineName + a fleet + liveSessions.total >= 1
    # -------------------------------------------------------------------------
    $snapshotBody = $authHeaderResp.Content.ReadAsStringAsync().Result
    $snapshot = $null
    try {
        $snapshot = ConvertFrom-Json $snapshotBody
    } catch {
        $snapshot = $null
    }

    if ($snapshot -and `
        -not [string]::IsNullOrEmpty($snapshot.machineName) -and `
        $snapshot.fleets -and $snapshot.fleets.Count -ge 1 -and `
        $snapshot.fleets[0].liveSessions.total -ge 1) {
        Report-Pass "Snapshot: decodes with machineName ($($snapshot.machineName)), fleets ($($snapshot.fleets.Count)), and liveSessions.total >= 1 ($($snapshot.fleets[0].liveSessions.total))"
    } else {
        Report-Fail "Snapshot" "Payload missing machineName, fleet, or liveSessions.total >= 1"
    }

    # -------------------------------------------------------------------------
    # 4. Feed tail: /sessions/<pid>/tail returns items for live session,
    #    carries canMessage, keys, permissionMode
    # -------------------------------------------------------------------------
    # Pick a live interactive session (excluding 24928 which is the orchestrator's session)
    $candidateSessions = @()
    if ($snapshot -and $snapshot.fleets -and $snapshot.fleets[0].liveSessions.sessions) {
        $candidateSessions = $snapshot.fleets[0].liveSessions.sessions | Where-Object { $_.pid -ne 24928 }
    }
    $targetPid = if ($candidateSessions.Count -gt 0) { $candidateSessions[0].pid } else { $null }

    $tailData = $null
    if ($targetPid) {
        $tailReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$baseURL/sessions/$targetPid/tail")
        $tailReq.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
        $tailResp = $httpClient.SendAsync($tailReq).Result

        if ([int]$tailResp.StatusCode -eq 200) {
            $tailData = ConvertFrom-Json $tailResp.Content.ReadAsStringAsync().Result
            $hasItems = $tailData.items -ne $null
            $hasCanMessage = $tailData.PSObject.Properties['canMessage'] -ne $null
            $hasKeys = $tailData.PSObject.Properties['keys'] -ne $null
            $hasPermMode = $tailData.PSObject.Properties['permissionMode'] -ne $null

            if ($hasItems -and $hasCanMessage -and $hasKeys -and $hasPermMode) {
                Report-Pass "Feed tail: /sessions/$targetPid/tail returned items ($($tailData.items.Count)), canMessage ($($tailData.canMessage)), keys ($($tailData.keys)), permissionMode ($($tailData.permissionMode))"
            } else {
                Report-Fail "Feed tail" "Missing required fields (items: $hasItems, canMessage: $hasCanMessage, keys: $hasKeys, permissionMode: $hasPermMode)"
            }
        } else {
            Report-Fail "Feed tail" "HTTP $([int]$tailResp.StatusCode) for pid $targetPid"
        }
    } else {
        Report-Fail "Feed tail" "No candidate live session PID found (excluding 24928)"
    }

    # -------------------------------------------------------------------------
    # 5. Long-poll: stale since returns fast (< 1s); current since holds ~wait
    #    (wait=3, assert 2.5s - 6.0s)
    # -------------------------------------------------------------------------
    if ($targetPid -and $tailData -and $tailData.stamp) {
        $currentStamp = $tailData.stamp

        # Test stale since
        $swStale = [System.Diagnostics.Stopwatch]::StartNew()
        $staleReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$baseURL/sessions/$targetPid/tail?n=1&since=stale-stamp-for-smoke&wait=3")
        $staleReq.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
        $staleResp = $httpClient.SendAsync($staleReq).Result
        $swStale.Stop()
        $staleSec = $swStale.Elapsed.TotalSeconds

        # Test current since (should hold for ~3s)
        $swHold = [System.Diagnostics.Stopwatch]::StartNew()
        $holdReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$baseURL/sessions/$targetPid/tail?n=1&since=$currentStamp&wait=3")
        $holdReq.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
        $holdResp = $httpClient.SendAsync($holdReq).Result
        $swHold.Stop()
        $holdSec = $swHold.Elapsed.TotalSeconds

        if ($staleSec -lt 1.0 -and $holdSec -ge 2.5 -and $holdSec -le 6.0) {
            Report-Pass "Long-poll: stale 'since' returned in $([math]::Round($staleSec, 3))s (< 1.0s); current 'since' held $([math]::Round($holdSec, 3))s (2.5s - 6.0s)"
        } else {
            Report-Fail "Long-poll" "Stale time: $([math]::Round($staleSec, 3))s (expected < 1s), Hold time: $([math]::Round($holdSec, 3))s (expected 2.5s - 6.0s)"
        }
    } else {
        Report-Fail "Long-poll" "Skipped: no stamp available from session tail"
    }

    # -------------------------------------------------------------------------
    # 6. Unknown pid -> 404; unknown route -> 404
    # -------------------------------------------------------------------------
    $badPidReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$baseURL/sessions/99999999/tail")
    $badPidReq.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
    $badPidStatus = [int]$httpClient.SendAsync($badPidReq).Result.StatusCode

    $badRouteReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$baseURL/nonexistent-route-for-testing")
    $badRouteReq.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
    $badRouteStatus = [int]$httpClient.SendAsync($badRouteReq).Result.StatusCode

    if ($badPidStatus -eq 404 -and $badRouteStatus -eq 404) {
        Report-Pass "Routing: unknown pid returned 404, unknown route returned 404"
    } else {
        Report-Fail "Routing" "Expected (404, 404) got ($badPidStatus, $badRouteStatus)"
    }

    # -------------------------------------------------------------------------
    # 7. POST /activities/token -> 2xx
    # -------------------------------------------------------------------------
    $actReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$baseURL/activities/token")
    $actReq.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
    $actReq.Content = [System.Net.Http.StringContent]::new("{}", [System.Text.Encoding]::UTF8, "application/json")
    $actStatus = [int]$httpClient.SendAsync($actReq).Result.StatusCode

    if ($actStatus -ge 200 -and $actStatus -lt 300) {
        Report-Pass "Activities token: POST /activities/token returned $actStatus (2xx)"
    } else {
        Report-Fail "Activities token" "Expected 2xx, got $actStatus"
    }

    # -------------------------------------------------------------------------
    # 8. POST /sessions/<pid>/input with kind:key -> outcome noSurface
    #
    # NOTE: We deliberately test kind:key rather than kind:message here.
    # An automated test script must NEVER inject cross-session messages into
    # real interactive user sessions, as that interrupts active tasks and
    # sends unexpected prompt messages to running Claude Code sessions.
    # Message injection is verified via manual scratch session tests and
    # unit tests (NamedPipeTests).
    # -------------------------------------------------------------------------
    if ($targetPid) {
        $keyReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$baseURL/sessions/$targetPid/input")
        $keyReq.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $testToken)
        $keyJson = ConvertTo-Json @{ kind = "key"; text = "enter" }
        $keyReq.Content = [System.Net.Http.StringContent]::new($keyJson, [System.Text.Encoding]::UTF8, "application/json")
        $keyResp = $httpClient.SendAsync($keyReq).Result
        $keyStatus = [int]$keyResp.StatusCode
        $keyBody = $keyResp.Content.ReadAsStringAsync().Result

        if ($keyStatus -eq 200 -and $keyBody -match '"outcome"\s*:\s*"noSurface"') {
            Report-Pass "Input key: POST /sessions/$targetPid/input with kind:key returned outcome 'noSurface'"
        } else {
            Report-Fail "Input key" "Status $keyStatus, body: $keyBody"
        }
    } else {
        Report-Fail "Input key" "Skipped: no target pid"
    }

} finally {
    # -------------------------------------------------------------------------
    # 9. Clean daemon termination: always cleanup child process even on failure
    # -------------------------------------------------------------------------
    if ($daemonProc -and -not $daemonProc.HasExited) {
        try {
            $daemonProc.Kill()
            $daemonProc.WaitForExit(3000) | Out-Null
            Report-Pass "Daemon shutdown: process $($daemonProc.Id) terminated cleanly"
        } catch {
            Report-Fail "Daemon shutdown" "Could not terminate PID $($daemonProc.Id): $_"
        }
    } elseif ($daemonProc -and $daemonProc.HasExited) {
        Report-Pass "Daemon shutdown: process $($daemonProc.Id) already exited"
    }

    if (Test-Path $tokenFile) {
        Remove-Item -Path $tokenFile -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Smoke test summary: $passCount passed, $failCount failed."
if ($failCount -gt 0) {
    exit 1
} else {
    exit 0
}
