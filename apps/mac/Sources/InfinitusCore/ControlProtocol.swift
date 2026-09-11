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
        // A `null` result is a value (team-status with no team answers
        // `null`), distinct from no result at all: decodeIfPresent folds
        // both into nil and the CLI would print nothing.
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
                       summary: "App version, which engines are on, engine badge, whether a sign-in is running, the fork server's tunnel (Mac only; state off|invalidPort|blocked|unavailable|starting|up|stopped, url while up — the stable fork_tunnel_hostname on the named tunnel when set, else a quick tunnel).",
                       replyShape: "{version, sha, engines:{swapd:{enabled,registered}, cliproxy:{enabled,registered,keyPresent}, 9router:{enabled,registered,keyPresent}}, badge, signInRunning, playground, forkTunnel:{enabled, port, state, url?, hostname?}, bundlePath, nested}"),
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
        ControlCommand(name: "crashes", args: [], effect: .read,
                       summary: "Crash reports of the phone app (MetricKit, over the mirror) and this Mac app, newest first, without the raw diagnostic.",
                       replyShape: "{crashes: [{id, platform, device, at, kind, reason, frames}]}"),
        ControlCommand(name: "randomize-names", args: ["<fleet>", "[n]"], effect: .write, requires: "rename",
                       summary: "Give every account in the fleet — or only account n, skipping the names the fleet already wears — a fresh name from the current theme's pool (every built-in's when the theme has none).",
                       replyShape: "{fleet, names}"),
        ControlCommand(name: "rename", args: ["<fleet>", "<n>", "<alias>"], effect: .write, requires: "rename",
                       summary: "Set (empty string clears) the alias every frontend shows.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "prefer", args: ["<fleet>", "<n>", "on|off"], effect: .write, requires: "prefer",
                       summary: "Star/unstar an account: the engine lands on starred ones first when it switches (swapd prefer; proxy priority tier). Refused when the engine reports no flag for the account.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "aws-logins", effect: .read,
                       summary: "Sessions whose AWS or gcloud sign-in lapsed (the expired-credentials signature in their newest tool results), each with the flow the phone would start and any login in flight; `provider` is \"gcloud\" for gcloud items and absent for AWS.",
                       replyShape: "{logins: [{profile, provider?, flow, pid, sessionLabel, state: {phase, url, userCode, message, startedAt} | null}]}"),
        ControlCommand(name: "aws-login", args: ["<profile>"], options: ["--pid <session pid>", "--local", "--remote", "--status"],
                       effect: .human,
                       summary: "Run the AWS sign-in for a profile and report the URL to open on another device: the relay flow (plain `aws login`, the phone's browser intercepts the localhost callback → `aws-login-callback`), the SSO device-code flow for sso_session profiles, or --remote (`aws login --remote`, code pasted back via `aws-login-code`); --local opens this Mac's browser instead; --status only reports the profile's login and starts nothing. Watch `aws-logins` for the state.",
                       replyShape: "{state: {profile, flow, phase, url, userCode, message}}"),
        ControlCommand(name: "aws-login-callback", args: ["<profile>"], effect: .write, stdin: "secret",
                       summary: "Relay flow: feed the redirect the phone's browser intercepted (read from stdin) to the waiting login — `http://127.0.0.1:<port>/oauth/callback?code=…` for `aws login`, `http://localhost:8085/?code=…` for `gcloud auth login`; the Mac replays it against the CLI's own listener.",
                       replyShape: "{state}"),
        ControlCommand(name: "aws-login-code", args: ["<profile>"], effect: .write, stdin: "secret",
                       summary: "Feed the authorization code read from stdin to the waiting `aws login --remote` for that profile.",
                       replyShape: "{state}"),
        ControlCommand(name: "gcloud-login", args: ["<account|default|application-default>"], options: ["--pid <session pid>", "--local", "--remote", "--status"],
                       effect: .human,
                       summary: "Run the gcloud sign-in for an account (`gcloud auth login`, or `auth application-default login` for application-default) and report the URL to open on another device: the relay flow (the phone's browser intercepts the localhost:8085 callback → `aws-login-callback`), or --remote (`--no-launch-browser`, the page ends with a verification code pasted back via `gcloud-login-code`); --local opens this Mac's browser instead; --status only reports the login and starts nothing. Watch `aws-logins` for the state (provider \"gcloud\").",
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
        ControlCommand(name: "lock-status", effect: .read,
                       summary: "Biometric lock (Settings › Lock): whether the setting is on, whether the pop-out and Settings are locked right now, and the re-lock choice. Off by default.",
                       replyShape: "{enabled, locked, relock: immediately|5 min|1 h|on sleep}"),
        ControlCommand(name: "lock", args: ["on|off|now|relock", "[immediately|5m|1h|sleep]"], options: ["--yes"], effect: .write,
                       summary: "Biometric lock: `on` runs the unlock prompt on the Mac once and turns the setting on; `off` turns it off (--yes while in a team); `now` locks the pop-out and Settings; `relock <choice>` sets the re-lock delay.",
                       replyShape: "lock-status"),
        ControlCommand(name: "unlock", effect: .write,
                       summary: "Run the unlock prompt on the Mac (Touch ID or password) and unlock the pop-out and Settings; refused with the reason when it fails or is cancelled.",
                       replyShape: "lock-status"),
        ControlCommand(name: "team-status", effect: .read,
                       summary: "Settings › Team: the team this Mac is in — members with what they last published, today's effort and blockers, pending requests, the loop's last fetch/publish — or null when there is none.",
                       replyShape: "{id, name, remote (masked), kid, role: leader|member|pending, rev, members: [{kid, name, role, isMe, founder, lastPublished, kinds, sessionsNow, blockers, crashes, todayUSD, todayMessages, todayCommits, fleet, controls}], requests: [{kid, name, platform, devices, at}], lastFetch, lastPublish, lastError} | null"),
        ControlCommand(name: "team-create", args: ["<name>"], options: ["--remote <url>", "--as <your name>"], effect: .write, stdin: "secret",
                       summary: "Create a team on an empty git remote; the remote's write token, if it needs one, comes on stdin (empty stdin: none).",
                       replyShape: "team-status"),
        ControlCommand(name: "team-join", args: ["<your name>"], effect: .write, stdin: "secret",
                       summary: "Request to join a team: the team code or invite link on stdin, this Mac's name in the roster as the argument.",
                       replyShape: "team-status"),
        ControlCommand(name: "team-hostname", options: ["--zone <zone>", "--label <label>", "--clear"], effect: .write, stdin: "secret",
                       summary: "Settings › Team › Hostnames: keep the Cloudflare zone and label member hostnames are minted under, with the API token on stdin (checked against the zone before it is kept); --clear forgets the token.",
                       replyShape: "{zone, label, configured}"),
        ControlCommand(name: "team-code", options: ["--days <n>", "--invite"], effect: .write,
                       summary: "Mint a team code (leaders): `infinitus://join/…`, valid --days (default 7); --invite adds a one-time nonce the app auto-approves when Settings › Team's switch is on (off by default). Carries the store credential when one is set.",
                       replyShape: "{code}"),
        ControlCommand(name: "team-fetch", effect: .write,
                       summary: "Pull the store now (roster, members' files, requests) and rebuild the snapshot.",
                       replyShape: "team-status"),
        ControlCommand(name: "team-publish", effect: .write,
                       summary: "Publish this Mac's data now (what the 5-minute loop does), then rebuild the snapshot.",
                       replyShape: "{published: [path], transcriptChunks, skipped}"),
        ControlCommand(name: "team-compact", effect: .write,
                       summary: "Rewrite your own member branch to a single commit without the pre-split transcript history — the one force-push the spec allows, explicit and once; teammates' mirrors follow on their next fetch.",
                       replyShape: "team-status"),
        ControlCommand(name: "team-approve", args: ["<kid>"], effect: .write,
                       summary: "Approve a join request (leaders).", replyShape: "team-status"),
        ControlCommand(name: "team-decline", args: ["<kid>"], effect: .write,
                       summary: "Decline a join request (leaders).", replyShape: "team-status"),
        ControlCommand(name: "show", args: ["popout|settings"], effect: .write,
                       summary: "Open a window: the pinned pop-out or Settings. The wall, workspace and session windows are retired — the Infinitus desktop app is the client.",
                       replyShape: "{shown}"),
        ControlCommand(name: "prefs", args: ["[get <key>...]"], effect: .read,
                       summary: "The preference catalog with current values: key, type, default, section (slug + name), live/restart effect, choices; `get` narrows it to the named keys.",
                       replyShape: "{sections:[{slug,name}], prefs:[{key,type,default,value,section,effect,choices?,min?,max?}]}"),
        ControlCommand(name: "activities-token", options: ["--body <json>", "--forget <deviceId>/<kind>"], effect: .write,
                       summary: "Register a phone's push token — the body `POST /activities/token` takes: {kind, token, deviceId, deviceName, environment, themeID?, macId?}. Without --body the CLI reads the JSON from stdin. `--forget <deviceId>/<kind>` withdraws that one registration instead (the phone's alerts switched off); forgotten is false when none was held.",
                       replyShape: "{slot} | with --forget {slot, forgotten}"),
        ControlCommand(name: "client-activity", options: ["--body <json>"], effect: .write,
                       summary: "A client's visibility report — the body `POST /client-activity` takes: {clientId, visible, focused, recentlyInteracted, scopes:[{type:sessions|session|fleets|stats, pid?}], ttlMs}. Leases the scopes it watches.",
                       replyShape: "{clientId}"),
        ControlCommand(name: "crash-report", options: ["--body <json>"], effect: .write,
                       summary: "File a client's crash or hang — the body `POST /crashes` takes: {id, platform, device, appVersion, osVersion, at (ISO-8601), kind, reason, frames, raw?}; `crashes` lists it.",
                       replyShape: "{id}"),
        ControlCommand(name: "prefs-set", args: ["<key>", "<value>"], effect: .write,
                       summary: "Set one preference (`prefs set <key> <value>` is the same): the value is JSON, or a bare word for a string; refused when it is the wrong type or off the pref's choices. A `restart` pref relaunches the app after the reply, as `engine` does.",
                       replyShape: "{key,type,default,value,section,effect,choices?}"),
        ControlCommand(name: "hide", args: ["popout|settings"], effect: .write,
                       summary: "Close the pinned pop-out (the e2e no-lease window) or Settings.",
                       replyShape: "{hidden}"),
        ControlCommand(name: "engine", args: ["swapd|cliproxy|9router", "on|off"], effect: .restart,
                       summary: "Turn an engine on or off. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "proxy", effect: .read,
                       summary: "CLIProxyAPI settings: base URL, whether a key is stored, routing strategy.",
                       replyShape: "{baseURL, keyPresent, routingStrategy?, error?}"),
        ControlCommand(name: "proxy-key", options: ["--url <base URL, default http://127.0.0.1:8317>"],
                       effect: .restart, stdin: "secret",
                       summary: "Store the management key read from stdin in the keychain. Empty stdin clears it. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "9router-password", options: ["--url <base URL, default http://127.0.0.1:20128>"],
                       effect: .restart, stdin: "secret",
                       summary: "Store the 9Router dashboard password read from stdin in the keychain. Empty stdin clears it. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "push-slack", effect: .write, stdin: "secret",
                       summary: "Store a Slack incoming-webhook URL (stdin) in the keychain: every push the app raises is posted there too. Empty stdin forgets it.",
                       replyShape: "{slack, telegram, telegramChat?}"),
        ControlCommand(name: "push-telegram", options: ["--chat <chat id or @channel>"], effect: .write, stdin: "secret",
                       summary: "Store a Telegram bot token (stdin) and the chat it posts to: every push the app raises is sent there too. Empty stdin forgets it.",
                       replyShape: "{slack, telegram, telegramChat?}"),
        ControlCommand(name: "proxy-routing", args: ["fill-first|round-robin|weighted-round-robin"],
                       effect: .write,
                       summary: "PUT the proxy's routing strategy.",
                       replyShape: "{routingStrategy}"),
        ControlCommand(name: "team-discoverable", args: ["on|off"], effect: .write,
                       summary: "Advertise this Mac to teams on the LAN (TXT d=1, /team/key and /team/request), or hide it.",
                       replyShape: "{discoverable}"),
        ControlCommand(name: "event", effect: .write, stdin: "payload",
                       summary: "A Claude Code hook payload on stdin (the plugin's Notification/Stop hooks): a prompt is pushed the moment it appears, then the fleet refreshes.",
                       replyShape: "{pid?}"),
        ControlCommand(name: "push", effect: .write, stdin: "payload",
                       summary: "A thread phase change from Infinitus desktop on stdin ({kind: \"thread.phase\", threadId, title, phase, detail?}): pushed as one line through the Mac's channels — Notification Center, the phone, Slack/Telegram — with the Mac's own gating. Title and phase only, never prompt text.",
                       replyShape: "{pushed}"),
        ControlCommand(name: "approve", effect: .read, stdin: "payload",
                       summary: "A PreToolUse hook payload on stdin: {decision: allow} when the phone allowed that tool for this session, else {decision: ask}.",
                       replyShape: "{decision}"),
        ControlCommand(name: "sessions", effect: .read,
                       summary: "The live Claude Code sessions: pid, name, folder, status, session id, the account alias they run on, start time (ISO 8601) and pending sign-in needs (`aws-login:<profile>`, `gcloud-login:<account>`).",
                       replyShape: "[{pid, name?, cwd, status?, kind, profile?, permissionMode?, sessionId, account?, startedAt?, needs}]"),
        ControlCommand(name: "nudge", args: ["<pid|name>"], effect: .write,
                       summary: "Sends one session the resume nudge by hand (peer socket first, then its terminal); {nudged: false, reason} when its transcript does not end in a limit stop or it cannot be reached.",
                       replyShape: "{pid, nudged, channel?, reason?}"),
        ControlCommand(name: "profiles", effect: .read,
                       summary: "The saved session profiles (Settings › Profiles): name, folder, engine, permission mode, model, system prompt, first prompt.",
                       replyShape: "{profiles: [{name, cwd?, engine?, permissionMode?, model?, systemPrompt?, prompt?, allowTools?}]}"),
        ControlCommand(name: "profile-set", args: ["<name>"],
                       options: ["--cwd <folder>", "--engine claude|codex", "--mode acceptEdits|auto|bypassPermissions",
                                 "--model <model>", "--system <appended system prompt>", "--prompt <first prompt>",
                                 "--allow <\"Edit, Bash git\">"],
                       effect: .write,
                       summary: "Creates or replaces a session profile with exactly the fields given (an omitted field is cleared). --allow lists tools a session born from it runs without asking (the plugin's PreToolUse hook).",
                       replyShape: "{profile}"),
        ControlCommand(name: "profile-remove", args: ["<name>"], effect: .write,
                       summary: "Deletes a session profile.",
                       replyShape: "{removed}"),
        ControlCommand(name: "checkpoints", args: ["<pid|name>"], effect: .read,
                       summary: "The session's per-prompt workspace checkpoints (hidden git refs), oldest first.",
                       replyShape: "{sessionId, cwd, checkpoints: [{n, sha, at, subject}]}"),
        ControlCommand(name: "checkpoint-diff", args: ["<pid|name>", "<n>", "[m]"], effect: .read,
                       summary: "Checkpoint n against checkpoint m, or against the working tree now (untracked files included): a --stat and the patch (capped at 200 KB).",
                       replyShape: "{from, to?, stat, patch, truncated}"),
        ControlCommand(name: "checkpoint-restore", args: ["<pid|name>", "<n>"], options: ["--yes"], effect: .destructive,
                       summary: "Puts the repository's files back to checkpoint n (the current state is checkpointed first, so it is undoable). Needs --yes.",
                       replyShape: "{restored: {n, sha, at, subject}, backup?: {n, sha, at, subject}}"),
        ControlCommand(name: "past-sessions", options: ["--limit <n, default 50>", "--search <text>"], effect: .read,
                       summary: "Every Claude Code session this Mac has run, newest first (default 50): id, folder, opening prompt, last activity, whether it is live. --search filters that newest set by repo, folder or prompt.",
                       replyShape: "{sessions: [{sessionId, cwd, repo, firstMessage, lastActivityAt, bytes, live}]}"),
        ControlCommand(name: "resume-session", args: ["<sessionId>"], options: ["--fork"], effect: .write,
                       summary: "Opens a new terminal in the folder that past session ran in and resumes it there (claude --resume), like the phone's Start session. --fork continues from the transcript under a new session id (claude --fork-session), leaving the original alone — allowed on a live session.",
                       replyShape: "{outcome, detail?, host?, pid?}"),
        ControlCommand(name: "session-mode", args: ["<pid|name>", "<supervised|acceptEdits|bypassPermissions>"], effect: .write,
                       summary: "Moves a running session's permission mode for the plugin's PreToolUse hook: Auto-accept edits allows the editing tools, Full access every tool, supervised clears it. A mode set at start is a floor — it cannot be narrowed from here.",
                       replyShape: "{mode?, label}"),
        ControlCommand(name: "send", args: ["<pid|name>"], effect: .write, stdin: "payload",
                       summary: "Text on stdin goes to that session as if typed into its prompt (peer socket first, then its terminal).",
                       replyShape: "{outcome, channel?, detail?}"),
        ControlCommand(name: "machine", effect: .read,
                       summary: "The machine-health guardian's last sample (#115): load, swap, processes, hooks with live instances, runaway processes, residue counts, session health, warnings. Triggers a sample when none has run yet.",
                       replyShape: "MachineReport | {sampling:true}"),
        ControlCommand(name: "machine-kill", args: ["<pid>"], options: ["--yes"], effect: .destructive,
                       summary: "SIGTERM a runaway the last `machine` report flagged (its own process group when it has one, never a session's), SIGKILL after 3 s if it's still alive. Refused without --yes.",
                       replyShape: "{result}"),
        ControlCommand(name: "machine-reclaim", options: ["--yes"], effect: .destructive,
                       summary: "Remove stale cc-socks, stale session-env dirs, and temp files older than an hour that no process holds open. Refused without --yes.",
                       replyShape: "{result}"),
        ControlCommand(name: "machine-hook", args: ["disable|restore|kill", "<owner>"], options: ["--yes"], effect: .destructive, stdin: "payload",
                       summary: "disable: move a tool's hook registrations out of ~/.claude/settings.json (a timestamped backup is written beside it); restore: put them back; kill: SIGTERM every live instance of its hooks and their helpers from the last `machine` sample (never a session's own pid), SIGKILL the survivors after 3 s. Refused without --yes.",
                       replyShape: "{result}"),
        ControlCommand(name: "desktop-credential", options: ["--origin <http://127.0.0.1:port>", "--expiresAt <iso>"], effect: .write, stdin: "secret",
                       summary: "Keep the bearer session Infinitus desktop mints for infinitusctl (stdin) in the keychain, with the desktop's origin; empty stdin forgets it. Infinitus desktop sends this itself when it publishes its port.",
                       replyShape: "{origin, expiresAt, stored}"),
        ControlCommand(name: "desktop-status", effect: .read,
                       summary: "Where Infinitus desktop is (origin, the published port) and the CLI credential kept for it, masked.",
                       replyShape: "{origin, port, credential: <masked>|null, expiresAt, stale}"),
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
