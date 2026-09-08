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
        .environment(\.t3, t3)
    }
}
