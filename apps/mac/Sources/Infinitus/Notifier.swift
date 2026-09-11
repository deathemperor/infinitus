import Foundation
import UserNotifications
import InfinitusCore

/// User notifications for switch / quota-restored / session-resumed
/// (backlog item 5, v1 scope).
///
/// Two paths: UNUserNotificationCenter when running from a .app bundle that
/// Notification Center actually accepts, else osascript. The UN path can
/// fail at runtime even with a bundle id (ad-hoc signatures are one cause:
/// the auth grant is keyed to the code signature, which changes every
/// rebuild) — so a UN failure downgrades to osascript instead of dropping
/// the notification, and the failure reason is kept for the UI.
enum Notifier {
    /// Last UN-center failure, for surfacing in the popup. Main-thread only.
    nonisolated(unsafe) static var lastAuthError: String?
    private nonisolated(unsafe) static var unUsable = Bundle.main.bundleIdentifier != nil

    /// Call once at app launch (bundled app only): puts the macOS permission
    /// prompt in front of the user immediately instead of at the first
    /// switch — which is exactly when nobody is watching the screen.
    static func requestAuthorization() {
        guard unUsable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    unUsable = false
                    DispatchQueue.main.async {
                        lastAuthError = "notifications degraded to osascript: \(error.localizedDescription)"
                    }
                    NSLog("Infinitus: UN auth failed, using osascript: \(error)")
                } else if !granted {
                    unUsable = false
                    DispatchQueue.main.async {
                        lastAuthError = "notifications denied in System Settings; using osascript"
                    }
                    NSLog("Infinitus: UN auth not granted")
                } else {
                    NSLog("Infinitus: UN auth granted — native notifications active")
                }
            }
    }

    static func post(title: String, body: String) {
        // "needs AWS login — repo (profile)": the headline is the banner's
        // subtitle, the detail its body — on both paths (#98).
        let parts = body.components(separatedBy: " — ")
        let subtitle = parts.count > 1 ? parts[0] : nil
        let detail = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : body
        if unUsable {
            postBundled(title: title, subtitle: subtitle, body: detail)
        } else {
            postOsascript(title: title, subtitle: subtitle, body: detail)
        }
    }

    private static func postBundled(title: String, subtitle: String?, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil)
        ) { error in
            if let error {
                // Delivery refused (unauthorized, unregistered bundle…) —
                // never drop the notification: resend via osascript.
                unUsable = false
                NSLog("Infinitus: UN post failed, resending via osascript: \(error)")
                postOsascript(title: title, subtitle: subtitle, body: body)
            }
        }
    }

    private static func postOsascript(title: String, subtitle: String?, body: String) {
        var script = "display notification \"\(AppleScriptEscaping.literal(body))\""
            + " with title \"\(AppleScriptEscaping.literal(title))\""
        if let subtitle {
            script += " subtitle \"\(AppleScriptEscaping.literal(subtitle))\""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
