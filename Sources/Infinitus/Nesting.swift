import AppKit

/// #777: the same app placed inside the Infinitus desktop bundle as its
/// menu-bar login item (`Contents/Library/LoginItems/Infinitus Menu Bar.app`).
/// Bundle id, prefs, App Support, keychain and the control socket stay the
/// standalone app's; what changes is who updates it, who registers it at
/// login, and which sessions' notifications it owns.
enum Nesting {
    static let bundlePath = Bundle.main.bundleURL.path
    static let isNested = nested(bundlePath)

    /// Path-based, so the desktop's build never has to remember a plist key.
    static func nested(_ path: String) -> Bool { path.contains("/Contents/Library/LoginItems/") }

    /// Another `run.infinitus` from a different bundle — the cask copy
    /// beside a nested helper, or the reverse. The process already running
    /// keeps the menu bar and the control socket; this one leaves. Dev
    /// instances (their own INFINITUS_CONTROL_SOCKET, or an unbundled
    /// binary) never take part. A twin on its way out — the desktop's
    /// `quit` answers before the process exits, and a team quit can hold
    /// it up to TeamModel.quitBound — is waited out first.
    static func yieldsToRunningTwin() -> Bool {
        guard ProcessInfo.processInfo.environment["INFINITUS_CONTROL_SOCKET"] == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              let id = Bundle.main.bundleIdentifier else { return false }
        let own = Bundle.main.bundleURL.standardizedFileURL
        let me = ProcessInfo.processInfo.processIdentifier
        func twin() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                $0.processIdentifier != me && !$0.isTerminated
                    && $0.bundleURL?.standardizedFileURL != own
            }
        }
        guard twin() != nil else { return false }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            guard twin() != nil else { return false }
        }
        guard let other = twin() else { return false }
        Lifecycle.log.notice("yielding to pid \(other.processIdentifier) at \(other.bundleURL?.path ?? "?", privacy: .public) — one Infinitus per Mac")
        return true
    }
}
