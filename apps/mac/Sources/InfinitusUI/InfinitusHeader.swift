import SwiftUI
import InfinitusCore

/// The "Infinitus" strip: app icon + name, tinted by the active theme
/// (user request 2026-08-30). The pop-out wears it as its drag-strip
/// title; the full popover shows it above the rows.
public struct InfinitusHeader<M: FleetModel>: View {
    @ObservedObject var model: M

    public init(model: M) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 5) {
            icon
                .frame(width: 16, height: 16)
            Text("Infinitus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .introTitle(model)
        .frame(maxWidth: .infinity)
    }

    /// Always the glyph, tinted like the title — never the app-icon
    /// squircle: the header's icon must match the themed text ("before
    /// that the icon color match the text", user 2026-09-01; the raw
    /// icon only ever showed because bundled runs took a different
    /// branch than the unbundled dev builds). The SwiftUI shape, not
    /// the AppKit template image — this view renders off-mac too.
    private var icon: some View {
        InfinitusGlyph()
            .foregroundStyle(tint)
    }

    private var tint: Color {
        let theme = model.rowTheme
        if theme.plain || theme.id == "off" { return .secondary }
        return theme.flashColor.isEmpty ? .accentColor
                                        : ThemeColor.resolve(theme.flashColor)
    }
}
