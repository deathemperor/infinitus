import Foundation
import Network
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
    /// every snapshot, so the cost is one stat per refresh. A LIVE foreign
    /// listener is left alone: two instances must not fight over the path.
    func heal() {
        guard listener != nil, boundInode != 0 else { return }
        let path = ControlProtocol.socketURL().path
        var st = stat()
        if stat(path, &st) == 0 {
            if st.st_ino == boundInode { return }
            if Self.answers(path) {
                NSLog("Infinitus control: another instance listens at %@; leaving it", path)
                return
            }
        }
        NSLog("Infinitus control: socket path lost at %@; rebinding", path)
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

    private func handle(line: Data) async -> ControlReply {
        let request: ControlRequest
        do { request = try ControlCodec.decode(ControlRequest.self, from: line) }
        catch { return .failure("bad request: \(error)") }
        guard ControlCommand.named(request.command) != nil else {
            return .failure("unknown command \(request.command); run `infinitusctl manifest`")
        }
        guard !busy else { return .failure("busy: another control command is running") }
        busy = true
        defer { busy = false }
        do { return try await dispatch(request) }
        catch { return .failure((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    // MARK: dispatch

    private struct Fail: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// The snapshot after a team action, or the action's error.
    private func teamReply() throws -> ControlReply {
        if let err = model.team.lastError { throw Fail(err) }
        return ControlReply(ok: true, result: try model.team.snapshot.map { try JSONValue.of($0) } ?? .null)
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

        case "sessions":
            return ControlReply(ok: true, result: .array(model.sessionRows().map { row in
                .object(["pid": .number(Double(row.pid)), "name": row.name.map { .string($0) } ?? .null,
                         "cwd": .string(row.cwd), "status": row.status.map { .string($0) } ?? .null,
                         "kind": .string(row.kind)])
            }))

        case "past-sessions":
            let claudeDir = ClaudeSessions.configHome()
            let live = Set(ClaudeSessions.list(claudeDir: claudeDir).map(\.sessionId))
            let sessions = PastSessions.scan(claudeDir: claudeDir, liveIds: live,
                                             limit: r.options["limit"].flatMap(Int.init) ?? 50,
                                             search: r.options["search"])
            return ControlReply(ok: true, result: try .of(["sessions": sessions]))

        case "resume-session":
            guard let id = r.args.first, !id.isEmpty else { throw Fail("usage: resume-session <sessionId>") }
            let claudeDir = ClaudeSessions.configHome()
            // A live session's transcript is another process's to write —
            // talk to it instead of resuming it twice.
            if let live = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.sessionId == id }) {
                throw Fail("session \(id) is live (pid \(live.pid)); use `infinitusctl send \(live.pid)`")
            }
            guard let past = PastSessions.find(sessionId: id, claudeDir: claudeDir) else {
                throw Fail("no past session \(id); see `infinitusctl past-sessions`")
            }
            let reply = SessionLauncher.start(SessionStart.Request(cwd: past.cwd, resume: past.sessionId),
                                              preferredHost: model.sessionHost)
            return ControlReply(ok: reply.outcome == "started", result: try .of(reply),
                                error: reply.outcome == "started" ? nil : "\(reply.outcome)\(reply.detail.map { ": " + $0 } ?? "")")

        case "send":
            guard let text = r.secret, !text.isEmpty else { throw Fail("send: the message is expected on stdin") }
            guard let who = r.args.first, let pid = model.sessionPid(matching: who) else {
                throw Fail("no live session matches \(r.args.first ?? "?"); see `infinitusctl sessions`")
            }
            let reply = await model.send(SessionInput.Request(kind: .message, text: text),
                                         toPid: pid, icon: "💬", what: "control send")
            return ControlReply(ok: reply.outcome == "delivered", result: try .of(reply),
                                error: reply.outcome == "delivered" ? nil : "\(reply.outcome)\(reply.detail.map { ": " + $0 } ?? "")")

        case "machine":
            if let report = model.machineModel.report {
                return ControlReply(ok: true, result: try .of(report))
            }
            Task { await model.machineModel.sample() }
            return ControlReply(ok: true, result: .object(["sampling": .bool(true)]))

        case "machine-kill":
            guard let pidText = r.args.first, let pid = Int(pidText), pid > 1 else {
                throw Fail("usage: machine-kill <pid> --yes")
            }
            guard r.options["yes"] != nil else { throw Fail("machine-kill signals a process; pass --yes") }
            let result = await model.machineModel.killRunaway(pid: pid)
            return ControlReply(ok: true, result: .object(["result": .string(result)]))

        case "machine-reclaim":
            guard r.options["yes"] != nil else { throw Fail("machine-reclaim removes files; pass --yes") }
            let result = await model.machineModel.reclaim()
            return ControlReply(ok: true, result: .object(["result": .string(result)]))

        case "machine-hook":
            guard r.args.count >= 2, ["disable", "restore", "kill"].contains(r.args[0]) else {
                throw Fail("usage: machine-hook disable|restore|kill <owner> --yes")
            }
            guard r.options["yes"] != nil else { throw Fail("machine-hook edits settings.json or signals processes; pass --yes") }
            let owner = r.args[1]
            let result: String
            switch r.args[0] {
            case "disable": result = await model.machineModel.disableHook(owner: owner)
            case "kill": result = await model.machineModel.killHookInstances(owner: owner)
            default: result = await model.machineModel.restoreHook(owner: owner)
            }
            return ControlReply(ok: true, result: .object(["result": .string(result)]))

        case "approve":
            guard let payload = r.secret, let event = HookEvent.parse(payload), event.name == "PreToolUse",
                  let sessionId = event.sessionId, let tool = event.toolName else {
                throw Fail("approve: a PreToolUse hook payload is expected on stdin")
            }
            let allowed = model.toolApprovals.allows(sessionId: sessionId, tool: tool, command: event.toolCommand)
            if allowed { model.logEvent("hook", icon: "checkmark.shield", "allowed \(tool) from the phone's session rule") }
            return ControlReply(ok: true, result: .object(["decision": .string(allowed ? "allow" : "ask")]))

        case "event":
            guard let payload = r.secret, let event = HookEvent.parse(payload) else {
                throw Fail("event: a Claude Code hook payload (JSON with hook_event_name) is expected on stdin")
            }
            let pid = model.handleHookEvent(event)
            return ControlReply(ok: true, result: .object(["pid": pid.map { .number(Double($0)) } ?? .null]))

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
                throw Fail("the installed cswap has no autoswitch.preferred setting (claude-swap PR #312)")
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

        case "aws-login":
            guard let profile = r.args.first, !profile.isEmpty else { throw Fail("usage: aws-login <profile> [--pid n] [--local] [--remote] [--status]") }
            let pid = r.options["pid"].flatMap(Int.init)
            // --status: the phone's flag-less poll — report, start nothing.
            let reply = await model.startAwsLogin(profile: profile, pid: pid, local: r.options["local"] == "true",
                                                  remote: r.options["status"] == "true" ? nil : r.options["remote"] == "true")
            guard reply.ok, let state = reply.state else { throw Fail(reply.error ?? "could not start") }
            return ControlReply(ok: true, result: try .of(["state": state]))

        case "aws-login-callback":
            guard let profile = r.args.first, let url = r.secret, !url.isEmpty else {
                throw Fail("usage: aws-login-callback <profile>  (the intercepted http://127.0.0.1:<port>/oauth/callback?… URL on stdin)")
            }
            let reply = await model.awsLoginRunner.relay(profile: profile, url: url)
            guard reply.ok, let state = reply.state else { throw Fail(reply.error ?? "not accepted") }
            return ControlReply(ok: true, result: try .of(["state": state]))

        case "aws-login-code":
            guard let profile = r.args.first, let code = r.secret, !code.isEmpty else {
                throw Fail("usage: aws-login-code <profile>  (code on stdin)")
            }
            let reply = await model.submitAwsLoginCode(profile: profile, code: code)
            guard reply.ok, let state = reply.state else { throw Fail(reply.error ?? "not accepted") }
            return ControlReply(ok: true, result: try .of(["state": state]))

        case "ignite":
            let (fleet, n) = try target(r)
            guard fleet.capabilities.contains(.ignite) else { throw Fail("\(fleet.id) cannot ignite (no per-account request verb)") }
            guard fleet.accounts.contains(where: { $0.number == n }) else { throw Fail("no account #\(n) in \(fleet.id)") }
            try await fleet.engine.ignite(fleet: fleet.provider, number: n)
            await model.refreshSnapshot()
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
            } else if fleet.engineID == CswapEngine.engineID {
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
            let rows = model.eventLog.suffix(max(0, limit)).map { e in
                ["at": JSONValue.string(ISO8601DateFormatter().string(from: e.at)),
                 "icon": .string(e.icon), "text": .string(e.text)]
            }
            return ControlReply(ok: true, result: .array(rows.map(JSONValue.object)))

        case "stats":
            let period = Stats.Period(rawValue: r.options["period"] ?? "week") ?? .week
            model.statsModel.loadIfNeeded()
            let summary = model.statsModel.summaries[period]
                ?? Stats.fold(days: model.statsModel.days, period: period)
            // Compacted: `DayPoint.day` carries the 168-slot histogram
            // and the session set, which made `--period year` ~0.5 MB.
            return ControlReply(ok: true, result: try .of(summary.compacted()))

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
                "rssBytes": .number(rss),
                "heapBytes": .number(Double(stats.size_in_use)),
                "threads": .number(Double(threadCount)),
                "uptimeSeconds": .number(Date().timeIntervalSince(launchedAt)),
            ]))

        case "lock-status":
            let policy = model.lock.policy
            return ControlReply(ok: true, result: .object([
                "enabled": .bool(policy.enabled),
                "locked": .bool(policy.locked),
                "relock": .string(policy.relock.label),
            ]))

        case "team-status":
            return ControlReply(ok: true, result: try model.team.snapshot.map { try JSONValue.of($0) } ?? .null)

        case "team-create":
            // infinitusctl's arg parser treats `--remote` as a bare flag (it
            // has no way to know team-create wants a value), so the URL
            // lands as the second positional instead of options["remote"].
            // Fall back to that positional when the option came back as the
            // flag sentinel (review round 1, C1).
            let remote = r.options["remote"].flatMap { $0 == "true" ? nil : $0 } ?? r.args.dropFirst().first
            guard let name = r.args.first, !name.isEmpty, let remote, !remote.isEmpty else {
                throw Fail("usage: team-create <name> --remote <url> [--as <your name>]")
            }
            await model.team.create(name: name, remote: remote, token: nil, leaderName: r.options["as"] ?? "Leader")
            return try teamReply()

        case "team-code":
            let days = min(max(r.options["days"].flatMap(Int.init) ?? 7, 1), 3650)
            if r.options["invite"] != nil { await model.team.mintInvite(days: days) } else { await model.team.mintCode(days: days) }
            if let err = model.team.lastError { throw Fail(err) }
            guard let code = model.team.code else { throw Fail("no code") }
            return ControlReply(ok: true, result: .object(["code": .string(code)]))

        case "team-fetch":
            await model.team.fetchNow()
            return try teamReply()

        case "team-publish":
            await model.team.publishNow()
            if let err = model.team.lastError { throw Fail(err) }
            return ControlReply(ok: true, result: try JSONValue.of(model.team.lastReport ?? TeamPublisher.Report()))

        case "team-approve", "team-decline":
            guard let kid = r.args.first, !kid.isEmpty else { throw Fail("usage: \(r.command) <kid>") }
            if r.command == "team-approve" { await model.team.approve(kid: kid) } else { await model.team.decline(kid: kid) }
            return try teamReply()

        case "show":
            guard let controller = AppDelegate.shared?.statusHolder?.controller else {
                throw Fail("no status item yet")
            }
            switch r.args.first {
            case "popout": controller.showPinnedWindow()
            case "settings": controller.showSettingsWindow()
            case "wall": controller.toggleWall()
            default: throw Fail("usage: show popout|settings|wall")
            }
            return ControlReply(ok: true, result: .object(["shown": .string(r.args[0])]))

        case "engine":
            guard r.args.count == 2, ["on", "off"].contains(r.args[1]) else {
                throw Fail("usage: engine cswap|cliproxy|9router on|off")
            }
            let on = r.args[1] == "on"
            switch r.args[0] {
            case "cswap":
                guard model.cswap != nil || !on else { throw Fail("cswap is not installed") }
                guard model.cswapEnabled != on else { return ControlReply(ok: true, result: .object(["unchanged": .bool(true)])) }
                model.cswapEnabled = on
            case "cliproxy":
                guard model.cliproxyKeyPresent || !on else { throw Fail("store a management key first (proxy-key)") }
                guard model.cliproxyEnabled != on else { return ControlReply(ok: true, result: .object(["unchanged": .bool(true)])) }
                model.cliproxyEnabled = on
            case "9router":
                guard model.nineRouterEnabled != on else { return ControlReply(ok: true, result: .object(["unchanged": .bool(true)])) }
                model.nineRouterEnabled = on
            default: throw Fail("unknown engine \(r.args[0])")
            }
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

        case "team-discoverable":
            guard let arg = r.args.first, ["on", "off"].contains(arg) else { throw Fail("usage: team-discoverable on|off") }
            // MirrorServer watches this default and re-advertises (Nearby, spec §6.4).
            UserDefaults.standard.set(arg == "on", forKey: TeamNearby.discoverableDefaultsKey)
            return ControlReply(ok: true, result: .object(["discoverable": .bool(arg == "on")]))

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
        let nextRecovery: NextRecovery?
        let accounts: [Account]
    }

    private func fleetPayload(_ f: FleetState) -> FleetPayload {
        FleetPayload(key: f.id, engineID: f.engineID, provider: f.provider.rawValue,
                     capabilities: Self.names(f.capabilities),
                     caveat: model.fleetCaveats[f.engineID],
                     activeNumber: f.activeNumber, nextCandidate: f.nextCandidate,
                     nextRecovery: f.nextRecovery, accounts: f.accounts)
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
    }

    private func status() -> Status {
        let info = Bundle.main.infoDictionary ?? [:]
        return Status(
            version: info["CFBundleShortVersionString"] as? String ?? "dev",
            sha: info["InfinitusGitSHA"] as? String ?? info["CFBundleVersion"] as? String ?? "dev",
            engines: [
                "cswap": EngineStatus(enabled: model.cswapEnabled, registered: model.cswapRegistered,
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
            socket: ControlProtocol.socketURL().path)
    }

    static func names(_ caps: EngineCapabilities) -> [String] {
        let table: [(EngineCapabilities, String)] = [
            (.switch, "switch"), (.rotate, "rotate"), (.reorder, "reorder"), (.hold, "hold"),
            (.rename, "rename"), (.remove, "remove"), (.addCurrent, "addCurrent"),
            (.addToken, "addToken"), (.addOAuth, "addOAuth"), (.autoSwitch, "autoSwitch"),
            (.costReport, "costReport"), (.history, "history"), (.settings, "settings"),
            (.prefer, "prefer"), (.ignite, "ignite"),
        ]
        return table.filter { caps.contains($0.0) }.map(\.1)
    }
}

/// `crashes`: the reports without their raw diagnostic.
private struct CrashListing: Encodable {
    let id: String, platform: String, device: String, at: Date, kind: String, reason: String, frames: [String]
}
