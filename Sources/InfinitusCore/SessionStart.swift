import Foundation

/// Start a session from the phone (#91, user 2026-09-05: "Ability to
/// start new sessions from mobile"): `POST /sessions/start` opens a new
/// terminal on the Mac — a cmux workspace when cmux is installed, else
/// Terminal.app — running the engine in the repository, first prompt
/// included, and answers with the session's pid once it registers.
public enum SessionStart {
    public static let path = "/sessions/start"

    public struct Request: Codable, Sendable, Equatable {
        public let cwd: String
        /// "claude" (default) or "codex".
        public let engine: String?
        public let prompt: String?
        /// A past session's id to pick up where it left off (#164):
        /// `claude --resume <id>`, from the folder it ran in. Optional
        /// so phones from before it still start sessions.
        public let resume: String?
        /// Claude Code's `--permission-mode` for the new session (#163):
        /// one of `permissionModes`; nil or unknown = the default
        /// (supervised — every tool asks). Optional so older phones
        /// still start sessions.
        public let permissionMode: String?
        /// `claude --model` / `--append-system-prompt` (#165 profiles);
        /// `profile` names the profile the session was born from, for
        /// the log. All optional and absent-tolerant.
        public let model: String?
        public let systemPrompt: String?
        public let profile: String?
        public init(cwd: String, engine: String? = nil, prompt: String? = nil, resume: String? = nil,
                    permissionMode: String? = nil, model: String? = nil, systemPrompt: String? = nil,
                    profile: String? = nil) {
            self.cwd = cwd
            self.engine = engine
            self.prompt = prompt
            self.resume = resume
            self.permissionMode = permissionMode
            self.model = model
            self.systemPrompt = systemPrompt
            self.profile = profile
        }
    }

    /// The modes a session can start in, as Claude Code spells them,
    /// with the label the pickers show. The default (ask for every
    /// tool) is "no flag", so it is not in this list.
    public static let permissionModes: [(mode: String, label: String)] = [
        ("acceptEdits", "Auto-accept edits"),
        ("auto", "Auto"),
        ("bypassPermissions", "Full access"),
    ]
    /// The modes a running session can be moved to (#163 phase 2) through
    /// the plugin's PreToolUse hook: `supervised` clears the hook mode.
    /// `auto` is Claude Code's own classifier and has no hook equivalent.
    public static let hookModes: [(mode: String, label: String)] = [
        ("supervised", "Supervised"),
        ("acceptEdits", "Auto-accept edits"),
        ("bypassPermissions", "Full access"),
    ]
    /// How much a mode lets through, for "a start mode is a floor": the
    /// hook can only widen what Claude Code would otherwise ask about.
    public static func modeRank(_ mode: String?) -> Int {
        switch mode {
        case "bypassPermissions": return 2
        case "acceptEdits", "auto": return 1
        default: return 0
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        /// "started" | "badCwd" | "noHost" | "failed"
        public let outcome: String
        public let detail: String?
        /// "cmux" | "Terminal" when started.
        public let host: String?
        /// The new session's pid once the roster shows it (Claude only —
        /// Codex sessions have no roster entry).
        public let pid: Int?
        public init(outcome: String, detail: String? = nil, host: String? = nil, pid: Int? = nil) {
            self.outcome = outcome
            self.detail = detail
            self.host = host
            self.pid = pid
        }
    }

    /// The one shell line the new terminal runs: into the folder, then
    /// the engine replaces the shell, the prompt as its argument; a
    /// resumed Claude session names its id first (Codex has no resume here).
    public static func shellCommand(cwd: String, engine: String?, prompt: String?,
                                    resume: String? = nil, permissionMode: String? = nil,
                                    model: String? = nil, systemPrompt: String? = nil) -> String {
        let bin = engine == "codex" ? "codex" : "claude"
        var line = "cd \(shellQuoted(cwd)) && exec \(bin)"
        if bin == "claude", let resume, !resume.isEmpty {
            line += " --resume " + shellQuoted(resume)
        }
        // Only a known mode reaches the command line; anything else is
        // the default, never an arbitrary flag value.
        if bin == "claude", let permissionMode, permissionModes.contains(where: { $0.mode == permissionMode }) {
            line += " --permission-mode " + permissionMode
        }
        if bin == "claude", let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            line += " --model " + shellQuoted(model)
        }
        if bin == "claude", let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            line += " --append-system-prompt " + shellQuoted(systemPrompt)
        }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            line += " " + shellQuoted(prompt)
        }
        return line
    }

    /// Single-quoted for sh: the only special character inside single
    /// quotes is the quote itself.
    public static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
