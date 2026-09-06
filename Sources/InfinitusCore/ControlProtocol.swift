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

    /// `~/Library/Application Support/Infinitus/control/control.sock` —
    /// the directory is 0700 (the app creates it before binding).
    /// `INFINITUS_CONTROL_SOCKET` overrides it on both ends, so a dev
    /// instance (playground / shots) and `infinitusctl` can meet on a
    /// private socket instead of the real app's.
    public static func socketURL(home: String = NSHomeDirectory(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["INFINITUS_CONTROL_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Infinitus/control/control.sock")
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
    /// such as `cswap/claude`; `<n>` an account number in that fleet.
    public let args: [String]
    public let options: [String]
    public let effect: Effect
    /// Engine capability the fleet must have, when the command targets one.
    public let requires: String?
    public let summary: String
    public let replyShape: String

    public init(name: String, args: [String] = [], options: [String] = [],
                effect: Effect, requires: String? = nil,
                summary: String, replyShape: String) {
        self.name = name
        self.args = args
        self.options = options
        self.effect = effect
        self.requires = requires
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
                       replyShape: "{version, sha, engines:{cswap:{enabled,registered}, cliproxy:{enabled,registered,keyPresent}, 9router:{enabled,registered,keyPresent}}, badge, signInRunning, playground}"),
        ControlCommand(name: "fleets", effect: .read,
                       summary: "Every fleet with accounts, usage, active/next and the engine's capabilities.",
                       replyShape: "[{key, engineID, provider, capabilities:[String], caveat?, activeNumber?, nextCandidate?, nextRecovery?, accounts:[Account]}]"),
        ControlCommand(name: "plan", effect: .read,
                       summary: "The reset battle plan (#7) the planner proposes right now — ignite / switch / hold / reset steps with epoch instants — or null when there is nothing to plan.",
                       replyShape: "{plan: {bindAt, steps:[{at, action, number, why}]} | null}"),
        ControlCommand(name: "forecast", effect: .read,
                       summary: "Run-rate projection: per account and window the measured pct/hour and the epoch instant it hits 100% (null when the reset lands first or the pace is unknown), the active account's line, and when the fleet's weekly headroom is gone at the active pace with the drain order assumed. Estimates.",
                       replyShape: "{forecast: {computedAt, active: <line> | null, accounts: [<line>], allDeadAt, drainOrder: [number], basis} | null} where <line> = {number, email, alias, active, disabled, windows:[{name, pct, ratePctPerHour, resetsAt, hitsAt}]}"),
        ControlCommand(name: "refresh", effect: .write,
                       summary: "Poll every engine now; replies like `fleets`.",
                       replyShape: "same as fleets"),
        ControlCommand(name: "switch", args: ["<fleet>", "<n>"], effect: .write, requires: "switch",
                       summary: "Make account n the active one (proxy: top priority tier).",
                       replyShape: "{fleet}"),
        ControlCommand(name: "rotate", args: ["<fleet>"], effect: .write, requires: "rotate",
                       summary: "Switch to the engine's next candidate — what auto-rotation would do now.",
                       replyShape: "{fleet}"),
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
                       summary: "Star/unstar an account: the engine lands on starred ones first when it switches (cswap autoswitch.preferred; proxy priority tier). Refused when the installed cswap lacks the setting.",
                       replyShape: "{fleet}"),
        ControlCommand(name: "aws-logins", effect: .read,
                       summary: "Sessions whose AWS sign-in lapsed (the expired-session signature in their newest tool results), each with the flow the phone would start and any login in flight.",
                       replyShape: "{logins: [{profile, flow, pid, sessionLabel, state: {phase, url, userCode, message, startedAt} | null}]}"),
        ControlCommand(name: "aws-login", args: ["<profile>"], options: ["--pid <session pid>", "--local", "--remote", "--status"],
                       effect: .human,
                       summary: "Run the AWS sign-in for a profile and report the URL to open on another device: the relay flow (plain `aws login`, the phone's browser intercepts the localhost callback → `aws-login-callback`), the SSO device-code flow for sso_session profiles, or --remote (`aws login --remote`, code pasted back via `aws-login-code`); --local opens this Mac's browser instead; --status only reports the profile's login and starts nothing. Watch `aws-logins` for the state.",
                       replyShape: "{state: {profile, flow, phase, url, userCode, message}}"),
        ControlCommand(name: "aws-login-callback", args: ["<profile>"], effect: .write,
                       summary: "Relay flow: feed the `http://127.0.0.1:<port>/oauth/callback?code=…` redirect the phone's browser intercepted (read from stdin) to the waiting `aws login`; the Mac replays it against the CLI's own listener.",
                       replyShape: "{state}"),
        ControlCommand(name: "aws-login-code", args: ["<profile>"], effect: .write,
                       summary: "Feed the authorization code read from stdin to the waiting `aws login --remote` for that profile.",
                       replyShape: "{state}"),
        ControlCommand(name: "ignite", args: ["<fleet>", "<n>"], effect: .write, requires: "ignite",
                       summary: "Start account n's 5h window now with one tiny request (cswap run igniter, #7); the active account is untouched. Costs ~1K weekly tokens on n.",
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
        ControlCommand(name: "windows", effect: .read,
                       summary: "Every AppKit window the app owns: title, class, visible, occluded, content view — the e2e/perf probe.",
                       replyShape: "[{number, title, class, visible, occluded, level, size:[w,h], content}]"),
        ControlCommand(name: "events", options: ["limit"], effect: .read,
                       summary: "The app's event log (switches, deaths, revivals, nudges…), oldest first — what the Activity pane shows. Last 100 kept.",
                       replyShape: "[{at, icon, text}]"),
        ControlCommand(name: "stats", options: ["period"], effect: .read,
                       summary: "Engineering metrics for a period (day|week|month|year, default week): commits, lines, PRs, human/phone/agent messages, sessions, tool calls, waiting time, switches, cost — Stats tab data.",
                       replyShape: "{period, from, to, total:{humanMessages, phoneMessages, agentMessages, commits, linesAdded, linesRemoved, prsOpened, prsMerged, sessionTally, toolCalls:{name:n}, waitingSeconds, switches, limitStops, usd, …}, previous:{…}, daily:[{key, day}], streak}"),
        ControlCommand(name: "perf", effect: .read,
                       summary: "Process cost: CPU seconds so far, RSS + live heap bytes, thread count — sample twice for an idle % and a heap growth rate (perf gate).",
                       replyShape: "{cpuSeconds, rssBytes, heapBytes, threads, uptimeSeconds}"),
        ControlCommand(name: "lock-status", effect: .read,
                       summary: "Biometric lock (Settings › Lock): whether the setting is on, whether the pop-out and Settings are locked right now, and the re-lock choice. Off by default.",
                       replyShape: "{enabled, locked, relock: immediately|5 min|1 h|on sleep}"),
        ControlCommand(name: "team-status", effect: .read,
                       summary: "Settings › Team: the team this Mac is in — members with what they last published, today's effort and blockers, pending requests, the loop's last fetch/publish — or null when there is none.",
                       replyShape: "{id, name, remote (masked), kid, role: leader|member|pending, rev, members: [{kid, name, role, isMe, founder, lastPublished, kinds, sessionsNow, blockers, crashes, todayUSD, todayMessages, todayCommits}], requests: [{kid, name, platform, devices, at}], lastFetch, lastPublish, lastError} | null"),
        ControlCommand(name: "team-create", args: ["<name>"], options: ["--remote <url>", "--as <your name>"], effect: .write,
                       summary: "Create a team on an empty git remote (no credential over the socket: use a file:// or ssh remote, or the pane). Needs the biometric lock on (INFINITUS_LOCK_GATE=open in CI).",
                       replyShape: "team-status"),
        ControlCommand(name: "team-code", options: ["--days <n>", "--invite"], effect: .write,
                       summary: "Mint a team code (leaders): `infinitus://join/…`, valid --days (default 7); --invite adds a one-time nonce the app auto-approves when Settings › Team's switch is on (off by default). Carries the store credential when one is set.",
                       replyShape: "{code}"),
        ControlCommand(name: "team-fetch", effect: .write,
                       summary: "Pull the store now (roster, members' files, requests) and rebuild the snapshot.",
                       replyShape: "team-status"),
        ControlCommand(name: "team-publish", effect: .write,
                       summary: "Publish this Mac's data now (what the 5-minute loop does), then rebuild the snapshot.",
                       replyShape: "{published: [path], transcriptChunks, skipped}"),
        ControlCommand(name: "team-approve", args: ["<kid>"], effect: .write,
                       summary: "Approve a join request (leaders).", replyShape: "team-status"),
        ControlCommand(name: "team-decline", args: ["<kid>"], effect: .write,
                       summary: "Decline a join request (leaders).", replyShape: "team-status"),
        ControlCommand(name: "show", args: ["popout|settings|wall"], effect: .write,
                       summary: "Open a window: the pinned pop-out, Settings, or the wall (toggle).",
                       replyShape: "{shown}"),
        ControlCommand(name: "engine", args: ["cswap|cliproxy|9router", "on|off"], effect: .restart,
                       summary: "Turn an engine on or off. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "proxy", effect: .read,
                       summary: "CLIProxyAPI settings: base URL, whether a key is stored, routing strategy.",
                       replyShape: "{baseURL, keyPresent, routingStrategy?, error?}"),
        ControlCommand(name: "proxy-key", options: ["--url <base URL, default http://127.0.0.1:8317>"],
                       effect: .restart,
                       summary: "Store the management key read from stdin in the keychain. Empty stdin clears it. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "9router-password", options: ["--url <base URL, default http://127.0.0.1:20128>"],
                       effect: .restart,
                       summary: "Store the 9Router dashboard password read from stdin in the keychain. Empty stdin clears it. The app relaunches.",
                       replyShape: "{restarting:true}"),
        ControlCommand(name: "proxy-routing", args: ["fill-first|round-robin|weighted-round-robin"],
                       effect: .write,
                       summary: "PUT the proxy's routing strategy.",
                       replyShape: "{routingStrategy}"),
        ControlCommand(name: "team-discoverable", args: ["on|off"], effect: .write,
                       summary: "Advertise this Mac to teams on the LAN (TXT d=1, /team/key and /team/request), or hide it.",
                       replyShape: "{discoverable}"),
        ControlCommand(name: "event", effect: .write,
                       summary: "A Claude Code hook payload on stdin (the plugin's Notification/Stop hooks): a prompt is pushed the moment it appears, then the fleet refreshes.",
                       replyShape: "{pid?}"),
        ControlCommand(name: "approve", effect: .read,
                       summary: "A PreToolUse hook payload on stdin: {decision: allow} when the phone allowed that tool for this session, else {decision: ask}.",
                       replyShape: "{decision}"),
        ControlCommand(name: "sessions", effect: .read,
                       summary: "The live Claude Code sessions: pid, name, folder, status.",
                       replyShape: "[{pid, name?, cwd, status?, kind}]"),
        ControlCommand(name: "profiles", effect: .read,
                       summary: "The saved session profiles (Settings › Profiles): name, folder, engine, permission mode, model, system prompt, first prompt.",
                       replyShape: "{profiles: [{name, cwd?, engine?, permissionMode?, model?, systemPrompt?, prompt?}]}"),
        ControlCommand(name: "profile-set", args: ["<name>"],
                       options: ["--cwd <folder>", "--engine claude|codex", "--mode acceptEdits|auto|bypassPermissions",
                                 "--model <model>", "--system <appended system prompt>", "--prompt <first prompt>"],
                       effect: .write,
                       summary: "Creates or replaces a session profile with exactly the fields given (an omitted field is cleared).",
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
        ControlCommand(name: "resume-session", args: ["<sessionId>"], effect: .write,
                       summary: "Opens a new terminal in the folder that past session ran in and resumes it there (claude --resume), like the phone's Start session.",
                       replyShape: "{outcome, detail?, host?, pid?}"),
        ControlCommand(name: "session-mode", args: ["<pid|name>", "<supervised|acceptEdits|bypassPermissions>"], effect: .write,
                       summary: "Moves a running session's permission mode for the plugin's PreToolUse hook: Auto-accept edits allows the editing tools, Full access every tool, supervised clears it. A mode set at start is a floor — it cannot be narrowed from here.",
                       replyShape: "{mode?, label}"),
        ControlCommand(name: "send", args: ["<pid|name>"], effect: .write,
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
        ControlCommand(name: "machine-hook", args: ["disable|restore|kill", "<owner>"], options: ["--yes"], effect: .destructive,
                       summary: "disable: move a tool's hook registrations out of ~/.claude/settings.json (a timestamped backup is written beside it); restore: put them back; kill: SIGTERM every live instance of its hooks and their helpers from the last `machine` sample (never a session's own pid), SIGKILL the survivors after 3 s. Refused without --yes.",
                       replyShape: "{result}"),
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
