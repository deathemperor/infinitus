import SwiftUI
import ServiceManagement

/// "Start at login" via SMAppService.mainApp. Registration binds to the app
/// bundle's CURRENT path (Infinitus.app in this checkout) —
/// rebuilding in place keeps it working, moving the repo silently breaks the
/// login item until the toggle is flipped off and on again.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published var enabled = false
    @Published var note: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        if Nesting.isNested {
            // #777: the desktop registers its login item from the outer
            // bundle; a toggle here would register the nested path as a
            // second, orphan item. A registration under this id that is
            // still enabled (the cask's, or the desktop's — SMAppService
            // exposes no path to tell them apart) is left alone.
            enabled = false
            note = status == .enabled
                ? "Start at login is Infinitus desktop's setting (Settings → General); a leftover Infinitus entry under System Settings → General → Login Items can be removed there."
                : "Start at login is Infinitus desktop's setting (Settings → General)."
            return
        }
        enabled = status == .enabled
        note = status == .requiresApproval
            ? "Waiting for approval — allow Infinitus under System Settings → General → Login Items."
            : nil
    }

    func set(_ wanted: Bool) {
        guard !Nesting.isNested else { refresh(); return }
        // `swift run Infinitus` has no .app bundle; SMAppService would
        // register the bare executable and the item would never launch.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            note = "Not running from the app bundle — build it first (make-app.sh), then toggle here."
            enabled = false
            return
        }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note = error.localizedDescription
        }
        refresh()
    }
}
