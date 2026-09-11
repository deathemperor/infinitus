import SwiftUI
import InfinitusCore

/// Every component of the kit in one stack per platform set, in both schemes:
/// the previews the parity harness (§3.6) crops its component shots from.

struct T3WebKitPreview: View {
    @State private var text = "feature/status-pill"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                T3Button("Run") {}
                T3Button("Cancel", variant: .secondary) {}
                T3Button("Settings", variant: .ghost, icon: .settings) {}
                T3Button("Branch", variant: .outline, icon: .gitBranch) {}
                T3Button("Delete", variant: .destructive, size: .sm) {}
                T3Button("Add", size: .icon, icon: .plus) {}
            }
            HStack(spacing: 8) {
                T3Badge("Running")
                T3Badge("Draft", variant: .secondary)
                T3Badge("main", variant: .outline)
                T3Badge("Failed", variant: .destructive)
                T3Kbd("⌘K")
                T3Spinner()
            }
            T3Input(text: $text, placeholder: "Search threads", leading: .search)
            T3Separator()
            VStack(alignment: .leading, spacing: 8) {
                T3Skeleton(width: 180)
                T3Skeleton(height: 12)
            }
            T3Tooltip("Open the thread") { T3Button("Hover me", variant: .outline) {} }
            HStack(alignment: .top, spacing: 0) {
                T3SidebarGroup(label: "Threads") {
                    T3SidebarMenuItem(title: "Status pill", icon: .messageSquare, selected: true)
                    T3SidebarMenuItem(title: "Token parity", icon: .messageSquare)
                }
                .frame(width: T3Theme.Metrics.sidebarWidth)
                T3SidebarRail()
                T3ScrollArea {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<12, id: \.self) { i in Text("Row \(i)").font(T3Font.web(.sm)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 160, height: 120)
            }
        }
        .padding(16)
    }
}

struct T3MobileKitPreview: View {
    @State private var on = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                T3ControlPill("New thread", icon: .plus) {}
                T3ControlPill("Filter", icon: .ellipsis, style: .glass) {}
                T3ProviderIcon(size: 20)
                T3ThemedSwitch(isOn: $on)
            }
            HStack(spacing: 8) {
                ForEach(T3ThreadStatus.allCases, id: \.self) { T3StatusPill($0) }
            }
            T3Wordmark(badge: "dev")
            T3LoadingStrip()
            T3ErrorBanner("The environment went offline while the turn was running.")
            T3GlassSurface {
                Text("Glass chrome").font(T3Font.mobile(.sm, .medium)).padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            T3EmptyState(title: "No environments connected",
                         message: "Connect a machine to start a thread on it.",
                         action: ("Connect a machine", {}))
        }
        .padding(16)
    }
}

#Preview("web light") {
    T3WebKitPreview().t3(platform: .web, scheme: .light).preferredColorScheme(.light)
}
#Preview("web dark") {
    T3WebKitPreview().t3(platform: .web, scheme: .dark).preferredColorScheme(.dark)
}
#Preview("mobile light") {
    T3MobileKitPreview().t3(platform: .mobile, scheme: .light).preferredColorScheme(.light)
}
#Preview("mobile dark") {
    T3MobileKitPreview().t3(platform: .mobile, scheme: .dark).preferredColorScheme(.dark)
}
