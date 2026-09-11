import Foundation

#if !os(iOS)
// MARK: - Installing the engine from the app (#871)
//
// A fresh Mac has Infinitus and no engine, and the documented way in is
// two commands in a terminal — which is where onboarding stopped. This is
// the same two commands, planned here and run by the app, so the first-run
// card can do it for the user. Pure: `swift test` covers every branch, the
// app layer only spawns what `command(...)` names.
//
// No release archive or formula exists for swapd yet, so building from
// source is the one way in (see `OnboardingBrief.swapdInstallCommand`).
// When one ships, this whole flow is replaced by a download.

/// One command the app runs on the user's behalf, in order.
public enum EngineInstallStep: String, Sendable, Equatable, CaseIterable {
    /// Rust, because the engine is built from source.
    case installRust
    /// The engine itself.
    case installEngine

    /// What the card says while this step runs.
    public var title: String {
        switch self {
        case .installRust: return "Installing Rust (the engine is built from source)"
        case .installEngine: return "Building and installing swapd"
        }
    }

    /// Roughly how long to warn about, since both steps are minutes long
    /// and a silent window reads as a hang.
    public var estimate: String {
        switch self {
        case .installRust: return "a few minutes"
        case .installEngine: return "5–10 minutes"
        }
    }
}

/// Why the app cannot run the install itself.
public enum EngineInstallBlocker: Sendable, Equatable {
    /// Nothing to do — the engine is already on this Mac.
    case alreadyInstalled
    /// No Rust and no Homebrew to install it with; the user has to bring
    /// one of them. Never install Homebrew for them: it is a system-wide
    /// change with its own prompts.
    case needsHomebrew

    public var message: String {
        switch self {
        case .alreadyInstalled:
            return "The engine is already installed."
        case .needsHomebrew:
            return "This Mac has neither Rust nor Homebrew. Install Homebrew "
                + "(brew.sh) or Rust (rustup.rs) yourself, then try again."
        }
    }
}

/// An executable and its arguments — never a shell string, so nothing this
/// builds can be word-split or expanded.
public struct EngineInstallCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// What this Mac needs, in order, for the engine to exist.
public struct EngineInstallPlan: Sendable, Equatable {
    public let steps: [EngineInstallStep]
    public let blocker: EngineInstallBlocker?

    public var isRunnable: Bool { blocker == nil && !steps.isEmpty }

    /// `engine`, `cargo` and `brew` are resolved paths, or nil where the
    /// tool is missing. Rust is only installed when it is actually absent,
    /// so a machine that already builds Rust keeps its own toolchain.
    public static func make(engine: String?, cargo: String?, brew: String?) -> EngineInstallPlan {
        if engine != nil { return EngineInstallPlan(steps: [], blocker: .alreadyInstalled) }
        if cargo != nil { return EngineInstallPlan(steps: [.installEngine], blocker: nil) }
        if brew != nil { return EngineInstallPlan(steps: [.installRust, .installEngine], blocker: nil) }
        return EngineInstallPlan(steps: [], blocker: .needsHomebrew)
    }

    /// The engine's source, quoted by `OnboardingBrief.swapdInstallCommand`
    /// as well; the test pins the two to each other.
    public static let engineRepository = "https://github.com/deathemperor/swapd"

    /// What a step actually runs. Nil when the tool it needs is not there —
    /// `installRust` is only reachable with a brew, and `installEngine`
    /// after it has to re-resolve cargo, which brew has just put on disk.
    public static func command(_ step: EngineInstallStep,
                               cargo: String?, brew: String?) -> EngineInstallCommand? {
        switch step {
        case .installRust:
            guard let brew else { return nil }
            return EngineInstallCommand(executable: brew, arguments: ["install", "rust"])
        case .installEngine:
            guard let cargo else { return nil }
            return EngineInstallCommand(
                executable: cargo,
                arguments: ["install", "--git", engineRepository, "swapd"])
        }
    }
}

/// Where the tools the install needs live. Same shape as `SwapdLocator`:
/// checked in order, first hit wins, `exists` injected so tests never touch
/// the real filesystem.
public enum EngineToolLocator {
    public static func cargoCandidates(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.cargo/bin/cargo", "/opt/homebrew/bin/cargo", "/usr/local/bin/cargo"]
    }

    public static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func locate(
        _ candidates: [String],
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: exists)
    }
}

/// The one line of the build's output worth showing. cargo is chatty and a
/// raw tail scrolls too fast to read; these are the lines that say progress
/// is being made, plus anything that called itself an error.
public enum EngineInstallProgress {
    public static func label(for line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("error") || lowered.hasPrefix("warning: build failed") { return text }
        for verb in ["Compiling", "Downloading", "Downloaded", "Installing", "Installed",
                     "Updating", "Building", "Finished", "Fetching"] where text.hasPrefix(verb) {
            return text
        }
        return nil
    }

    /// What the user is told when a step exits non-zero: the last thing the
    /// tool said, never a bare exit code.
    public static func failure(step: EngineInstallStep, output: [String], status: Int32) -> String {
        let said = output.reversed().first { label(for: $0)?.lowercased().hasPrefix("error") == true }
            ?? output.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let said, !said.isEmpty else {
            return "\(step.title) failed (exited \(status))."
        }
        return said.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
