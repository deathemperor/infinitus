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
        public init(cwd: String, engine: String? = nil, prompt: String? = nil, resume: String? = nil) {
            self.cwd = cwd
            self.engine = engine
            self.prompt = prompt
            self.resume = resume
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
                                    resume: String? = nil) -> String {
        let bin = engine == "codex" ? "codex" : "claude"
        var line = "cd \(shellQuoted(cwd)) && exec \(bin)"
        if bin == "claude", let resume, !resume.isEmpty {
            line += " --resume " + shellQuoted(resume)
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
