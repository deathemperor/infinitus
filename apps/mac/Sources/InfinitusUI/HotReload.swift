import SwiftUI
import Combine

/// Hot reload for the dev loop (InjectionIII, docs/guides/hot-reload.md).
/// The injection bundle swaps a changed file's code in place and posts
/// `INJECTION_BUNDLE_NOTIFICATION`; this observer turns that into a
/// SwiftUI invalidation so the roots re-render with the new bodies.
/// Release builds never load the bundle, so nothing here ever fires.
public final class InjectionObserver: ObservableObject {
    public static let shared = InjectionObserver()
    @Published public private(set) var generation = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"),
            object: nil, queue: .main) { [weak self] _ in
                self?.generation += 1
            }
    }
}

private struct ReloadOnInjection: ViewModifier {
    @ObservedObject private var observer = InjectionObserver.shared
    func body(content: Content) -> some View {
        // A new identity rebuilds the whole subtree, so every injected
        // body runs again — at the cost of view state, which is fine for
        // a dev edit-save-look loop.
        content.id(observer.generation)
    }
}

public extension View {
    /// Put on each window's root view. A no-op until something injects.
    func reloadOnInjection() -> some View {
        #if DEBUG
        modifier(ReloadOnInjection())
        #else
        self
        #endif
    }
}
