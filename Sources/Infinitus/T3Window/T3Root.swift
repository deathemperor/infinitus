import SwiftUI
import InfinitusCore
import InfinitusUI

/// Placeholder root — Task 6 replaces this with the real sidebar / thread
/// / composer layout.
struct T3Root: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var app: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t3 = T3Environment(platform: .web, scheme: scheme)
        ZStack {
            t3.web.background.color.ignoresSafeArea()
            Text("\(model.state.threads.count) threads")
                .font(T3Font.web(.sm))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        .frame(minWidth: T3WindowController.minimumSize.width, minHeight: T3WindowController.minimumSize.height)
        // ⌘W closes the workspace window — an accessory app has no menu bar
        // to route the standard close item, so this is the only way in
        // (the ⌘⇧T pattern in PinnedRoot).
        .overlay {
            Button("") { model.closeRequested?() }
                .keyboardShortcut("w", modifiers: [.command])
                .buttonStyle(.plain)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .environment(\.t3, t3)
    }
}
