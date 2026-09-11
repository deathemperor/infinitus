import SwiftUI
import InfinitusCore

/// T3's `<SidebarGroup>` + `<SidebarGroupLabel>` (ui/sidebar.tsx): a padded
/// column ("p-[var(--sidebar-content-inset)]") under an h-8 xs label.
public struct T3SidebarGroup<Content: View>: View {
    @Environment(\.t3) private var t3
    let label: String
    let content: Content
    public init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {   // <SidebarMenu> "gap-1"
            Text(label)
                .font(T3Font.web(.xs, .medium))
                .foregroundStyle(t3.web.sidebarForeground.color)
                .padding(.horizontal, 8)
                .frame(height: 32, alignment: .leading)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(T3Theme.Metrics.sidebarContentInset)
    }
}

/// T3's `<SidebarMenuButton>` at its default size: "h-8 rounded-[control-radius]
/// px-[var(--sidebar-row-content-inset)] text-sm", hover `sidebar-row-hover`,
/// `data-[active=true]` `sidebar-row-selected` + `sidebar-foreground`.
public struct T3SidebarMenuItem<Trailing: View>: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let title: String, icon: Lucide?, selected: Bool, trailing: Trailing
    public init(title: String, icon: Lucide? = nil, selected: Bool = false,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.icon = icon; self.selected = selected; self.trailing = trailing()
    }
    public var body: some View {
        let p = t3.web
        HStack(spacing: 8) {   // --sidebar-control-gap: 0.5rem
            if let icon { LucideIcon(icon, size: 16) }
            Text(title).font(T3Font.web(.sm, .medium)).lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, T3Theme.Metrics.sidebarRowContentInset)
        .frame(height: 32)
        .foregroundStyle(selected || hover ? p.sidebarForeground.color : p.sidebarMutedForeground.color.opacity(0.8))
        .background(rowBackground, in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
        .onHover { hover = $0 }
    }
    private var rowBackground: Color {
        if selected { return t3.web.sidebarRowSelected.color }
        return hover ? t3.web.sidebarRowHover.color : .clear
    }
}

public extension T3SidebarMenuItem where Trailing == EmptyView {
    init(title: String, icon: Lucide? = nil, selected: Bool = false) {
        self.init(title: title, icon: icon, selected: selected) { EmptyView() }
    }
}

/// T3's `<SidebarRail>`: a 16 px grab strip whose 2 px hairline shows
/// `sidebar-border` under the pointer ("w-4 after:w-[2px] hover:after:bg-sidebar-border").
public struct T3SidebarRail: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    public init() {}
    public var body: some View {
        Color.clear
            .frame(width: 16)
            .overlay(Rectangle().fill(hover ? t3.web.sidebarBorder.color : .clear).frame(width: 2))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
