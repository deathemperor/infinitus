import SwiftUI

/// Which T3 client a view is standing in for, and which scheme (spec §3.1).
public struct T3Environment: Sendable, Equatable {
    public enum Platform: Sendable { case mobile, web }
    public var platform: Platform
    public var scheme: ColorScheme
    public init(platform: Platform, scheme: ColorScheme) { self.platform = platform; self.scheme = scheme }

    public var mobile: T3Theme.MobilePalette { scheme == .dark ? T3Theme.mobileDark : T3Theme.mobileLight }
    public var web: T3Theme.WebPalette { scheme == .dark ? T3Theme.webDark : T3Theme.webLight }

    static var defaultPlatform: Platform {
        #if os(iOS)
        return .mobile
        #else
        return .web
        #endif
    }
}

private struct T3EnvironmentKey: EnvironmentKey {
    static let defaultValue = T3Environment(platform: T3Environment.defaultPlatform, scheme: .light)
}

public extension EnvironmentValues {
    var t3: T3Environment {
        get { self[T3EnvironmentKey.self] }
        set { self[T3EnvironmentKey.self] = newValue }
    }
}

public extension View {
    /// Installs the T3 environment for a subtree, following the system scheme unless one is forced.
    func t3(platform: T3Environment.Platform, scheme: ColorScheme? = nil) -> some View {
        modifier(T3Installer(platform: platform, forced: scheme))
    }
}

private struct T3Installer: ViewModifier {
    let platform: T3Environment.Platform
    let forced: ColorScheme?
    @Environment(\.colorScheme) private var system
    func body(content: Content) -> some View {
        content.environment(\.t3, T3Environment(platform: platform, scheme: forced ?? system))
    }
}
