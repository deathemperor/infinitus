import Foundation

#if !os(iOS)
/// A terminal surface hosting a shell — one cmux surface, tmux pane or
/// herdr pane. `tty` is the pty it fronts when the host exposes it;
/// `pids` the foreground processes when it exposes those instead.
public struct PtySurface: Sendable, Equatable {
    public let ref: String
    public let tty: String?
    public let title: String
    public let pids: [Int32]

    public init(ref: String, tty: String? = nil, title: String = "", pids: [Int32] = []) {
        self.ref = ref
        self.tty = tty
        self.title = title
        self.pids = pids
    }
}

/// Runs a binary with arguments and returns stdout. Injectable so the host
/// adapters test against canned output.
public typealias CommandRunner = @Sendable (_ binary: String, _ args: [String]) throws -> String

/// A terminal multiplexer that can list its surfaces, type into one and
/// read its screen. Every method is blocking — run off the main thread.
public protocol PtyHost: Sendable {
    var name: String { get }
    func surfaces() throws -> [PtySurface]
    /// Type `text` and press Enter.
    func sendLine(_ ref: String, _ text: String) throws
    func sendEsc(_ ref: String) throws
    func readScreen(_ ref: String, lines: Int) throws -> String
}

public struct PtyHostError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Subprocess {
    /// Blocking run; stdout on success, error on a non-zero exit or timeout.
    public static func run(_ binary: String, _ args: [String], timeout: TimeInterval = 15) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PtyHostError("\(URL(fileURLWithPath: binary).lastPathComponent) exited \(process.terminationStatus): \(msg)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// First existing executable among absolute candidates. A Finder- or
    /// login-item-launched app has no user PATH, so never search it.
    public static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Process facts from `ps` — no host exposes everything we match on.
public enum ProcessFacts {
    public static func run(_ args: [String]) -> String {
        (try? Subprocess.run("/bin/ps", args)) ?? ""
    }

    /// Controlling tty basename of `pid` (`ttys009`), nil when detached.
    public static func tty(of pid: Int32) -> String? {
        let tty = run(["-o", "tty=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty || tty == "??" || tty == "-" ? nil : tty
    }

    /// The session's permission-mode class from how it was launched —
    /// the fallback when its transcript tail carries no mode
    /// (`Transcript.peerModeClass`): `"bypass"` for
    /// `--dangerously-skip-permissions` or `--permission-mode
    /// bypassPermissions`, `"prompting"` for any other launch, nil when
    /// `ps` shows nothing. A mode switched at the keyboard after launch
    /// is missed, which only re-creates today's hold; a missing class
    /// is held by every bypass receiver (2.1.263+).
    public static func peerModeClass(pid: Int32) -> String? {
        peerModeClass(command: run(["-o", "command=", "-p", String(pid)]))
    }

    static func peerModeClass(command: String) -> String? {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !words.isEmpty else { return nil }
        if words.contains("--dangerously-skip-permissions") { return "bypass" }
        for (i, word) in words.enumerated() {
            if word == "--permission-mode", i + 1 < words.count, words[i + 1] == "bypassPermissions" { return "bypass" }
            if word == "--permission-mode=bypassPermissions" { return "bypass" }
        }
        return "prompting"
    }

    /// Parent chain of `pid`, nearest first, stopping before launchd.
    public static func ancestors(of pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var current = pid
        while out.count < 32 {
            let text = run(["-o", "ppid=", "-p", String(current)]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parent = Int32(text), parent > 1 else { break }
            out.append(parent)
            current = parent
        }
        return out
    }

    /// Seconds since the tty last saw input or output.
    public static func idleSeconds(tty: String, now: Date = Date()) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: "/dev/\(tty)") else { return nil }
        let mod = attrs[.modificationDate] as? Date ?? .distantPast
        return now.timeIntervalSince(mod)
    }
}

extension Array where Element == PtySurface {
    /// The surface hosting `pid`: by tty when the host exposes ttys (a
    /// Claude inside tmux sits on a NESTED pty, so the pane's own tty never
    /// matches — the pid ancestry does), else by the pid or any ancestor
    /// appearing among the surface's foreground processes, else — for a
    /// host that exposes no pids at all (cmux) — by title: Claude Code
    /// titles its terminal with the session's name behind a status glyph
    /// ("◑ Infinitus2"), exact match after the glyph (2026-09-04).
    public func surface(for pid: Int32, tty: String?, ancestors: [Int32],
                        name: String? = nil) -> PtySurface? {
        if let tty, let hit = first(where: { $0.tty == tty }) { return hit }
        let lineage = Set([pid] + ancestors)
        if let hit = first(where: { !$0.pids.isEmpty && !lineage.isDisjoint(with: $0.pids) }) { return hit }
        guard let name, !name.isEmpty else { return nil }
        return first { $0.pids.isEmpty && Self.titleName($0.title) == name }
    }

    static func titleName(_ title: String) -> String {
        String(title.drop(while: { !$0.isLetter && !$0.isNumber }))
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - cmux

public struct CmuxHost: PtyHost {
    public static let candidates = ["/Applications/cmux.app/Contents/Resources/bin/cmux"]
    public let name = "cmux"
    let binary: String
    let runner: CommandRunner

    public init(binary: String, runner: @escaping CommandRunner = { try Subprocess.run($0, $1) }) {
        self.binary = binary
        self.runner = runner
    }

    public static func find() -> CmuxHost? {
        Subprocess.find(candidates).map { CmuxHost(binary: $0) }
    }

    public func surfaces() throws -> [PtySurface] {
        let text = try runner(binary, ["tree", "--all", "--json"])
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return [] }
        var out: [PtySurface] = []
        Self.walk(root, into: &out)
        return out
    }

    /// Terminal surfaces live at the leaves of window → workspace → pane;
    /// walk generically so a layout change above the leaf keeps working.
    static func walk(_ node: Any, into out: inout [PtySurface]) {
        if let dict = node as? [String: Any] {
            if (dict["type"] as? String) == "terminal", let ref = dict["ref"] as? String {
                let tty = (dict["tty"] as? String).map { ($0 as NSString).lastPathComponent }
                out.append(PtySurface(ref: ref, tty: tty, title: dict["title"] as? String ?? ""))
                return
            }
            for value in dict.values { walk(value, into: &out) }
        } else if let list = node as? [Any] {
            for value in list { walk(value, into: &out) }
        }
    }

    /// Text and Enter as two calls, like the tmux/herdr hosts: a CR
    /// inside `send` text reaches the app as pasted input, and Claude
    /// Code runs with bracketed paste on, so the CR lands as a newline in
    /// the prompt instead of submitting it (#5: nudge typed, never sent).
    /// `send-key enter` is a key event, delivered outside the paste.
    public func sendLine(_ ref: String, _ text: String) throws {
        _ = try runner(binary, ["send", "--surface", ref, "--", text])
        _ = try runner(binary, ["send-key", "--surface", ref, "enter"])
    }

    public func sendEsc(_ ref: String) throws {
        _ = try runner(binary, ["send", "--surface", ref, "--", "\u{1b}"])
    }

    public func readScreen(_ ref: String, lines: Int) throws -> String {
        try runner(binary, ["read-screen", "--surface", ref, "--lines", String(lines)])
    }
}

// MARK: - tmux

public struct TmuxHost: PtyHost {
    public static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    public let name = "tmux"
    let binary: String
    let runner: CommandRunner

    public init(binary: String, runner: @escaping CommandRunner = { try Subprocess.run($0, $1) }) {
        self.binary = binary
        self.runner = runner
    }

    public static func find() -> TmuxHost? {
        Subprocess.find(candidates).map { TmuxHost(binary: $0) }
    }

    public func surfaces() throws -> [PtySurface] {
        // No server running exits non-zero; that's "no panes", not an error.
        guard let text = try? runner(binary, ["list-panes", "-a", "-F",
                                              "#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{pane_title}"])
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[1]) else { return nil }
            return PtySurface(ref: parts[0], tty: (parts[2] as NSString).lastPathComponent,
                              title: parts.count > 3 ? parts[3] : "", pids: [pid])
        }
    }

    public func sendLine(_ ref: String, _ text: String) throws {
        _ = try runner(binary, ["send-keys", "-t", ref, "-l", "--", text])
        _ = try runner(binary, ["send-keys", "-t", ref, "Enter"])
    }

    public func sendEsc(_ ref: String) throws {
        _ = try runner(binary, ["send-keys", "-t", ref, "Escape"])
    }

    public func readScreen(_ ref: String, lines: Int) throws -> String {
        try runner(binary, ["capture-pane", "-p", "-t", ref, "-S", String(-lines)])
    }
}

// MARK: - herdr

public struct HerdrHost: PtyHost {
    public static func candidates(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
    }
    public let name = "herdr"
    let binary: String
    let runner: CommandRunner

    public init(binary: String, runner: @escaping CommandRunner = { try Subprocess.run($0, $1) }) {
        self.binary = binary
        self.runner = runner
    }

    public static func find(home: String = NSHomeDirectory()) -> HerdrHost? {
        Subprocess.find(candidates(home: home)).map { HerdrHost(binary: $0) }
    }

    static func result(_ text: String) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return root["result"] as? [String: Any]
    }

    /// herdr exposes no tty; each pane's foreground process group and
    /// processes are matched against the session's pid ancestry instead.
    public func surfaces() throws -> [PtySurface] {
        guard let result = Self.result(try runner(binary, ["pane", "list"])),
              let panes = result["panes"] as? [[String: Any]] else { return [] }
        return panes.compactMap { pane in
            guard let id = pane["pane_id"] as? String else { return nil }
            var pids: [Int32] = []
            if let info = Self.result((try? runner(binary, ["pane", "process-info", "--pane", id])) ?? "")?["process_info"] as? [String: Any] {
                if let leader = info["foreground_process_group_id"] as? NSNumber { pids.append(leader.int32Value) }
                for proc in info["foreground_processes"] as? [[String: Any]] ?? [] {
                    if let pid = proc["pid"] as? NSNumber { pids.append(pid.int32Value) }
                }
            }
            return PtySurface(ref: id, title: pane["terminal_title"] as? String ?? "", pids: pids)
        }
    }

    public func sendLine(_ ref: String, _ text: String) throws {
        _ = try runner(binary, ["pane", "send-text", ref, text])
        _ = try runner(binary, ["pane", "send-keys", ref, "enter"])
    }

    public func sendEsc(_ ref: String) throws {
        _ = try runner(binary, ["pane", "send-keys", ref, "esc"])
    }

    public func readScreen(_ ref: String, lines: Int) throws -> String {
        try runner(binary, ["pane", "read", ref, "--lines", String(lines), "--source", "visible"])
    }
}

public enum PtyHosts {
    /// Every multiplexer installed on this machine.
    public static func available(home: String = NSHomeDirectory()) -> [any PtyHost] {
        var out: [any PtyHost] = []
        if let cmux = CmuxHost.find() { out.append(cmux) }
        if let tmux = TmuxHost.find() { out.append(tmux) }
        if let herdr = HerdrHost.find(home: home) { out.append(herdr) }
        return out
    }
}
#endif
