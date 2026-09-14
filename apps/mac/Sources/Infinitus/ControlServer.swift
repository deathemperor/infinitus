import Foundation
import Network
import os
import AppKit
import InfinitusCore

/// The agent-facing control socket (user 2026-09-03). A same-user UNIX
/// socket in App Support; one JSON line per connection each way. Every
/// command runs on the main actor through the same AppModel / FleetState
/// calls the panes make, so an agent sees and changes exactly what the
/// popup shows. Dispatch table = `ControlCommand.all`; a command missing
/// here answers "not implemented" rather than silently succeeding.
@MainActor
final class ControlServer {
    private let launchedAt = Date()
    private unowned let model: AppModel
    private var listener: NWListener?
    /// The inode we bound — `heal()` checks the path still leads to it.
    private var boundInode: ino_t = 0
    private let queue = DispatchQueue(label: "infinitus.control")
    private var busy = false
    private var task: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    func start() {
        let url = ControlProtocol.socketURL()
        NSLog("Infinitus control: starting at %@", url.path)
        // sun_path is 104 bytes on Darwin; a longer path fails the bind
        // silently inside NWListener.
        guard url.path.utf8.count < 104 else {
            NSLog("Infinitus control: socket path too long (%d bytes): %@", url.path.utf8.count, url.path)
            return
        }
        let dir = url.deletingLastPathComponent()
        // The socket lives in its own 0700 directory: NWListener binds
        // asynchronously, so a mode set on the socket itself would leave
        // a window another local user could connect in (push review
        // 2026-09-03). The directory gate closes before the bind starts.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        // A stale socket from a crashed instance must not block the bind.
        unlink(url.path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: url.path)
        guard let listener = try? NWListener(using: params) else {
            NSLog("Infinitus control: couldn't open %@", url.path)
            return
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor in self.serve(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                chmod(url.path, 0o600)
                var st = stat()
                let inode = stat(url.path, &st) == 0 ? st.st_ino : 0
                Task { @MainActor in self?.boundInode = inode }
                NSLog("Infinitus control: listening at %@", url.path)
            case .failed(let error), .waiting(let error):
                // CI's e2e job sat on "socket never came up" with nothing
                // in the log (2026-09-03) — the bind's own verdict belongs there.
                NSLog("Infinitus control: listener %@: %@", "\(state)".hasPrefix("failed") ? "failed" : "waiting", "\(error)")
            default:
                NSLog("Infinitus control: listener %@", "\(state)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundInode = 0
        unlink(ControlProtocol.socketURL().path)
    }

    /// Re-bind when the path no longer leads to a live listener. Another
    /// Infinitus instance — a debug binary launched without
    /// INFINITUS_CONTROL_SOCKET — unlinks and re-binds this path on start;
    /// killed, it leaves an inode nobody answers, and every infinitusctl
    /// and phone control call got "connection refused" until a relaunch
    /// (2026-09-03, the bundle sat that way for 25 minutes). Called after
    /// every snapshot, so the cost is one stat and one connect per
    /// refresh. A LIVE foreign listener is left alone: two instances must
    /// not fight over the path.
    func heal() {
        guard listener != nil, boundInode != 0 else { return }
        let path = ControlProtocol.socketURL().path
        var st = stat()
        let why: String
        if stat(path, &st) == 0 {
            if st.st_ino == boundInode {
                // Our inode, but does it answer? A listener whose socket
                // died under it (#637: `Connection refused` mid-run with
                // the path intact and nothing logged) looked healthy to
                // the inode check forever. One connect per snapshot.
                if Self.answers(path) { return }
                why = "our own inode \(boundInode) refuses"
            } else if Self.answers(path) {
                NSLog("Infinitus control: another instance listens at %@; leaving it", path)
                return
            } else {
                why = "inode \(st.st_ino) is not ours (\(boundInode)), nobody answers"
            }
        } else {
            why = String(cString: strerror(errno))
        }
        // The reason is the next flake's evidence (#265: two re-binds in a
        // run with no dev instance around, cause unknown).
        NSLog("Infinitus control: socket path lost at %@ (%@); rebinding", path, why)
        listener?.cancel()
        listener = nil
        boundInode = 0
        start()
    }

    /// Does anything accept on this UNIX socket path? (One connect; a
    /// live ControlServer just sees an empty request and drops it.)
    private static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let fits = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                path.withCString { strlcpy(dst, $0, capacity) } < capacity
            }
        }
        guard fits else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { conn.cancel(); return }
            Task { @MainActor in
                let reply = await self.handle(line: data)
                let bytes = (try? ControlCodec.encode(reply)) ?? Data("{\"ok\":false}\n".utf8)
                conn.send(content: bytes, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    private static let log = Logger(subsystem: "run.infinitus", category: "control")
    /// One formatter for every timestamp the verbs emit: a fresh
    /// ISO8601DateFormatter is an ICU `udat_open` each time, and `events`
    /// built one per row on every desktop-app poll (#346's sample).
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private func handle(line: Data) async -> ControlReply {
        let request: ControlRequest
        do { request = try ControlCodec.decode(ControlRequest.self, from: line) }
        catch { return .failure("bad request: \(error)") }
        guard let command = ControlCommand.named(request.command) else {
            return .failure("unknown command \(request.command); run `infinitusctl manifest`")
        }
        if command.effect != .read, !(request.command == "prefs" && request.args.first == "get") {
            // The verb and its target, never a value (`prefs set <key>`
            // shows the key; secrets ride `secret`, not argv): a relaunch
            // or a wedge can then be traced to its request from our side
            // (#654: the 11:30 relaunch had no native record of its caller).
            let shown = request.args.prefix(request.command == "prefs" ? 2 : 1).joined(separator: " ")
            Self.log.notice("\(request.command, privacy: .public) \(shown, privacy: .public)")
        }
        // One write at a time; reads run alongside. The desktop app polls
        // status/fleets/events/sessions continuously, and a blanket guard
        // handed the CLI (and the phone) "busy" whenever a poll was in
        // flight — a `perf` probe hit it on the live bundle (#346).
        if command.effect != .read {
            guard !busy else { return .failure("busy: another control command is running") }
            busy = true
        }
        defer { if command.effect != .read { busy = false } }
        do { return try await dispatch(request) }
        catch { return .failure((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    // MARK: dispatch

    private struct Fail: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// The lock's current state, for `lock-status`/`lock on|off|now|relock|unlock`.
    private func lockReply() -> ControlReply {
        let policy = model.lock.policy
        return ControlReply(ok: true, result: .object([
            "enabled": .bool(policy.enabled),
            "locked": .bool(policy.locked),
            "relock": .string(policy.relock.label),
        ]))
    }

    private func dispatch(_ r: ControlRequest) async throws -> ControlReply {
        switch r.command {
        case "manifest":
            return ControlReply(ok: true, result: try .of([
                "schemaVersion": JSONValue.number(Double(ControlProtocol.schemaVersion)),
                "commands": try .of(ControlCommand.all),
            ] as [String: JSONValue]))

        case "status":
            return ControlReply(ok: true, result: try .of(status()))

        case "fleets":
            return ControlReply(ok: true, result: try .of(fleetsPayload()))

        case "plan":
            // Wrapped: a bare null result prints as nothing in infinitusctl.
            return ControlReply(ok: true, result: .object([
                "plan": try model.battlePlan.map { try .of(WindowPlanner.Payload($0)) } ?? .null]))

        case "forecast":
            return ControlReply(ok: true, result: .object([
                "forecast": try model.forecast.map { try .of($0) } ?? .null]))

        case "refresh":
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: try .of(fleetsPayload()))

        case "quit":
            // Answer first: shutdown() ends the listener with the process.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                model.shutdown()
            }
            return ControlReply(ok: true, result: try .of(["quitting": true]))

        case "push":
            // #269 G: the desktop's thread phase changes ride the Mac's
            // own pusher, so they get its gating and every channel on.
            // #1047: its thread card state rides the same verb to the
            // phone's lock screen — no Notification Center line for it.
            // The reply says what was addressed: `targets` phones and the
            // requests per token kind, 0 when nobody is registered (a
            // synthetic push into nothing used to read as a success).
            if let payload = r.secret, let activity = ThreadActivityPush.parse(payload) {
                let reach: PushReach
                switch activity {
                case .show(let state):
                    reach = model.liveActivityPusher.pushAgentActivity(state)
                    model.desktopActiveThreads = state.activeCount
                case .end:
                    reach = model.liveActivityPusher.pushAgentActivity(nil)
                    model.desktopActiveThreads = 0
                }
                return ControlReply(ok: true, result: .object(
                    ["pushed": .bool(true), "card": .bool(true)].merging(reach.replyFields) { _, new in new }))
            }
            guard let payload = r.secret, let push = ThreadPhasePush.parse(payload) else {
                throw Fail("push: {kind: \"thread.phase\", threadId, title, phase, detail?} or {kind: \"thread.activity\", state} is expected on stdin")
            }
            let reach = model.push(push.line)
            return ControlReply(ok: true, result: .object(
                ["pushed": .bool(true)].merging(reach.replyFields) { _, new in new }))

        case "switch", "hold", "unhold", "rename", "remove":
            let (fleet, n) = try target(r)
            let need: EngineCapabilities = ["switch": .switch, "hold": .hold, "unhold": .hold,
                                            "rename": .rename, "remove": .remove][r.command]!
            guard fleet.capabilities.contains(need) else {
                throw Fail("\(fleet.id) does not support \(r.command)")
            }
            guard fleet.accounts.contains(where: { $0.number == n }) else {
                throw Fail("no account #\(n) in \(fleet.id)")
            }
            switch r.command {
            case "switch": try await fleet.engine.switchTo(fleet: fleet.provider, number: n)
            case "hold": try await fleet.engine.setHold(fleet: fleet.provider, number: n, held: true)
            case "unhold": try await fleet.engine.setHold(fleet: fleet.provider, number: n, held: false)
            case "rename":
                guard r.args.count >= 3 else { throw Fail("usage: rename <fleet> <n> <alias>") }
                try await fleet.engine.rename(fleet: fleet.provider, number: n, r.args[2])
            case "remove":
                guard r.options["yes"] != nil else { throw Fail("remove deletes the credential; pass --yes") }
                try await fleet.engine.remove(fleet: fleet.provider, number: n)
            default: break
            }
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: try .of(["fleet": fleetPayload(fleet)]))

        case "randomize-names":
            guard let key = r.args.first, let fleet = model.fleets.first(where: { $0.id == key }) else {
                throw Fail("usage: randomize-names <fleet> [n]")
            }
            guard fleet.capabilities.contains(.rename) else { throw Fail("\(fleet.id) does not support rename") }
            var targets = fleet.accounts
            var taken = Set<String>()
            if r.args.count > 1 {
                // One account re-rolls alone (#145): it skips every name the
                // fleet wears, its own included, so the roll visibly lands.
                guard let n = Int(r.args[1]), let one = fleet.accounts.first(where: { $0.number == n }) else {
                    throw Fail("no account #\(r.args[1]) in \(fleet.id)")
                }
                targets = [one]
                taken = Set(fleet.accounts.compactMap(\.alias).filter { !$0.isEmpty })
            }
            let names = model.rowTheme.randomAccountNames(count: targets.count, avoiding: taken)
            for (account, name) in zip(targets, names) {
                try await fleet.engine.rename(fleet: fleet.provider, number: account.number, name)
            }
            await model.refreshSnapshot()
            struct Payload: Encodable { let fleet: FleetPayload; let names: [String] }
            return ControlReply(ok: true, result: try .of(Payload(fleet: fleetPayload(fleet), names: names)))

        case "rotate":
            let fleet = try fleet(r)
            guard fleet.capabilities.contains(.rotate) else { throw Fail("\(fleet.id) does not support rotate") }
            try await fleet.engine.rotate(fleet: fleet.provider)
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: try .of(["fleet": fleetPayload(fleet)]))

        case "history":
            let fleet = try fleet(r)
            guard fleet.capabilities.contains(.history), let swapd = fleet.engine as? SwapdEngine else {
                throw Fail("\(fleet.id) keeps no switch history")
            }
            var limit: Int?
            if let raw = r.options["limit"] {
                guard let n = Int(raw), n > 0 else { throw Fail("usage: history <fleet> [--limit <n>]") }
                limit = n
            }
            let history = try JSONDecoder().decode(JSONValue.self,
                from: try await swapd.cli.historyData(provider: fleet.provider, limit: limit))
            return ControlReply(ok: true, result: .object(["fleet": .string(fleet.id), "history": history]))

        case "reorder":
            let fleet = try fleet(r)
            guard fleet.capabilities.contains(.reorder) else { throw Fail("\(fleet.id) has no rotation order") }
            let order = r.args.dropFirst().compactMap(Int.init)
            let have = fleet.accounts.map(\.number)
            guard order.count == r.args.count - 1, order.count == have.count, Set(order) == Set(have) else {
                throw Fail("reorder needs every account number exactly once, top first: \(have.sorted().map(String.init).joined(separator: " "))")
            }
            try await fleet.engine.reorder(fleet: fleet.provider, order)
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: try .of(["fleet": fleetPayload(fleet)]))

        case "prefer":
            let (fleet, n) = try target(r)
            guard fleet.capabilities.contains(.prefer) else { throw Fail("\(fleet.id) has no pick-first setting") }
            guard r.args.count >= 3, ["on", "off"].contains(r.args[2]) else { throw Fail("usage: prefer <fleet> <n> on|off") }
            guard let account = fleet.accounts.first(where: { $0.number == n }) else { throw Fail("no account #\(n) in \(fleet.id)") }
            guard account.preferred != nil else {
                throw Fail("the engine reports no pick-first flag for \(fleet.id)")
            }
            try await fleet.engine.setPreferred(fleet: fleet.provider, number: n, r.args[2] == "on")
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: try .of(["fleet": fleetPayload(fleet)]))

        case "crashes":
            return ControlReply(ok: true, result: try .of(["crashes": model.crashReports.map { r in
                CrashListing(id: r.id, platform: r.platform, device: r.device, at: r.at, kind: r.kind,
                             reason: r.reason, frames: r.frames) }]))

        case "aws-logins":
            return ControlReply(ok: true, result: try .of(["logins": model.awsLogins]))

        case "aws-login", "gcloud-login":
            // #367: the same login machinery for both CLIs; gcloud's
            // <profile> is an account, "default" for the active one, or
            // "application-default" for the library credentials.
            let provider: AwsLogin.Provider = r.command == "gcloud-login" ? .gcloud : .aws
            guard let profile = r.args.first, !profile.isEmpty else {
                throw Fail("usage: \(r.command) <\(provider == .aws ? "profile" : "account|application-default")> [--local] [--remote] [--status]")
            }
            // --status: the phone's flag-less poll — report, start nothing.
            let reply = await model.startAwsLogin(provider: provider, profile: profile, pid: nil, local: r.options["local"] == "true",
                                                  remote: r.options["status"] == "true" ? nil : r.options["remote"] == "true")
            guard reply.ok, let state = reply.state else { throw Fail(reply.error ?? "could not start") }
            return ControlReply(ok: true, result: try .of(["state": state]))

        case "aws-login-callback":
            guard let profile = r.args.first, let url = r.secret, !url.isEmpty else {
                throw Fail("usage: aws-login-callback <profile|account>  (the intercepted http://127.0.0.1:<port>/oauth/callback?… or http://localhost:8085/?… URL on stdin)")
            }
            // The outstanding item for that profile says which CLI's listener the callback is for.
            let items = await MainActor.run { model.awsLogins }
            let provider = AwsLogin.inferProvider(profile: profile, items: items)
            let reply = await model.awsLoginRunner.relay(provider: provider, profile: profile, url: url)
            guard reply.ok, let state = reply.state else { throw Fail(reply.error ?? "not accepted") }
            return ControlReply(ok: true, result: try .of(["state": state]))

        case "aws-login-code", "gcloud-login-code":
            guard let profile = r.args.first, let code = r.secret, !code.isEmpty else {
                throw Fail("usage: \(r.command) <profile>  (code on stdin)")
            }
            let reply = await model.submitAwsLoginCode(provider: r.command == "gcloud-login-code" ? .gcloud : .aws,
                                                       profile: profile, code: code)
            guard reply.ok, let state = reply.state else { throw Fail(reply.error ?? "not accepted") }
            return ControlReply(ok: true, result: try .of(["state": state]))

        case "ignite":
            let (fleet, n) = try target(r)
            guard fleet.capabilities.contains(.ignite) else { throw Fail("\(fleet.id) cannot ignite (no per-account request verb)") }
            guard fleet.accounts.contains(where: { $0.number == n }) else { throw Fail("no account #\(n) in \(fleet.id)") }
            // Publishes the fresh account itself when the engine can
            // refresh one, so the reply carries the window the run just
            // opened rather than the row from before it.
            try await model.igniteAndPublish(fleet, number: n)
            return ControlReply(ok: true, result: try .of(["fleet": fleetPayload(fleet)]))

        case "add":
            guard let key = r.args.first,
                  let fleet = model.fleets.first(where: { $0.id == key }) else {
                throw Fail("usage: add <fleet>; fleets: \(model.fleets.map(\.id).joined(separator: ", "))")
            }
            guard !TokenFlow.shared.running, !model.addingFirstAccount else {
                throw Fail("a sign-in is already running")
            }
            if fleet.capabilities.contains(.addOAuth) {
                model.addOAuthAccount(engineID: fleet.engineID, provider: fleet.provider)
            } else if fleet.capabilities.contains(.addCurrent) {
                model.addFirstAccount()
            } else {
                throw Fail("\(key) has no sign-in flow")
            }
            return ControlReply(ok: true, result: .object(["started": .bool(true)]))

        case "wait-add":
            let timeout = Double(r.options["timeout"] ?? "") ?? 300
            let deadline = Date().addingTimeInterval(timeout)
            while (TokenFlow.shared.running || model.addingFirstAccount), Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            let stillRunning = TokenFlow.shared.running || model.addingFirstAccount
            let error = model.firstAccountMessage
            return ControlReply(ok: !stillRunning && error == nil, result: try .of([
                "done": JSONValue.bool(!stillRunning),
                "error": error.map(JSONValue.string) ?? (stillRunning ? .string("timed out") : .null),
                "fleets": try .of(fleetsPayload()),
            ] as [String: JSONValue]), error: stillRunning ? "timed out after \(Int(timeout))s" : error)

        case "signin-begin":
            guard let key = r.args.first,
                  let fleet = model.fleets.first(where: { $0.id == key }) else {
                throw Fail("usage: signin-begin <fleet> [--relogin <email>]; fleets: \(model.fleets.map(\.id).joined(separator: ", "))")
            }
            let flow = TokenFlow.shared
            guard !flow.running, !model.addingFirstAccount else {
                throw Fail("a sign-in is already running")
            }
            var relogin: Account?
            if let email = r.options["relogin"] {
                guard let account = fleet.accounts.first(where: { $0.email == email }) else {
                    throw Fail("\(key) has no account \(email)")
                }
                relogin = account
            }
            if fleet.capabilities.contains(.addOAuth) {
                model.addOAuthAccount(engineID: fleet.engineID, provider: fleet.provider,
                                      relogin: relogin, headless: true)
            } else if fleet.capabilities.contains(.addCurrent) {
                flow.start(model: model, relogin: relogin, headless: true)
            } else {
                throw Fail("\(key) has no sign-in flow")
            }
            guard let flowID = flow.flowID, flow.running || flow.authURL != nil else {
                throw Fail("the sign-in did not start")
            }
            // The OAuth URL arrives once the CLI (or the engine) hands it
            // over — a second or two; the caller gets it in this reply.
            let urlDeadline = Date().addingTimeInterval(30)
            while flow.authURL == nil, flow.running, Date() < urlDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if case .failed(let why) = flow.phase { throw Fail(why) }
            guard let url = flow.authURL else {
                flow.cancel()
                throw Fail("no sign-in URL within 30s")
            }
            return ControlReply(ok: true, result: .object([
                "flowId": .string(flowID),
                "url": .string(url.absoluteString),
                "pasteCode": .bool(flow.pasteCode),
                "label": .string(flow.reloginTarget.map { "Sign in again \u{2014} \($0)" } ?? "Add account"),
            ]))

        case "signin-status":
            return ControlReply(ok: true, result: signinPayload(try signinFlow(r)))

        case "signin-code":
            let flow = try signinFlow(r)
            guard let code = r.secret?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                throw Fail("signin-code: the code is expected on stdin")
            }
            guard flow.pasteCode else { throw Fail("this sign-in takes no code — it finishes on its own") }
            guard case .awaitingLogin = flow.phase else {
                throw Fail("not waiting for a code (\(signinPhase(flow).phase))")
            }
            flow.code = code
            flow.submitCode()
            // The CLI answers a bad paste within a second ("Invalid code…",
            // "OAuth error: …"); a good one moves on to registering.
            let codeDeadline = Date().addingTimeInterval(15)
            while Date() < codeDeadline {
                if let err = flow.codeError {
                    return ControlReply(ok: false, result: .object(["ok": .bool(false), "error": .string(err)]), error: err)
                }
                guard case .waitingForToken = flow.phase else { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if case .failed(let why) = flow.phase {
                return ControlReply(ok: false, result: .object(["ok": .bool(false), "error": .string(why)]), error: why)
            }
            return ControlReply(ok: true, result: .object(["ok": .bool(true)]))

        case "signin-cancel":
            let flow = try signinFlow(r)
            flow.cancel()
            return ControlReply(ok: true, result: .object(["cancelled": .bool(true)]))

        case "windows":
            struct Win: Encodable {
                let number: Int, title: String, `class`: String
                let visible: Bool, occluded: Bool, level: Int
                let size: [Double], content: String
            }
            let rows = NSApp.windows.map { w in
                Win(number: w.windowNumber, title: w.title,
                    class: String(describing: type(of: w)),
                    visible: w.isVisible,
                    occluded: !w.occlusionState.contains(.visible),
                    level: w.level.rawValue,
                    size: [w.frame.width, w.frame.height],
                    content: w.contentView.map { String(describing: type(of: $0)) } ?? "-")
            }
            return ControlReply(ok: true, result: try .of(rows))

        case "events":
            // The switch log Infinitus2 had to reconstruct from
            // usage-history (2026-09-04 "auto switch hell").
            let limit = Int(r.options["limit"] ?? "") ?? 100
            func row(_ e: AppModel.EventEntry) -> JSONValue {
                // `kind` is the durable log's vocabulary (switch, limit,
                // revival, nudge…) and `id` holds for this app run,
                // so a consumer classifies and dedupes without reading
                // icons or text (#615).
                .object(["id": .string(e.id.uuidString),
                         "at": .string(Self.iso.string(from: e.at)),
                         "kind": .string(e.kind), "icon": .string(e.icon), "text": .string(e.text)])
            }
            // `--after <id>`: only the rows past that event, so a poller
            // stops re-reading 100 rows every cycle (#346). An unknown id
            // (the app relaunched, or the row aged out of the 100 kept)
            // answers `known: false` with the full tail so the caller
            // re-seeds its cursor.
            if let after = r.options["after"] {
                let index = model.eventLog.firstIndex { $0.id.uuidString == after }
                let fresh = index.map { Array(model.eventLog[($0 + 1)...]) } ?? model.eventLog
                return ControlReply(ok: true, result: .object([
                    "after": .string(after), "known": .bool(index != nil),
                    "rows": .array(fresh.suffix(max(0, limit)).map(row))]))
            }
            return ControlReply(ok: true, result: .array(model.eventLog.suffix(max(0, limit)).map(row)))

        case "stats":
            let period = Stats.Period(rawValue: r.options["period"] ?? "week") ?? .week
            model.statsModel.loadIfNeeded()
            let summary = model.statsModel.summaries[period]
                ?? Stats.fold(days: model.statsModel.days, period: period)
            // Compacted: `DayPoint.day` carries the 168-slot histogram
            // and the session set, which made `--period year` ~0.5 MB.
            return ControlReply(ok: true, result: try .of(summary.compacted()))

        case "utilization":
            // #747: the Utilization pane's figures, computed here, for the
            // desktop app's page — history is file IO, so off the main actor.
            let days = r.options["days"].flatMap(Int.init) ?? 7
            guard (1...90).contains(days) else { throw Fail("usage: utilization [--days <1|7|30>]") }
            let now = Date().timeIntervalSince1970
            var snap = await Task.detached(priority: .utility) {
                var snap = UtilizationModel.compute(days: days, now: now)
                snap.rates = TokenRateScanner.scan(projectsDir: TokenRateScanner.defaultProjectsDir(),
                                                   cacheURL: UtilizationModel.ratesCacheURL)
                return snap
            }.value
            snap.liveRate = LiveForecastRelay.shared.tokenRate
            return ControlReply(ok: true, result: try .of(snap))

        case "perf":
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            let rss = kr == KERN_SUCCESS ? Double(info.resident_size) : -1
            var threadList: thread_act_array_t?
            var threadCount = mach_msg_type_number_t(0)
            task_threads(mach_task_self_, &threadList, &threadCount)
            if let threadList {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList),
                              vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
            }
            // Live malloc bytes: RSS swings with page-ins and caches, the
            // heap is what a leak actually moves (the e2e growth gate).
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return ControlReply(ok: true, result: .object([
                "cpuSeconds": .number(cpu),
                "leases": .number(Double(model.leases.clientCount())),
                "leaseScopes": .object(model.leases.held().mapValues { .array($0.map { .string($0) }) }),
                "rssBytes": .number(rss),
                "heapBytes": .number(Double(stats.size_in_use)),
                "threads": .number(Double(threadCount)),
                "uptimeSeconds": .number(Date().timeIntervalSince(launchedAt)),
            ]))

        case "lock-status":
            return lockReply()

        case "lock":
            // #747: the fork's Lock pane drives the biometric lock through
            // these; `on` and `unlock` run the prompt on this Mac.
            switch r.args.first {
            case "on":
                if !model.lock.enabled {
                    let on = await model.lock.turnOn()
                    guard on else { throw Fail(model.lock.lastError ?? "the unlock prompt was cancelled") }
                }
            case "off":
                model.lock.turnOff()
            case "now":
                model.lock.lockNow()
            case "relock":
                let choices: [String: LockPolicy.Relock] = ["immediately": .immediately, "5m": .fiveMinutes,
                                                             "1h": .oneHour, "sleep": .onSleep]
                guard r.args.count >= 2, let relock = choices[r.args[1]] else {
                    throw Fail("usage: lock relock immediately|5m|1h|sleep")
                }
                model.lock.relock = relock
            default:
                throw Fail("usage: lock on|off|now|relock immediately|5m|1h|sleep")
            }
            return lockReply()

        case "unlock":
            guard model.lock.enabled else { throw Fail("the lock is off") }
            guard model.lock.policy.locked else { return lockReply() }
            await model.lock.unlock()
            if let err = model.lock.lastError { throw Fail(err) }
            guard !model.lock.policy.locked else { throw Fail("the unlock prompt was cancelled") }
            return lockReply()

        case "show":
            guard let controller = AppDelegate.shared?.statusHolder?.controller else {
                throw Fail("no status item yet")
            }
            switch r.args.first {
            case "popout": controller.showPinnedWindow()
            case "settings": controller.showSettingsWindow()
            case "wall", "workspace", "session":
                throw Fail("retired: the wall, workspace and session windows moved to the Infinitus desktop app")
            default: throw Fail("usage: show popout|settings")
            }
            return ControlReply(ok: true, result: .object(["shown": .string(r.args[0])]))

        case "activities-token":
            // `--forget <deviceId>/<kind>` withdraws one registration (#572
            // G6); idempotent, so a phone that never registered here can
            // still switch its alerts off.
            if let slot = r.options["forget"] {
                let forgotten = model.liveActivityPusher.forget(slot: slot)
                return ControlReply(ok: true, result: .object(["slot": .string(slot), "forgotten": .bool(forgotten)]))
            }
            // The mirror's `POST /activities/token`, for a client on the
            // socket (#572 N1): the same decode, the same registration.
            let registration = try ControlBody.decode(ActivityPushRegistration.self, from: r)
            model.liveActivityPusher.register(registration)
            return ControlReply(ok: true, result: .object(["slot": .string(registration.slot)]))

        case "client-activity":
            let report = try ControlBody.decode(ClientActivity.Report.self, from: r)
            model.leases.report(report)
            return ControlReply(ok: true, result: .object(["clientId": .string(report.clientId)]))

        case "crash-report":
            let report = try ControlBody.decode(CrashReport.self, from: r, cap: 2 * CrashReport.rawCap)
            model.ingestCrash(report, announce: true)
            return ControlReply(ok: true, result: .object(["id": .string(report.id)]))

        case "prefs", "prefs-set":
            // `prefs` lists every entry; `prefs get k…` only those keys;
            // `prefs set k v` (= `prefs-set k v`) writes one.
            var args = r.args
            if r.command == "prefs-set" { args.insert("set", at: 0) }
            do {
                if args.first == "set" {
                    guard args.count == 3 else { throw Fail("usage: prefs set <key> <value>") }
                    // #1137: a fork-server port the app cannot reach is not
                    // followed — the tunnel and the CLI credential would both
                    // point at a closed port until the app was relaunched.
                    if args[1] == "fork_server_port", let port = Int(args[2]),
                       await !model.acceptsForkServerPublish(port: port) {
                        throw Fail(ForkServerProbe.refusalReply(port: port))
                    }
                    let (pref, restarting) = try model.setPref(key: args[1], value: PrefCatalog.parseValue(args[2]))
                    return ControlReply(ok: true, result: try .of(pref), restarting: restarting)
                }
                var keys: [String]? = nil
                if args.first == "get" {
                    keys = Array(args.dropFirst())
                    if keys!.isEmpty { throw Fail("usage: prefs [get <key>...|set <key> <value>]") }
                } else if !args.isEmpty {
                    throw Fail("usage: prefs [get <key>...|set <key> <value>]")
                }
                return ControlReply(ok: true, result: try .of(model.prefsReply(keys: keys)))
            } catch let unknown as PrefCatalog.UnknownKey {
                throw Fail("unknown pref \(unknown.key)")
            } catch let violation as PrefCatalog.Violation {
                throw Fail(violation.message)
            }

        case "hide":
            guard let controller = AppDelegate.shared?.statusHolder?.controller else {
                throw Fail("no status item yet")
            }
            switch r.args.first {
            case "popout": controller.hidePinnedWindow()
            case "settings": controller.hideSettingsWindow()
            case "workspace":
                throw Fail("retired: the workspace window moved to the Infinitus desktop app")
            default: throw Fail("usage: hide popout|settings")
            }
            return ControlReply(ok: true, result: .object(["hidden": .string(r.args[0])]))

        case "engine":
            guard r.args.count == 2, ["on", "off"].contains(r.args[1]) else {
                throw Fail("usage: engine swapd|cliproxy|9router on|off")
            }
            let on = r.args[1] == "on"
            let changed: Bool
            do { changed = try model.setEngineEnabled(r.args[0], on: on) }
            catch let refused as PrefCatalog.Violation { throw Fail(refused.message) }
            guard changed else { return ControlReply(ok: true, result: .object(["unchanged": .bool(true)])) }
            return ControlReply(ok: true, result: .object(["restarting": .bool(true)]), restarting: true)

        case "proxy":
            var out: [String: JSONValue] = [
                "baseURL": .string(model.cliproxyBaseURL),
                "keyPresent": .bool(model.cliproxyKeyPresent),
                "enabled": .bool(model.cliproxyEnabled),
            ]
            if let s = model.proxyRoutingStrategy { out["routingStrategy"] = .string(s) }
            if let e = model.engineErrors[CLIProxyEngine.engineID] { out["error"] = .string(e) }
            return ControlReply(ok: true, result: .object(out))

        case "9router":
            // The proxy's read verb for the other engine. Its error was
            // reachable only from the Mac's own Settings pane, so a
            // 9Router that had stopped refreshing could not be diagnosed
            // from the CLI, the phone or the desktop app at all.
            var out: [String: JSONValue] = [
                "baseURL": .string(model.nineRouterBaseURL),
                "passwordPresent": .bool(model.nineRouterPasswordPresent),
                "enabled": .bool(model.nineRouterEnabled),
            ]
            if let e = model.engineErrors[NineRouterEngine.engineID] { out["error"] = .string(e) }
            return ControlReply(ok: true, result: .object(out))

        case "proxy-key":
            let url = r.options["url"] ?? model.cliproxyBaseURL
            model.saveCLIProxy(baseURL: url, key: r.secret ?? "")
            return ControlReply(ok: true, result: .object(["restarting": .bool(true)]), restarting: true)

        case "9router-password":
            let url = r.options["url"] ?? model.nineRouterBaseURL
            model.saveNineRouter(baseURL: url, password: r.secret ?? "")
            return ControlReply(ok: true, result: .object(["restarting": .bool(true)]), restarting: true)

        case "proxy-routing":
            guard let strategy = r.args.first, CLIProxyEngine.routingStrategies.contains(strategy) else {
                throw Fail("usage: proxy-routing \(CLIProxyEngine.routingStrategies.joined(separator: "|"))")
            }
            guard let proxy = model.registry.engine(id: CLIProxyEngine.engineID) as? CLIProxyEngine else {
                throw Fail("the CLIProxyAPI engine is off")
            }
            try await proxy.setRoutingStrategy(strategy)
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: .object(["routingStrategy": .string(strategy)]))

        case "apns":
            // #1178: the push setup for the Devices page — the key ids,
            // whether the .p8 is in the keychain, the phones registered.
            // Never a token: a registration's token is the phone's push
            // address.
            let pusher = model.liveActivityPusher
            return ControlReply(ok: true, result: .object(ApnsStatus.fields(
                keyPresent: pusher.keyStored, teamId: pusher.teamID, keyId: pusher.keyID,
                registrations: Array(pusher.registrations.values))))

        case "apns-key":
            // #1178: the .p8 rides stdin, never argv; empty stdin forgets it.
            // Stored under the key id, so that pref comes first.
            let pusher = model.liveActivityPusher
            guard !pusher.keyID.isEmpty else { throw Fail("set the key id first (prefs set apns_key_id <id>)") }
            let pem = r.secret ?? ""
            let forgetting = pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            pusher.storeKey(pem: pem)
            guard forgetting || pusher.keyStored else { throw Fail(pusher.lastResult ?? "couldn't store the key") }
            return ControlReply(ok: true, result: .object(["stored": .bool(pusher.keyStored)]))
        case "test-connection":
            // #1177: the fork's Engines page probes with the keychain
            // credential; the reply never carries it, only the engine's words.
            guard r.args.count == 1, ConnectionTest.targets.contains(r.args[0]) else {
                throw Fail("usage: test-connection cliproxy|9router [--url <base URL>]")
            }
            let target = r.args[0]
            let stored = target == "cliproxy" ? model.cliproxyBaseURL : model.nineRouterBaseURL
            let urlString = r.options["url"] ?? stored
            guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
                return ControlReply(ok: true, result: .object(
                    ConnectionTest.Reply.failed("That isn't a valid address \u{2014} it should look like "
                        + (target == "cliproxy" ? CLIProxyEngine.defaultBaseURL : NineRouterEngine.defaultBaseURL).absoluteString
                        + ".").fields))
            }
            let credential = target == "cliproxy"
                ? Keychain.read(account: stored)
                : Keychain.read(account: stored, service: Keychain.nineRouterService)
            guard let credential, !credential.isEmpty else {
                return ControlReply(ok: true, result: .object(ConnectionTest.Reply.failed(
                    target == "cliproxy" ? "No management key is stored. Save one first, then test."
                                         : "No dashboard password is stored. Save one first, then test.").fields))
            }
            let started = Date()
            let reply: ConnectionTest.Reply
            do {
                if target == "cliproxy" {
                    let engine = CLIProxyEngine(baseURL: url, managementKey: credential)
                    _ = try await ConnectionTest.withDeadline { try await engine.probe() }
                } else {
                    let engine = NineRouterEngine(baseURL: url, password: credential)
                    _ = try await ConnectionTest.withDeadline { try await engine.probe() }
                }
                reply = .reached(latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            } catch is ConnectionTest.TimedOut {
                reply = .failed("The engine didn't answer within \(Int(ConnectionTest.timeoutSeconds)) s. Check it is running and its address is right, then try again.")
            } catch {
                reply = .failed(EngineFailure.sentence(error))
            }
            return ControlReply(ok: true, result: .object(reply.fields))

        case "desktop-credential":
            // #822: the desktop's own push at port publish (or a hand-fed
            // token); the secret rides stdin, never argv. Empty stdin forgets.
            let token = r.secret ?? ""
            let origin = r.options["origin"] ?? model.desktopCredential.origin ?? "http://127.0.0.1:\(model.forkServerPort)"
            guard token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (r.options["origin"].map { $0 != "true" && !$0.isEmpty } ?? true) else {
                throw Fail("usage: desktop-credential --origin <http://127.0.0.1:port> [--expiresAt <iso>]  (the token on stdin; empty stdin forgets it)")
            }
            let expiresAt = r.options["expiresAt"].flatMap { $0 == "true" ? nil : $0 }
            // #1137: the origin carries the same port the publish just set, so
            // after an accepted `prefs set` this probes nothing. After a
            // refused one it refuses too, rather than leaving the CLI pointed
            // at a port the tunnel was kept away from. Forgetting (empty
            // stdin) is never refused — it takes no target anywhere.
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let port = URL(string: origin)?.port,
               await !model.acceptsForkServerPublish(port: port) {
                throw Fail(ForkServerProbe.refusalReply(port: port))
            }
            if let why = model.desktopCredential.store(origin: origin, expiresAt: expiresAt, token: token) { throw Fail(why) }
            return ControlReply(ok: true, result: .object([
                "origin": model.desktopCredential.origin.map(JSONValue.string) ?? .null,
                "expiresAt": model.desktopCredential.expiresAt.map(JSONValue.string) ?? .null,
                "stored": .bool(model.desktopCredential.stored),
            ]))

        case "desktop-status":
            let credential = model.desktopCredential
            let origin = credential.origin
            // Stale: the desktop moved port since it handed the credential over.
            let stale = origin.flatMap { URL(string: $0)?.port }.map { $0 != model.forkServerPort } ?? false
            return ControlReply(ok: true, result: .object([
                "origin": origin.map(JSONValue.string) ?? .null,
                "port": .number(Double(model.forkServerPort)),
                "credential": credential.masked.map(JSONValue.string) ?? .null,
                "expiresAt": credential.expiresAt.map(JSONValue.string) ?? .null,
                "stale": .bool(stale),
            ]))

        case "desktop-token":
            // The dispatcher has one entry, the Unix socket (the phone goes
            // through the mirror), so every request here is local.
            guard let origin = model.desktopCredential.origin, let token = model.desktopCredential.token() else {
                throw Fail("no Infinitus desktop credential — launch Infinitus desktop")
            }
            return ControlReply(ok: true, result: .object([
                "origin": .string(origin), "token": .string(token),
                "expiresAt": model.desktopCredential.expiresAt.map(JSONValue.string) ?? .null,
            ]))

        default:
            return .failure("\(r.command) is in the manifest but not implemented")
        }
    }

    // MARK: payloads

    private func fleet(_ r: ControlRequest) throws -> FleetState {
        guard let key = r.args.first else { throw Fail("usage: \(r.command) <fleet> …") }
        guard let fleet = model.fleets.first(where: { $0.id == key }) else {
            throw Fail("no fleet \(key); fleets: \(model.fleets.map(\.id).joined(separator: ", "))")
        }
        return fleet
    }

    private func target(_ r: ControlRequest) throws -> (FleetState, Int) {
        guard r.args.count >= 2, let n = Int(r.args[1]) else {
            throw Fail("usage: \(r.command) <fleet> <n>")
        }
        return (try fleet(r), n)
    }

    private struct FleetPayload: Encodable {
        let key: String, engineID: String, provider: String
        let capabilities: [String]
        let caveat: String?
        let activeNumber: Int?, nextCandidate: Int?
        let candidateOrder: [Int]?
        let nextRecovery: NextRecovery?
        let accounts: [Account]
        let headroom: Headroom?
    }

    /// The running (or last) sign-in, when the caller names it.
    private func signinFlow(_ r: ControlRequest) throws -> TokenFlow {
        let flow = TokenFlow.shared
        guard let id = r.args.first, !id.isEmpty else { throw Fail("usage: \(r.command) <flowId>") }
        guard flow.flowID == id else { throw Fail("no sign-in \(id)") }
        return flow
    }

    /// The #677 phase names over TokenFlow.Phase.
    private func signinPhase(_ flow: TokenFlow) -> (phase: String, error: String?) {
        switch flow.phase {
        case .idle: return ("failed", "cancelled")
        case .launching: return ("starting", nil)
        case .awaitingLogin: return (flow.pasteCode ? "waitingForCode" : "waitingForToken", flow.codeError)
        case .waitingForToken: return ("waitingForToken", nil)
        case .registering: return ("registering", nil)
        case .done: return ("done", nil)
        case .failed(let why): return ("failed", why)
        }
    }

    private func signinPayload(_ flow: TokenFlow) -> JSONValue {
        let (phase, error) = signinPhase(flow)
        var d: [String: JSONValue] = [
            "flowId": .string(flow.flowID ?? ""),
            "phase": .string(phase),
            "pasteCode": .bool(flow.pasteCode),
        ]
        if let error { d["error"] = .string(error) }
        if let url = flow.authURL { d["url"] = .string(url.absoluteString) }
        if let email = flow.completedEmail { d["account"] = .string(email) }
        return .object(d)
    }

    private func fleetPayload(_ f: FleetState) -> FleetPayload {
        FleetPayload(key: f.id, engineID: f.engineID, provider: f.provider.rawValue,
                     capabilities: Self.names(f.capabilities),
                     caveat: model.fleetCaveats[f.engineID],
                     activeNumber: f.activeNumber, nextCandidate: f.nextCandidate,
                     candidateOrder: f.candidateOrder,
                     nextRecovery: f.nextRecovery, accounts: f.accounts,
                     headroom: f.headroom)
    }

    private func fleetsPayload() -> [FleetPayload] { model.fleets.map(fleetPayload) }

    private struct EngineStatus: Encodable {
        let enabled: Bool, registered: Bool, keyPresent: Bool?
    }
    private struct Status: Encodable {
        let version: String, sha: String
        let engines: [String: EngineStatus]
        let badge: String
        let signInRunning: Bool
        let playground: Bool
        let socket: String
        let forkTunnel: ForkTunnelStatus
        /// #777: where this process runs from, and whether that is inside
        /// the desktop bundle — the desktop's reconcile quits only its own.
        let bundlePath: String
        let nested: Bool
    }

    private func status() -> Status {
        let info = Bundle.main.infoDictionary ?? [:]
        return Status(
            version: info["CFBundleShortVersionString"] as? String ?? "dev",
            sha: info["InfinitusGitSHA"] as? String ?? info["CFBundleVersion"] as? String ?? "dev",
            engines: [
                "swapd": EngineStatus(enabled: model.swapdEnabled, registered: model.swapdRegistered,
                                      keyPresent: nil),
                "cliproxy": EngineStatus(enabled: model.cliproxyEnabled,
                                         registered: model.registry.engine(id: CLIProxyEngine.engineID) != nil,
                                         keyPresent: model.cliproxyKeyPresent),
                "9router": EngineStatus(enabled: model.nineRouterEnabled,
                                        registered: model.registry.engine(id: NineRouterEngine.engineID) != nil,
                                        keyPresent: model.nineRouterPasswordPresent),
            ],
            badge: model.engineBadge.map { "\($0)" } ?? "none",
            signInRunning: TokenFlow.shared.running || model.addingFirstAccount,
            playground: model.isPlayground,
            socket: ControlProtocol.socketURL().path,
            forkTunnel: model.forkTunnelStatus,
            bundlePath: Nesting.bundlePath,
            nested: Nesting.isNested)
    }

    static func names(_ caps: EngineCapabilities) -> [String] {
        let table: [(EngineCapabilities, String)] = [
            (.switch, "switch"), (.rotate, "rotate"), (.reorder, "reorder"), (.hold, "hold"),
            (.rename, "rename"), (.remove, "remove"), (.addCurrent, "addCurrent"),
            (.addToken, "addToken"), (.addOAuth, "addOAuth"), (.autoSwitch, "autoSwitch"),
            (.costReport, "costReport"), (.history, "history"), (.settings, "settings"),
            (.prefer, "prefer"), (.ignite, "ignite"), (.backup, "backup"),
            (.refreshAccount, "refreshAccount"),
        ]
        return table.filter { caps.contains($0.0) }.map(\.1)
    }
}

/// `crashes`: the reports without their raw diagnostic.
private struct CrashListing: Encodable {
    let id: String, platform: String, device: String, at: Date, kind: String, reason: String, frames: [String]
}
