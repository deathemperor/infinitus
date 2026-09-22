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
