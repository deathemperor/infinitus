import Foundation
import WinSDK

/// Façade for the new SettingsShell.
public enum SettingsWindow {
    /// Shows or brings existing Settings window to foreground.
    public static func show(paneID: String? = nil) {
        SettingsShell.show(paneID: paneID)
    }
}
