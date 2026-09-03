import Foundation

// MARK: - Onboarding detection (todo 2026-09-01)
//
// What this machine already has, read the allowed way: Claude Code's own
// files (~/.claude.json) and presence-only facts about other tools —
// never another engine's internals. CLIProxy credential FILES are
// counted by name, their contents (tokens) are never opened.

/// A Claude Code CLI install and whoever it's signed in as.
public struct ClaudeCLIInfo: Sendable, Equatable {
    public let binaryPath: String?
    public let email: String?
    public let organization: String?
    /// Something worth onboarding from: a binary or a signed-in account.
    public var isPresent: Bool { binaryPath != nil || email != nil }
}

public enum ClaudeCLIDetect {
    public static func info(home: String = NSHomeDirectory()) -> ClaudeCLIInfo {
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        let bin = candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        let account = accountInfo(
            data: try? Data(contentsOf:
                URL(fileURLWithPath: "\(home)/.claude.json")))
        return ClaudeCLIInfo(binaryPath: bin,
                             email: account?.0, organization: account?.1)
    }

    /// (email, organization) from a ~/.claude.json blob. Tolerant: the
    /// file is Claude Code's kitchen sink; only `oauthAccount` matters.
    public static func accountInfo(data: Data?) -> (String, String?)? {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any],
              let email = oauth["emailAddress"] as? String, !email.isEmpty
        else { return nil }
        return (email, oauth["organizationName"] as? String)
    }
}

/// A CLIProxyAPI install: its auth dir and how many credential files sit
/// in it. Presence-only — file names, never contents.
public struct CLIProxyInfo: Sendable, Equatable {
    public let authDir: String
    public let credentialFiles: Int
    public let hasConfig: Bool
}

public enum CLIProxyDetect {
    /// Default management-API port; the runtime probe belongs to the app
    /// layer (URLSession), this is the on-disk half.
    public static let defaultPort = 8317

    public static func info(home: String = NSHomeDirectory()) -> CLIProxyInfo? {
        let dir = "\(home)/.cli-proxy-api"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return CLIProxyInfo(
            authDir: dir,
            credentialFiles: names.filter { $0.hasSuffix(".json") }.count,
            hasConfig: names.contains("config.yaml"))
    }
}

// MARK: - "Copy for an AI agent" (user 2026-09-03)

/// The first-run brief a user hands to a coding agent: what is already on
/// this machine, what is missing, and the exact commands — the same
/// shape as the Devices pane's phone brief. Pure text, so `swift test`
/// covers every branch.
public enum OnboardingBrief {
    public static func text(engineInstalled: Bool, claude: ClaudeCLIInfo?,
                            proxy: CLIProxyInfo?, proxyLive: Bool) -> String {
        var out = ["# Set up Infinitus on this Mac", "",
                   "Infinitus is a menu bar cockpit over the claude-swap engine (`cswap`): it "
                   + "rotates Claude Code between several Claude accounts and shows their "
                   + "5-hour / 7-day usage. Do the unticked steps in order; every command is "
                   + "safe to re-run. Ask before signing into any account — a human types the "
                   + "credentials.", "",
                   "## Found on this Mac"]
        out.append("- claude-swap engine (cswap): \(engineInstalled ? "installed" : "NOT installed")")
        if let claude {
            out.append("- Claude Code: " + (claude.binaryPath.map { "at \($0)" } ?? "not found")
                       + (claude.email.map { " — signed in as \($0)" + org(claude.organization) } ?? " — not signed in"))
        } else {
            out.append("- Claude Code: not checked yet")
        }
        if let proxy {
            out.append("- CLIProxyAPI (optional second engine): "
                       + (proxy.hasConfig ? "config present, \(proxy.credentialFiles) credential file(s), "
                          + (proxyLive ? "running" : "not running") : "not set up"))
        }
        out += ["", "## Steps"]
        out.append("- [\(engineInstalled ? "x" : " ")] 1. Install the engine: `brew install uv` if `uv` is missing, then "
                   + "`uv tool install claude-swap`. Relaunch Infinitus (or click Install engine in its popup).")
        let signedIn = claude?.email != nil
        out.append("- [\(signedIn ? "x" : " ")] 2. Sign Claude Code into the first account: run `claude`, use "
                   + "`/login`, the human completes the browser sign-in.")
        out.append("- [ ] 3. Register it: `cswap add` (adopts Claude Code's current login). "
                   + "Repeat 2–3 for every extra account: `/logout` in Claude Code, `/login` as the "
                   + "next account, `cswap add` again. `cswap list` shows the fleet.")
        out.append("- [ ] 4. Start auto-rotation: Infinitus runs `cswap auto` itself once the "
                   + "fleet has accounts (Settings → Engines shows it; `infinitusctl status` from "
                   + "Infinitus.app/Contents/MacOS confirms).")
        out.append("- [ ] 5. Optional, CLIProxyAPI as a second engine: `brew install cliproxyapi` "
                   + "(or the release binary), start it, then in Infinitus Settings → Engines → "
                   + "CLIProxyAPI paste the management key (the human pastes secrets) and add "
                   + "accounts from the same tab.")
        out.append("- [ ] 6. Optional, the phone: Infinitus Settings → Devices has its own "
                   + "\"Copy for an AI agent\" brief for pairing the iPhone app.")
        out += ["", "## Verify", "`cswap list --json` lists every account with usage; the Infinitus popup "
                + "shows one row per account with 5h/7d bars; `infinitusctl status` reports "
                + "`badge: running`."]
        return out.joined(separator: "\n")
    }

    private static func org(_ o: String?) -> String { o.map { " (\($0))" } ?? "" }
}

// MARK: - "Install engine" bootstrap (user 2026-09-03)

/// What the Install engine button has to run. `uv tool install
/// claude-swap` needs `uv`, and a Mac that has never installed it dead
/// -ended on "uv not found — get it first: brew install uv" — a button
/// that asks you to open a terminal is the terminal, one click later.
/// So a missing `uv` is a first STEP, not a failure: Homebrew when it is
/// there, else Astral's standalone installer, which needs no Homebrew
/// and no sudo (it lands in `~/.local/bin`, already a locator candidate).
public enum EngineInstall {
    public enum Bootstrap: Equatable, Sendable {
        /// `brew install uv`, with the brew binary that was found.
        case brew(String)
        /// `curl -LsSf https://astral.sh/uv/install.sh | sh`
        case standalone
    }

    public enum Step: Equatable, Sendable {
        case installUV(Bootstrap)
        /// `uv tool install claude-swap`, run with whatever `uv` the
        /// re-locate finds — the path is not known before the bootstrap.
        case installEngine
    }

    public static func uvCandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "\(home)/.cargo/bin/uv",
        ]
    }

    public static func brewCandidates() -> [String] {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    }

    /// The steps to run, in order, given what is already on disk.
    public static func plan(uv: String?, brew: String?) -> [Step] {
        guard uv == nil else { return [.installEngine] }
        return [.installUV(brew.map(Bootstrap.brew) ?? .standalone), .installEngine]
    }

    /// The shell one-liner for `.standalone`. `set -o pipefail` so a
    /// failed download can't be piped into a successful `sh`.
    public static let standaloneScript =
        "set -o pipefail; curl -LsSf https://astral.sh/uv/install.sh | sh"

    /// What the user is told while a step runs.
    public static func progressMessage(_ step: Step) -> String {
        switch step {
        case .installUV(.brew): return "Installing uv with Homebrew…"
        case .installUV(.standalone): return "Installing uv…"
        case .installEngine: return "Installing claude-swap…"
        }
    }

    /// What the user is told when a step fails. `output` is the tail of
    /// the child's combined stdout+stderr.
    public static func failureMessage(_ step: Step, output: String) -> String {
        let tail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
        switch step {
        case .installUV:
            return "Couldn't install uv: \(tail)"
        case .installEngine:
            return "Install failed: \(tail)"
        }
    }
}
