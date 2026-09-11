import InfinitusCore
import UIKit
import os

/// The app icon follows the theme (#83, user 2026-09-05: "Themify the
/// app icons too"): one alternate icon per built-in theme, rendered by
/// make-theme-icons.swift; a custom theme keeps the stock icon. iOS
/// shows an alert on every change, so the switch happens only when the
/// effective theme moved to a different icon.
@MainActor
enum AppIcons {
    private static let log = Logger(subsystem: "run.infinitus.mobile", category: "icons")
    private static let themed: Set<String> = [
        "rpg", "movie", "hades", "mgs", "agent", "swe", "scifi", "west",
        "cyber", "gothic", "musical", "earth", "cosmo", "ocean",
    ]

    static func follow(themeID: String) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let wanted = themed.contains(themeID) ? "AppIcon-\(themeID)" : nil
        guard UIApplication.shared.alternateIconName != wanted else { return }
        UIApplication.shared.setAlternateIconName(wanted) { error in
            if let error { log.error("icon \(wanted ?? "stock") refused: \(error.localizedDescription)") }
        }
    }
}
