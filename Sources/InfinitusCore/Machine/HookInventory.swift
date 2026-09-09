import Foundation

/// Every Claude Code hook registration on the machine, attributed to
/// the tool that owns it (#115): installers write into
/// `~/.claude/settings.json` silently, and an unaudited hook on a
/// per-tool-call event is a spawn storm waiting for ten sessions.
public struct HookRegistration: Equatable, Sendable, Codable, Identifiable {
    public enum Source: Equatable, Sendable, Codable {
        case user
        case project(String)
        case plugin(String)
        public var label: String {
            switch self {
            case .user: return "user settings"
            case .project(let path): return "project " + (path as NSString).lastPathComponent
            case .plugin(let name): return "plugin " + name
            }
        }
    }
    public enum OwnerKind: String, Sendable, Codable { case brew, vendored, handInstalled, plugin, unknown }

    public let event: String
    public let matcher: String?
    public let command: String
    public let timeout: Int?
    public let source: Source
    public let ownerKind: OwnerKind
    /// The tool's name as a person would say it: "peon-ping", "cst", a plugin's name.
    public let owner: String

    public var id: String { "\(source.label)|\(event)|\(command)" }

    public init(event: String, matcher: String?, command: String, timeout: Int?, source: Source) {
        self.event = event; self.matcher = matcher; self.command = command; self.timeout = timeout; self.source = source
        let owned = HookInventory.owner(of: command, source: source)
        ownerKind = owned.kind; owner = owned.name
    }

    /// Interpreter start-ups, AppleScript into System Events, the
    /// network: the commands that hurt at PostToolUse rates.
    public var heavy: Bool { HookInventory.isHeavy(command) }

    /// The path the running instances carry in their command line.
    public var scriptPath: String? { HookInventory.scriptPath(in: command) }
}

public enum HookInventory {
    /// Spawns per session-hour, by event, at a typical ~30 turns/hour.
    public static let spawnsPerSessionHour: [String: Double] = [
        "PreToolUse": 450, "PostToolUse": 450, "PostToolUseFailure": 20,
        "UserPromptSubmit": 30, "Stop": 30, "Notification": 30, "PermissionRequest": 15,
        "SubagentStart": 60, "SubagentStop": 60, "PreCompact": 2,
        "SessionStart": 1, "SessionEnd": 1,
    ]

    public static func spawnsPerHour(event: String, liveSessions: Int) -> Double {
        (spawnsPerSessionHour[event] ?? 10) * Double(max(1, liveSessions))
    }

    /// Parse one settings file's `hooks` object.
    public static func parse(settings: [String: Any], source: HookRegistration.Source) -> [HookRegistration] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var out: [HookRegistration] = []
        for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let matcher = group["matcher"] as? String
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    guard let command = hook["command"] as? String else { continue }
                    out.append(HookRegistration(event: event, matcher: matcher, command: command,
                                                timeout: hook["timeout"] as? Int, source: source))
                }
            }
        }
        return out
    }

    public static func parse(json data: Data, source: HookRegistration.Source) -> [HookRegistration] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return parse(settings: object, source: source)
    }

    static let heavyMarkers = ["python3", "python ", "node ", "node\"", "bun ", "bunx ", "osascript", "curl ", "ruby ", "deno ", "npx ", "System Events"]
    public static func isHeavy(_ command: String) -> Bool {
        heavyMarkers.contains { command.contains($0) }
    }

    public static func owner(of command: String, source: HookRegistration.Source) -> (kind: HookRegistration.OwnerKind, name: String) {
        if case .plugin(let name) = source { return (.plugin, name) }
        if command.contains("${CLAUDE_PLUGIN_ROOT}") || command.contains("/.claude/plugins/cache/") {
            return (.plugin, pathComponent(after: "/plugins/cache/", in: command, index: 1) ?? "plugin")
        }
        if command.contains("/opt/homebrew/") || command.contains("/usr/local/Cellar/") {
            return (.brew, pathComponent(after: "/Cellar/", in: command, index: 0)
                        ?? pathComponent(after: "/opt/homebrew/opt/", in: command, index: 0)
                        ?? binaryName(command))
        }
        if command.contains("/.claude/vendor/") {
            return (.vendored, pathComponent(after: "/.claude/vendor/", in: command, index: 0) ?? "vendored")
        }
        if command.contains("/.claude/hooks/") {
            if let dir = pathComponent(after: "/.claude/hooks/", in: command, index: 0) {
                // `hooks/peon-ping/peon.sh` → peon-ping; `hooks/cst_x.py` → cst.
                if dir.contains(".") {
                    let stem = dir.split(separator: ".").first.map(String.init) ?? dir
                    return (.handInstalled, stem.split(separator: "_").first.map(String.init) ?? stem)
                }
                return (.handInstalled, dir)
            }
        }
        // `[ -f ~/.claude/hooks/x.sh ] && bash ~/.claude/hooks/x.sh`: the
        // first token is a shell conditional, the script names the owner.
        let name = binaryName(command)
        if ["[", "test", "if"].contains(name) || interpreters.contains(name),
           let script = scriptPath(in: command) {
            let stem = (script as NSString).lastPathComponent.split(separator: ".").first.map(String.init)
            return (.unknown, stem ?? name)
        }
        return (.unknown, name)
    }

    static func pathComponent(after marker: String, in command: String, index: Int) -> String? {
        guard let range = command.range(of: marker) else { return nil }
        let tail = command[range.upperBound...]
        let end = tail.firstIndex(where: { $0 == " " || $0 == "\"" || $0 == "'" }) ?? tail.endIndex
        let parts = tail[..<end].split(separator: "/").map(String.init)
        return parts.count > index ? parts[index] : nil
    }

    static func binaryName(_ command: String) -> String {
        let first = command.split(separator: " ").first.map(String.init) ?? command
        return (first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).lastPathComponent
    }

    static let interpreters: Set<String> = ["sh", "bash", "zsh", "python", "python3", "node", "bun", "ruby", "deno", "env"]

    /// The first path-like token that is not an interpreter: what `ps`
    /// shows for a running instance (`/bin/bash x.sh` would otherwise
    /// count every bash on the Mac). A leading `~` is expanded the way
    /// the shell does before the command reaches `ps`.
    public static func scriptPath(in command: String, home: String = NSHomeDirectory()) -> String? {
        for token in command.split(separator: " ") {
            var clean = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if clean.hasPrefix("~/") { clean = home + clean.dropFirst() }
            guard clean.hasPrefix("/") else { continue }
            if interpreters.contains((clean as NSString).lastPathComponent) { continue }
            return clean
        }
        return nil
    }

    /// Live instances of a registration among the process rows: the
    /// rows whose command carries its script path, plus their
    /// descendants (a shell hook's python helpers), the oldest, and how
    /// many sit in uninterruptible wait.
    public struct Live: Equatable, Sendable, Codable {
        public var instances = 0
        public var helpers = 0
        public var oldestSeconds = 0
        public var uninterruptible = 0
        public init() {}
    }

    /// The owner of the hook whose instance tree holds a process whose
    /// command contains `needle` (e.g. "pip install"), if any.
    public static func spawner(of needle: String, rows: [ProcessRow], registrations: [HookRegistration]) -> String? {
        let hits = Set(rows.filter { $0.command.contains(needle) }.map(\.pid))
        guard !hits.isEmpty else { return nil }
        for reg in registrations {
            let (instances, helpers) = instanceRows(of: reg, rows: rows)
            if (instances + helpers).contains(where: { hits.contains($0.pid) }) { return reg.owner }
        }
        return nil
    }

    public static func live(of registration: HookRegistration, rows: [ProcessRow],
                            index: ProcessIndex? = nil) -> Live {
        var live = Live()
        let (instances, helpers) = instanceRows(of: registration, rows: rows, index: index)
        live.instances = instances.count
        live.helpers = helpers.count
        for row in instances + helpers {
            live.oldestSeconds = max(live.oldestSeconds, row.elapsedSeconds)
            if row.state == "U" { live.uninterruptible += 1 }
        }
        return live
    }

    /// The rows whose command carries the registration's script path,
    /// and their descendants (a shell hook's python helpers). `index` is
    /// `ProcessIndex(rows)`, built once by a caller that asks for every
    /// registration — 70 registrations regrouping 1,100 rows each was
    /// most of the machine sample's CPU (#346), and Foundation's
    /// `String.contains` over the same 80k pairs cost a second per
    /// sample; the byte search is 25× cheaper.
    public static func instanceRows(of registration: HookRegistration, rows: [ProcessRow],
                                    index: ProcessIndex? = nil) -> (instances: [ProcessRow], helpers: [ProcessRow]) {
        guard let path = registration.scriptPath else { return ([], []) }
        let index = index ?? ProcessIndex(rows)
        let byParent = index.children
        let needle = Array(path.utf8)
        var instances: [ProcessRow] = []
        for (i, bytes) in index.commands.enumerated() where bytesContain(bytes, needle) { instances.append(rows[i]) }
        var seen = Set(instances.map(\.pid))
        var helpers: [ProcessRow] = []
        var queue = instances
        while let row = queue.popLast() {
            for child in byParent[row.pid] ?? [] where seen.insert(child.pid).inserted {
                helpers.append(child)
                queue.append(child)
            }
        }
        return (instances, helpers)
    }

    /// One sample's rows, grouped by parent and with each command as
    /// bytes, shared by every registration's `instanceRows`.
    public struct ProcessIndex {
        public let children: [Int: [ProcessRow]]
        let commands: [[UInt8]]
        public init(_ rows: [ProcessRow]) {
            children = Dictionary(grouping: rows, by: \.ppid)
            commands = rows.map { Array($0.command.utf8) }
        }
    }

    static func bytesContain(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = needle.count, h = hay.count
        guard n > 0, h >= n else { return n == 0 }
        let first = needle[0]
        var i = 0
        while i <= h - n {
            if hay[i] == first {
                var j = 1
                while j < n, hay[i + j] == needle[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }

    /// A stable fingerprint of the registrations: a change means an
    /// installer wrote into settings.json (#115 item 5).
    public static func fingerprint(_ registrations: [HookRegistration]) -> String {
        registrations.map(\.id).sorted().joined(separator: "\n")
    }

    /// The tools that appeared since `previous` (by owner + event).
    public static func newcomers(_ current: [HookRegistration], since previous: Set<String>) -> [HookRegistration] {
        current.filter { !previous.contains($0.id) }
    }

    // MARK: files

    /// Reads the user file, each project's two files, and installed
    /// plugins' hooks.json (`~/.claude/plugins/installed_plugins.json`).
    public static func scan(home: String = NSHomeDirectory(), projectDirs: [String]) -> [HookRegistration] {
        let fm = FileManager.default
        var out: [HookRegistration] = []
        func read(_ path: String, _ source: HookRegistration.Source) {
            guard let data = fm.contents(atPath: path) else { return }
            out += parse(json: data, source: source)
        }
        read("\(home)/.claude/settings.json", .user)
        for dir in Set(projectDirs).sorted() {
            read("\(dir)/.claude/settings.json", .project(dir))
            read("\(dir)/.claude/settings.local.json", .project(dir))
        }
        if let data = fm.contents(atPath: "\(home)/.claude/plugins/installed_plugins.json"),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let plugins = object["plugins"] as? [String: Any] {
            for (name, value) in plugins.sorted(by: { $0.key < $1.key }) {
                let installs = (value as? [[String: Any]]) ?? []
                var seen = Set<String>()
                for install in installs {
                    guard let path = install["installPath"] as? String, seen.insert(path).inserted else { continue }
                    let short = name.split(separator: "@").first.map(String.init) ?? name
                    read("\(path)/hooks/hooks.json", .plugin(short))
                }
            }
        }
        return out
    }
}
