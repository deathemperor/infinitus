import Foundation
import InfinitusCore
import UserNotifications

/// The call to action for an AWS sign-in (user 2026-09-05: "Add a call
/// to action when needing aws login"): a local notification the first
/// time a refresh — foreground or the background task — sees a login
/// the previous snapshot didn't have, tap → the sign-in sheet. Local,
/// so it needs no push; once per login until it clears.
@MainActor
final class AwsLoginAlerts {
    static let shared = AwsLoginAlerts()
    static let userInfoKey = "awsLogin"
    private var known: Set<String>?

    /// Called with every snapshot's logins. The first snapshot after a
    /// launch only seeds: the list is on screen, a banner would repeat it.
    func sync(_ logins: [AwsLogin.Item]) {
        let ids = Set(logins.map(\.id))
        defer { known = ids }
        guard let known else { return }
        let center = UNUserNotificationCenter.current()
        let cleared = known.subtracting(ids)
        if !cleared.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: cleared.map(Self.identifier))
        }
        for item in logins where !known.contains(item.id) {
            let content = UNMutableNotificationContent()
            content.title = "\(item.sessionLabel ?? "A session") needs an AWS sign-in"
            content.body = "profile \(item.profile) · tap to sign in from here"
            content.sound = .default
            content.userInfo = [Self.userInfoKey: item.id]
            center.add(UNNotificationRequest(identifier: Self.identifier(item.id),
                                             content: content, trigger: nil))
        }
    }

    private static func identifier(_ id: String) -> String { "aws-login-" + id }
}
