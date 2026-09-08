import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Settings sheet as T3 draws it (`SettingsSheet.tsx`, the layout
/// `refs/ios-settings.png` shows): centered title with a round close,
/// labelled groups of card rows — icon, label, value, chevron. This is
/// the shell (T3 clone C-7): each row pushes the existing settings group
/// until D restyles the pages.
struct T3SettingsSheet: View {
    @ObservedObject var model: MirrorModel
    /// The pushed group; the harness seeds it to render a page.
    @State var path: [SettingsForm.Part] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.t3) private var t3

    private var macCount: Int { (model.pairToken.isEmpty ? 0 : 1) + model.others.count }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    group("Configuration") {
                        row(.laptop, "Macs", value: macCount == 0 ? "None" : "\(macCount)", part: .macs)
                    }
                    group("General") {
                        row(.palette, "Appearance", part: .appearance)
                        row(.messageSquare, "Dictation", part: .dictation)
                        row(.frame, "Screenshots", part: .screenshots)
                        row(.circleAlert, "Notifications", part: .notifications)
                        row(.userPlus, "Team", part: .team)
                        row(.info, "About", part: .about)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(t3.mobile.sheet.color.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .navigationDestination(for: SettingsForm.Part.self) { part in
                SettingsForm(part: part, model: model)
                    .navigationTitle(part.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        ZStack {
            Text("Settings").font(T3Font.mobileLiteral(24, .bold)).foregroundStyle(t3.mobile.foreground.color)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(t3.mobile.icon.color)
                        .frame(width: 48, height: 48)
                        .background(t3.mobile.subtle.color, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .background(t3.mobile.sheet.color)
    }

    private func group<Rows: View>(_ label: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(T3Font.mobile(.base)).foregroundStyle(t3.mobile.foregroundMuted.color)
                .padding(.leading, 8).padding(.top, 8)
            VStack(spacing: 0) { rows() }
                .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func row(_ icon: Lucide, _ label: String, value: String? = nil, part: SettingsForm.Part) -> some View {
        NavigationLink(value: part) {
            HStack(spacing: 16) {
                LucideIcon(icon, size: 22).foregroundStyle(t3.mobile.icon.color).frame(width: 24)
                Text(label).font(T3Font.mobile(.lg)).foregroundStyle(t3.mobile.foreground.color)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(T3Font.mobile(.lg)).foregroundStyle(t3.mobile.foregroundMuted.color)
                }
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t3.mobile.chevron.color)
            }
            .padding(.horizontal, 20).frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
