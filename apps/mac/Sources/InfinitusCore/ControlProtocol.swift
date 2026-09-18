import Foundation

// MARK: - Control protocol (agent CLI ↔ running app)
//
// One request line in, one reply line out, over a same-user UNIX
// socket the app owns (mode 0600 — the socket's owner IS the auth).
// The manifest below is the single table both sides read: the app
// dispatches on it, the CLI prints help from it, and `infinitus
// manifest` hands it to agents so a guide can never drift from the
// code (user 2026-09-03: "so AI Agent can control it").

public enum ControlProtocol {
    /// Bumped when a reply shape changes incompatibly; the CLI refuses
    /// to talk to a newer app so an agent never misreads a field.
    public static let schemaVersion = 1

    /// macOS: `~/Library/Application Support/Infinitus/control/control.sock`
    /// — the directory is 0700 (the app creates it before binding).
    /// Linux (#486 slice 3): `$XDG_RUNTIME_DIR/infinitus/control.sock`,
    /// where the tray binds it and `infinitusctl` finds it.
    /// `INFINITUS_CONTROL_SOCKET` overrides both, so a dev instance
    /// (playground / shots) and `infinitusctl` can meet on a private
    /// socket instead of the real app's.
    public static func socketURL(home: String = NSHomeDirectory(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["INFINITUS_CONTROL_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #if os(Linux)
        return URL(fileURLWithPath: linuxSocketPath(home: home, environment: environment))
        #else
        return URL(fileURLWithPath: macSocketPath(home: home))
        #endif
    }

    /// Each platform's rule as a plain function, so both are tested from
    /// either one (`socketURL` above only picks between them).
    static func macSocketPath(home: String) -> String {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Infinitus/control/control.sock").path
    }

    /// The runtime dir is where a per-user socket belongs on Linux (tmpfs,
    /// 0700, cleared at logout). Without one — a bare `ssh` session, a
    /// systemd-less box — the state dir is the stable stand-in, the same
    /// `~/.local/state/infinitus` the tray already keeps its history in.
    static func linuxSocketPath(home: String, environment: [String: String]) -> String {
        if let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            return URL(fileURLWithPath: runtime)
                .appendingPathComponent("infinitus/control.sock").path
        }
        if let state = environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state)
                .appendingPathComponent("infinitus/control.sock").path
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".local/state/infinitus/control.sock").path
    }
}

public struct ControlRequest: Codable, Sendable, Equatable {
    public let command: String
    public let args: [String]
    /// Named options (`--yes`, `--timeout 300`) — keyed without dashes.
    public let options: [String: String]
    /// Secret material (the proxy management key) rides here, read from
    /// the CLI's stdin — never argv.
    public let secret: String?

    public init(command: String, args: [String] = [], options: [String: String] = [:],
                secret: String? = nil) {
        self.command = command
        self.args = args
        self.options = options
        self.secret = secret
    }
}

public struct ControlReply: Codable, Sendable {
    public let schemaVersion: Int
    public let ok: Bool
    /// Command result; shape per `ControlCommand.replyShape`.
    public let result: JSONValue?
    public let error: String?
    /// The app is relaunching (engine flips, key save); the CLI waits
    /// for the socket to return before it exits 0.
    public let restarting: Bool

    public init(ok: Bool, result: JSONValue? = nil, error: String? = nil,
                restarting: Bool = false) {
        self.schemaVersion = ControlProtocol.schemaVersion
        self.ok = ok
        self.result = result
        self.error = error
        self.restarting = restarting
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, ok, result, error, restarting }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        ok = try c.decode(Bool.self, forKey: .ok)
        // A `null` result is a value, distinct from no result at all:
        // decodeIfPresent folds both into nil and the CLI would print
        // nothing.
        if c.contains(.result) {
            result = try c.decodeNil(forKey: .result) ? .null : try c.decode(JSONValue.self, forKey: .result)
        } else {
            result = nil
        }
        error = try c.decodeIfPresent(String.self, forKey: .error)
        restarting = try c.decodeIfPresent(Bool.self, forKey: .restarting) ?? false
    }

    public static func failure(_ message: String) -> ControlReply {
        ControlReply(ok: false, error: message)
    }
}

/// What an agent needs to know to call a command without reading code.
public struct ControlCommand: Codable, Sendable, Equatable {
    public enum Effect: String, Codable, Sendable {
        /// Reads state; always safe.
        case read
        /// Changes engine state; reversible.
        case write
        /// Deletes a credential; needs `--yes`.
        case destructive
        /// The app relaunches; the CLI waits for it.
        case restart
        /// Starts something a human must finish (OAuth in the app window).
        case human
    }

    public let name: String
    /// Positional args, in order. `<fleet>` is an `EngineFleet.key`
    /// such as `swapd/claude`; `<n>` an account number in that fleet.
    public let args: [String]
    public let options: [String]
    public let effect: Effect
    /// Engine capability the fleet must have, when the command targets one.
    public let requires: String?
    public let summary: String
    public let replyShape: String
    /// What the request line's `secret` field (the CLI's stdin) carries:
    /// `"secret"` — a credential or code, never logged, never echoed;
    /// `"payload"` — a message or hook body; nil — nothing is read. A
    /// client must not send a secret to a verb that does not declare
    /// `"secret"` (#747).
    public let stdin: String?

    public init(name: String, args: [String] = [], options: [String] = [],
                effect: Effect, requires: String? = nil, stdin: String? = nil,
                summary: String, replyShape: String) {
        self.name = name
        self.args = args
        self.options = options
        self.effect = effect
        self.requires = requires
        self.stdin = stdin
        self.summary = summary
        self.replyShape = replyShape
    }

    /// Every command the app answers. Order = help order.
    public static let all: [ControlCommand] = [
        ControlCommand(name: "manifest", effect: .read,
                       summary: "This table as JSON, plus schemaVersion.",
                       replyShape: "{schemaVersion, commands:[ControlCommand]}"),
        ControlCommand(name: "status", effect: .read,
                       summary: "App version, which engines are on, engine badge, whether a sign-in is running.",
                       replyShape: "{version, sha, engines:{swapd:{enabled,registered,binaryPath?,daemon?:stopped|running|backingOff|refused|schemaMismatch,error?}, cliproxy:{enabled,registered,keyPresent,error?}, 9router:{enabled,registered,keyPresent,error?}}, badge, signInRunning, playground, bundlePath, nested}"),
        ControlCommand(name: "fleets", effect: .read,
                       summary: "Every fleet with accounts, usage, active/next, the engine's capabilities and, while priority_mode is on, its headroom verdict (#616: absent = mode off or no usage seen yet; a transient usage gap keeps the last verdict; #743: the interrupt mode says critical where hold says low).",
                       replyShape: "[{key, engineID, provider, capabilities:[String], caveat?, activeNumber?, nextCandidate?, candidateOrder?, nextRecovery?, accounts:[Account], headroom?:{state:abundant|low|critical, window, pct, reason}}]"),
        ControlCommand(name: "plan", effect: .read,
                       summary: "The reset battle plan (#7) the planner proposes right now — ignite / switch / hold / reset steps with epoch instants — or null when there is nothing to plan.",
                       replyShape: "{plan: {bindAt, steps:[{at, action, number, why}]} | null}"),
        ControlCommand(name: "forecast", effect: .read,
                       summary: "Run-rate projection: per account and window the measured pct/hour and the epoch instant it hits 100% (null when the reset lands first or the pace is unknown), the active account's line, and when the fleet's weekly headroom is gone at the active pace with the drain order assumed. Estimates.",
                       replyShape: "{forecast: {computedAt, active: <line> | null, accounts: [<line>], allDeadAt, drainOrder: [number], basis} | null} where <line> = {number, email, alias, active, disabled, windows:[{name, pct, ratePctPerHour, resetsAt, hitsAt}]}"),
        ControlCommand(name: "refresh", effect: .write,
                       summary: "Poll every engine now; replies like `fleets`.",
                       replyShape: "same as fleets"),
        ControlCommand(name: "quit", effect: .write,
                       summary: "Quit the menu-bar app gracefully: tunnels, terminals, the engine supervisor and owned sessions are stopped first (#654, the fork's quit-with-window setting).",
                       replyShape: "{quitting: true}"),
        ControlCommand(name: "switch", args: ["<fleet>", "<n>"], effect: .write, requires: "switch",
                       summary: "Make account n the active one (proxy: top priority tier).",
                       replyShape: "{fleet}"),
        ControlCommand(name: "rotate", args: ["<fleet>"], effect: .write, requires: "rotate",
                       summary: "Switch to the engine's next candidate — what auto-rotation would do now.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "history", args: ["<fleet>"], options: ["--limit <n>"], effect: .read, requires: "history",
                       summary: "The engine's switch log, its own JSON untouched (swapd: {schemaVersion, switches:[{ts, from?, to, trigger?}]}, newest last).",
                       replyShape: "{fleet, history}"),
        ControlCommand(name: "hold", args: ["<fleet>", "<n>"], effect: .write, requires: "hold",
                       summary: "Take account n out of rotation.", replyShape: "{fleet}"),
        ControlCommand(name: "unhold", args: ["<fleet>", "<n>"], effect: .write, requires: "hold",
                       summary: "Return account n to rotation.", replyShape: "{fleet}"),
        ControlCommand(name: "crashes", args: [], options: ["--id <id>"], effect: .read,
                       summary: "Crash reports of the phone app (MetricKit, over the mirror) and this Mac app, newest first, without the raw diagnostic. `--id` answers that one report alone, with the `transcript` a session gets — the raw diagnostic included.",
                       replyShape: "{crashes: [{id, platform, device, appVersion, osVersion, at, kind, reason, frames, transcript?}]}"),
        ControlCommand(name: "randomize-names", args: ["<fleet>", "[n]"], effect: .write, requires: "rename",
                       summary: "Give every account in the fleet — or only account n, skipping the names the fleet already wears — a fresh name from the current theme's pool (every built-in's when the theme has none).",
                       replyShape: "{fleet, names}"),
        ControlCommand(name: "rename", args: ["<fleet>", "<n>", "<alias>"], effect: .write, requires: "rename",
                       summary: "Set (empty string clears) the alias every frontend shows.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "prefer", args: ["<fleet>", "<n>", "on|off"], effect: .write, requires: "prefer",
                       summary: "Star/unstar an account: the engine lands on starred ones first when it switches (swapd prefer; proxy priority tier). Refused when the engine reports no flag for the account.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "auto-ignite", args: ["<fleet>", "<n>", "on|off"], effect: .write, requires: "autoIgnite",
                       summary: "Keep account n's 5h window running: the engine's daemon ignites it whenever the window has gone cold (swapd auto-ignite). Each ignite costs ~1K weekly tokens on n. Refused when the engine reports no flag for the account.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "aws-logins", effect: .read,
                       summary: "AWS or gcloud sign-ins started by these verbs, running or just failed; `provider` is \"gcloud\" for gcloud items and absent for AWS.",
                       replyShape: "{logins: [{profile, provider?, flow, state: {phase, url, userCode, message, startedAt} | null}]}"),
        ControlCommand(name: "aws-login", args: ["<profile>"], options: ["--local", "--remote", "--status", "--dismiss"],
                       effect: .human,
                       summary: "Run the AWS sign-in for a profile and report the URL to open on another device: the relay flow (plain `aws login`, the phone's browser intercepts the localhost callback → `aws-login-callback`), the SSO device-code flow for sso_session profiles, or --remote (`aws login --remote`, code pasted back via `aws-login-code`); --local opens this Mac's browser instead; --status only reports the profile's login and starts nothing; --dismiss forgets it (stops a running one) so `aws-logins` drops the profile. Watch `aws-logins` for the state.",
                       replyShape: "{state: {profile, flow, phase, url, userCode, message}}"),
        ControlCommand(name: "aws-login-callback", args: ["<profile>"], effect: .write, stdin: "secret",
                       summary: "Relay flow: feed the redirect the phone's browser intercepted (read from stdin) to the waiting login — `http://127.0.0.1:<port>/oauth/callback?code=…` for `aws login`, `http://localhost:8085/?code=…` for `gcloud auth login`; the Mac replays it against the CLI's own listener.",
                       replyShape: "{state}"),
        ControlCommand(name: "aws-login-code", args: ["<profile>"], effect: .write, stdin: "secret",
                       summary: "Feed the authorization code read from stdin to the waiting `aws login --remote` for that profile.",
                       replyShape: "{state}"),
        ControlCommand(name: "gcloud-login", args: ["<account|default|application-default>"], options: ["--local", "--remote", "--status", "--dismiss"],
                       effect: .human,
                       summary: "Run the gcloud sign-in for an account (`gcloud auth login`, or `auth application-default login` for application-default) and report the URL to open on another device: the relay flow (the phone's browser intercepts the localhost:8085 callback → `aws-login-callback`), or --remote (`--no-launch-browser`, the page ends with a verification code pasted back via `gcloud-login-code`); --local opens this Mac's browser instead; --status only reports the login and starts nothing; --dismiss forgets it (stops a running one). Watch `aws-logins` for the state (provider \"gcloud\").",
                       replyShape: "{state: {profile, provider, flow, phase, url, message}}"),
        ControlCommand(name: "gcloud-login-code", args: ["<account|default|application-default>"], effect: .write, stdin: "secret",
                       summary: "Feed the verification code read from stdin to the waiting `gcloud auth login` for that account.",
                       replyShape: "{state}"),
        ControlCommand(name: "ignite", args: ["<fleet>", "<n>"], effect: .write, requires: "ignite",
                       summary: "Start account n's 5h window now with one tiny request (swapd ignite, #7); the active account is untouched. Costs ~1K weekly tokens on n.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "reorder", args: ["<fleet>", "<n>..."], effect: .write, requires: "reorder",
                       summary: "Set the rotation order: every account number exactly once, top first.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "remove", args: ["<fleet>", "<n>"], options: ["--yes"],
                       effect: .destructive, requires: "remove",
                       summary: "Delete the credential from the engine. Refused without --yes.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "add", args: ["<fleet>"], effect: .human, requires: "addOAuth|addToken",
                       summary: "Open the in-app sign-in for this fleet. A human completes it in the Infinitus window; poll with wait-add.",
                       replyShape: "{started:true}"),
        ControlCommand(name: "wait-add", options: ["--timeout <seconds, default 300>"], effect: .read,
                       summary: "Block until the running sign-in finishes.",
                       replyShape: "{done:Bool, error?, fleets}"),
        ControlCommand(name: "signin-begin", args: ["<fleet>"], options: ["--relogin <email>"],
                       effect: .human, requires: "addOAuth|addToken",
                       summary: "Start this fleet's sign-in with no window on the Mac: the reply carries the OAuth URL for the caller to show (the desktop app, #677). Poll signin-status; hand the code back with signin-code.",
                       replyShape: "{flowId, url, pasteCode:Bool, label}"),
        ControlCommand(name: "signin-status", args: ["<flowId>"], effect: .read,
                       summary: "Where the sign-in stands; error carries the CLI's own rejection wording.",
                       replyShape: "{flowId, phase: starting|waitingForCode|waitingForToken|registering|done|failed, error?, url?, pasteCode:Bool, account?}"),
        ControlCommand(name: "signin-code", args: ["<flowId>"], effect: .write, stdin: "secret",
                       summary: "Hand the code from the OAuth success page (stdin, never argv) to the waiting sign-in; ok:false carries the CLI's rejection.",
                       replyShape: "{ok:Bool, error?}"),
        ControlCommand(name: "signin-cancel", args: ["<flowId>"], effect: .write,
                       summary: "Stop the sign-in and close its CLI.",
                       replyShape: "{cancelled:true}"),
        ControlCommand(name: "windows", effect: .read,
                       summary: "Every AppKit window the app owns: title, class, visible, occluded, content view — the e2e/perf probe.",
                       replyShape: "[{number, title, class, visible, occluded, level, size:[w,h], content}]"),
        ControlCommand(name: "events", options: ["limit", "after"], effect: .read,
                       summary: "The app's event log (switches, deaths, revivals, nudges…), oldest first — what the Activity pane shows. Last 100 kept. --after <event id> returns only the rows past that event; known:false means the id is gone (app relaunched or aged out) and rows is the full tail.",
                       replyShape: "[{id, at, kind, icon, text}] | with --after {after, known, rows:[…]}"),
        ControlCommand(name: "stats", options: ["period"], effect: .read,
                       summary: "Engineering metrics for a period (day|week|month|year, default week): commits, lines, PRs, human/phone/agent messages, sessions, tool calls, waiting time, switches, cost — Stats tab data.",
                       replyShape: "{period, from, to, total:{humanMessages, phoneMessages, agentMessages, commits, linesAdded, linesRemoved, prsOpened, prsMerged, sessionTally, toolCalls:{name:n}, waitingSeconds, switches, limitStops, usd, …}, previous:{…}, daily:[{key, day}], streak}"),
        ControlCommand(name: "utilization", options: ["--days <1|7|30>"], effect: .read,
                       summary: "The Utilization pane's data over the last N days (default 7): the recorded usage samples downsampled to the pane's bucket, weekly-window waste generations, five-hour windows, the replay report, the planner's dry run over the latest samples, and the token run rate when the app has scanned it.",
                       replyShape: "{days, bucketSeconds, samples:[{t, email, number, active?, fiveHour?:{pct, resetsAt}, sevenDay?:{pct, resetsAt}, scoped?:{name:{pct, resetsAt}}}], generations:[{email, window, resetAt, finalPct, observationGap}], fiveHourWindows:[{email, number?, start, resetsAt, peakPct, samples, closed}], replay:{from, to, switches, coldSwitches, stalledSeconds, sawActiveFlag}, dryRunPlan?, windows:[name], emails:[email], rates?:{computedAt, lastHour:{input, output, cacheRead, cacheWrite, usd, messages}, lastDay, lastWeek, files, unpricedModels}, liveRate?:{perMinute, peakPerMinute}}"),
        ControlCommand(name: "perf", effect: .read,
                       summary: "Process cost: CPU seconds so far, RSS + live heap bytes, thread count — sample twice for an idle % and a heap growth rate (perf gate).",
                       replyShape: "{cpuSeconds, rssBytes, heapBytes, threads, uptimeSeconds, leases, leaseScopes: {clientId: [scope]}}"),
        ControlCommand(name: "show", args: ["popout"], effect: .write,
                       summary: "Open the pinned pop-out. The Settings, wall, workspace and session windows are retired — the Infinitus desktop app is the client.",
                       replyShape: "{shown}"),
        ControlCommand(name: "prefs", args: ["[get <key>...]"], effect: .read,
                       summary: "The preference catalog with current values: key, type, default, section (slug + name), live/restart effect, choices; `get` narrows it to the named keys.",
                       replyShape: "{sections:[{slug,name}], prefs:[{key,type,default,value,section,effect,choices?,min?,max?}]}"),
        ControlCommand(name: "client-activity", options: ["--body <json>"], effect: .write,
                       summary: "A client's visibility report — the body `POST /client-activity` takes: {clientId, visible, focused, recentlyInteracted, scopes:[{type:sessions|session|fleets|stats, pid?}], ttlMs}. Leases the scopes it watches.",
                       replyShape: "{clientId}"),
        ControlCommand(name: "crash-report", options: ["--body <json>"], effect: .write,
                       summary: "File a client's crash or hang — the body `POST /crashes` takes: {id, platform, device, appVersion, osVersion, at (ISO-8601), kind, reason, frames, raw?}; `crashes` lists it.",
                       replyShape: "{id}"),
        ControlCommand(name: "prefs-set", args: ["<key>", "<value>"], effect: .write,
                       summary: "Set one preference (`prefs set <key> <value>` is the same): the value is JSON, or a bare word for a string; refused when it is the wrong type or off the pref's choices. A `restart` pref relaunches the app after the reply, as `engine` does.",
                       replyShape: "{key,type,default,value,section,effect,choices?}"),
        ControlCommand(name: "hide", args: ["popout"], effect: .write,
                       summary: "Close the pinned pop-out (the e2e no-lease window).",
                       replyShape: "{hidden}"),
        ControlCommand(name: "engine", args: ["swapd|cliproxy|9router", "on|off"], effect: .restart,
                       summary: "Turn an engine on or off. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "proxy", effect: .read,
                       summary: "CLIProxyAPI settings: base URL, its management panel's URL, whether a key is stored, whether the engine is on, routing strategy, session affinity (absent on a proxy without the route), the routing caveat and the last error.",
                       replyShape: "{baseURL, dashboardURL, keyPresent, enabled, routingStrategy?, sessionAffinity?, caveat?, error?}"),
        ControlCommand(name: "proxy-key", options: ["--url <base URL, default http://127.0.0.1:8317>"],
                       effect: .restart, stdin: "secret",
                       summary: "Store the management key read from stdin in the keychain. Empty stdin clears it. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "9router", effect: .read,
                       summary: "9Router settings: base URL, its dashboard's URL, whether a password is stored, whether the engine is on, and the last error its refresh failed with.",
                       replyShape: "{baseURL, dashboardURL, passwordPresent, enabled, error?}"),
        ControlCommand(name: "9router-password", options: ["--url <base URL, default http://127.0.0.1:20128>"],
                       effect: .restart, stdin: "secret",
                       summary: "Store the 9Router dashboard password read from stdin in the keychain. Empty stdin clears it. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "proxy-routing", args: ["fill-first|round-robin|weighted-round-robin"],
                       effect: .write,
                       summary: "PUT the proxy's routing strategy.",
                       replyShape: "{routingStrategy}"),
        ControlCommand(name: "proxy-affinity", args: ["on|off"], effect: .write,
                       summary: "PUT the proxy's session affinity (a conversation stays on one credential). Refused on a proxy without the route.",
                       replyShape: "{sessionAffinity}"),
        ControlCommand(name: "test-connection", args: ["cliproxy|9router"],
                       options: ["--url <base URL, this probe only; default the stored one>"], effect: .read,
                       summary: "Probe an engine's management API with the credential in the keychain (the caller never holds it): ok with the round-trip time, or the engine's own words in error — never the credential. Answers within 5 s; a dead URL reads as a timeout. --url probes an address before it is saved.",
                       replyShape: "{ok, latencyMs?, version?, error?}"),
        ControlCommand(name: "push", effect: .write, stdin: "payload",
                       summary: "A thread phase change from Infinitus desktop on stdin ({kind: \"thread.phase\", threadId, title, phase, detail?}): pushed as one line through the Mac's channels — Notification Center, and the phones through the desktop and the Infinitus Connect relay (#1375) — with the Mac's own gating. Title and phase only, never prompt text.",
                       replyShape: "{pushed}"),
        ControlCommand(name: "desktop-credential", options: ["--origin <http://127.0.0.1:port>", "--expiresAt <iso>"], effect: .write, stdin: "secret",
                       summary: "Keep the bearer session Infinitus desktop mints for infinitusctl (stdin) in the keychain, with the desktop's origin; empty stdin forgets it. Infinitus desktop sends this itself when it publishes its port.",
                       replyShape: "{origin, expiresAt, stored}"),
        ControlCommand(name: "desktop-status", effect: .read,
                       summary: "Where Infinitus desktop is (origin, the published port) and the CLI credential kept for it, masked.",
                       replyShape: "{origin, port, credential: <masked>|null, expiresAt, stale}"),
        // Team (#1313): Settings › Team on the desktop and the
        // phone drive these; the secret-carrying ones take it on stdin.
        ControlCommand(name: "team-status", effect: .read,
                       summary: "Settings › Team: the team this Mac is in — members with what they last published, pending requests, shares, exclusions, the loop's last fetch/publish — or null when there is none.",
                       replyShape: "{id, name, remote (masked), kid, role: leader|member|pending, rev, members: [{kid, name, role, isMe, founder, since, lastPublished, kinds, threadsNow, blockers, crashes, todayUSD, todayMessages, todayCommits, fleet}], requests: [{kid, name, platform, devices, at}], policy: {requests}, shares: {kind: audience}, exclusions: [slug], lastFetch, lastPublish, lastError} | null"),
        ControlCommand(name: "team-create", args: ["<name>"], options: ["--remote <url>", "--as <your name>"], effect: .write, stdin: "secret",
                       summary: "Create a team on an empty git remote; the remote's write token, if it needs one, comes on stdin (empty stdin: none).",
                       replyShape: "team-status"),
        ControlCommand(name: "team-join", args: ["<your name>"], effect: .write, stdin: "secret",
                       summary: "Request to join a team: the team code or invite link on stdin, this Mac's name in the roster as the argument.",
                       replyShape: "team-status"),
        ControlCommand(name: "team-code", options: ["--days <n>", "--invite"], effect: .write,
                       summary: "Mint a team code (leaders): the code, valid --days (default 7); --invite adds a one-time nonce the leader auto-approves.",
                       replyShape: "{code, expires}"),
        ControlCommand(name: "team-fetch", effect: .write, summary: "Pull the store now and rebuild the snapshot.", replyShape: "team-status"),
        ControlCommand(name: "team-publish", effect: .write, summary: "Publish this Mac's data now (what the 5-minute loop does).", replyShape: "{published: [path], transcriptChunks, skipped}"),
        ControlCommand(name: "team-approve", args: ["<kid>"], effect: .write, summary: "Approve a join request (leaders).", replyShape: "team-status"),
        ControlCommand(name: "team-decline", args: ["<kid>"], effect: .write, summary: "Decline a join request (leaders).", replyShape: "team-status"),
        ControlCommand(name: "team-remove", args: ["<kid>"], effect: .write, summary: "Remove a member (leaders; never the founder).", replyShape: "team-status"),
        ControlCommand(name: "team-promote", args: ["<kid>"], effect: .write, summary: "Make a member a leader.", replyShape: "team-status"),
        ControlCommand(name: "team-leave", options: ["--yes"], effect: .write, summary: "Delete my files on the store, tell the leaders, forget the team here; --yes confirms.", replyShape: "{left}"),
        ControlCommand(name: "team-share", args: ["<kind>", "off|leaders|team"], effect: .write, summary: "Audience for stats|now|threads|transcripts|fleet.", replyShape: "team-status"),
        ControlCommand(name: "team-exclude", args: ["add|remove", "<project slug>"], effect: .write, summary: "Keep a project private (local, never sent).", replyShape: "team-status"),
        ControlCommand(name: "team-policy", args: ["requests", "code|off"], effect: .write, summary: "Who may request to join (leaders): with a code, or nobody.", replyShape: "team-status"),
        ControlCommand(name: "team-insights", options: ["--period <day|week|month|year>"], effect: .read, summary: "Blockers, headroom, who is on, the team picture for the period (spend is an estimate).", replyShape: "{period, blockers: [{kid, name, kind, text}], headroom: [{kid, name, engine, active, headroom, spare, dead}], onNow: [name], cost: {total, byMember, byModel, byRepo}, repos: [{project, usd, turns, members}], hours: [n]}"),
        ControlCommand(name: "team-identity", options: ["--export"], effect: .read, stdin: "secret",
                       summary: "This Mac's team identity kid; with --export, the passphrase on stdin and the sealed identity file in the reply (never logged).", replyShape: "{kid, exported?}"),
        // Delegated control (#1313, spec §8): who may drive this Mac's
        // threads, the driver's side, and the desktop route's inbox.
        ControlCommand(name: "team-inbox", effect: .write, stdin: "secret",
                       summary: "One sealed team command (base64 on stdin) off the desktop's POST /api/infinitus/team/command: verified, run against Infinitus desktop, answered with the sealed ack — or null when there is nobody to answer (not a member, not an envelope). Never an error: a stranger learns nothing.",
                       replyShape: "{ack: <base64>|null}"),
        ControlCommand(name: "team-grants", effect: .read, summary: "This Mac's grants: who may do what to which threads.", replyShape: "{grants: [{id, audience, threads, capabilities, since, preauthorized?, expires?}]}"),
        ControlCommand(name: "team-grant", args: ["<leaders|team|kid,…>"], options: ["--cap <view,send,interrupt,new>", "--threads <id,id>", "--pre <interrupt,new>", "--expires <seconds>"], effect: .write,
                       summary: "Let an audience drive this Mac's threads (every thread unless --threads); view and send never ask, interrupt and new ask first unless --pre names them.",
                       replyShape: "{id, audience, threads, capabilities, since, preauthorized?, expires?}"),
        ControlCommand(name: "team-revoke", args: ["<grant id>"], effect: .write, summary: "Take a grant back; the next command under it is refused.", replyShape: "{removed}"),
        ControlCommand(name: "team-pending", effect: .read, summary: "Drivers' commands waiting for this Mac's tap (2 minutes each).", replyShape: "[{id, kid, name, thread, action, text, project, expires}]"),
        ControlCommand(name: "team-allow", args: ["<command id>"], effect: .write, summary: "Run a waiting command now; the driver hears the outcome on the next fetch.", replyShape: "{id, outcome, detail}"),
        ControlCommand(name: "team-deny", args: ["<command id>"], effect: .write, summary: "Refuse a waiting command.", replyShape: "{id, outcome}"),
        ControlCommand(name: "team-drive", args: ["<kid|name>", "<thread|->", "<view|send|interrupt|new>", "[text…]"], options: ["--project <title|id>"], effect: .write,
                       summary: "One command on a teammate's thread under their grant: their desktop's doors first (LAN, tunnel), else the store on their next fetch (queued). `new` names the Mac (-) and --project.",
                       replyShape: "{id, lane: lan|tunnel|store, outcome, detail}"),
        ControlCommand(name: "team-acks", effect: .read, summary: "Answers to this Mac's store-lane commands, newest first (fetch first).", replyShape: "[{id, from, outcome, detail, at}]"),
        ControlCommand(name: "desktop-token", effect: .read,
                       summary: "The stored desktop credential, for the CLI's own requests to Infinitus desktop (this socket only; the CLI never prints it).",
                       replyShape: "{origin, token, expiresAt}"),
    ]

    public static func named(_ name: String) -> ControlCommand? {
        all.first { $0.name == name }
    }
}

// MARK: - JSONValue helpers (the Models.swift enum carries replies)

public extension JSONValue {
    /// Re-encode any Encodable as JSON (one hop through Data).
    static func of<T: Encodable>(_ value: T) throws -> JSONValue {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: enc.encode(value))
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

// MARK: - Line codec

public enum ControlCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: line)
    }
}
