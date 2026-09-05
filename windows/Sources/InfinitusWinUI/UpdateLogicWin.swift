import Foundation
import InfinitusCore

public enum UpdateLogicWin {
    public enum InstallLocation: Equatable, Sendable {
        case debugBuild
        case installed
        case other(String)
    }

    /// Strips leading 'v' from a release tag.
    public static func normalizeTag(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Compares current version against remote tag using PackageVersion.
    /// Returns true if remote is newer.
    public static func isUpdateAvailable(current: String, latest: String) -> Bool {
        let norm = normalizeTag(latest)
        guard let currVer = PackageVersion(current),
              let latestVer = PackageVersion(norm) else {
            return false
        }
        return currVer < latestVer
    }

    /// Determines if 24h have passed since last auto check.
    public static func shouldCheck(lastCheck: Double, now: Double, enabled: Bool) -> Bool {
        guard enabled else { return false }
        return (now - lastCheck) >= 24 * 3600
    }

    /// Determines whether to trigger a notification balloon (fires once per version).
    public static func shouldNotify(latest: String, lastNotified: String) -> Bool {
        let norm = normalizeTag(latest)
        return !norm.isEmpty && norm != lastNotified
    }

    /// Classifies installation directory based on binary path.
    public static func classifyInstallLocation(path: String) -> InstallLocation {
        let lower = path.lowercased()
        if lower.contains("\\.build\\debug") || lower.contains("/.build/debug") {
            return .debugBuild
        }
        if lower.contains("\\infinitus\\bin") || lower.contains("/infinitus/bin") {
            return .installed
        }
        return .other(path)
    }

    /// Formats update instructions command block.
    public static func updateCommands(autostart: Bool) -> String {
        var cmd = "cd <repo>\r\ngit pull\r\npowershell -ExecutionPolicy Bypass -File .\\windows\\install.ps1"
        if autostart {
            cmd += " -Autostart"
        }
        return cmd
    }
}
