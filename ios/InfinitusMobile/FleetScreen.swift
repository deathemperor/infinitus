import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Mac popup, on the phone (#9 phase D2): the same shared views in
/// the same order MenuContent's wide branch renders them — header, rows,
/// the all-dead banner, the sessions card, a divider, the footer chips —
/// on the same chrome, scaled to the screen the way the mac scales to
/// its popover. The mac's action buttons (pin, layout, quit…) have no
/// phone equivalent; Settings rides a small overlay button instead of a
/// navigation bar, so the header stays the centered "∞ Infinitus".
///
/// Since the native shell landed (#9), this is the "Show as Mac popup"
/// view — kept 1:1, one Settings toggle away.
struct FleetScreen: View {
    @ObservedObject var model: MirrorModel
    @State private var settingsShown = false

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height >= geo.size.width
            ScrollView {
                popup
                    .popupFit(available: geo.size.width, portrait: portrait,
                              textScale: model.popupScale)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await model.refresh() }
            .overlay(alignment: .topTrailing) {
                Button { settingsShown = true } label: {
                    Image(systemName: "gearshape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .onAppear { model.isLandscape = geo.size.width > geo.size.height }
            .onChange(of: geo.size) { _, size in
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.3)) {
                    model.isLandscape = size.width > size.height
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Polling and the foreground intro replay live in RootView — the
        // native shell needs them too, and only one shell is on screen.
        .sheet(isPresented: $settingsShown) { SettingsScreen(model: model) }
        // ONE tip chip for the whole screen, drawn above every row —
        // same plumbing the mac popup uses.
        .overlayPreferenceValue(ActiveTipKey.self) { InstantTipCanvas(tips: $0) }
        // The bars take their fill-up cue from the environment, not the
        // model (GaugeBar has no model) — set it once, like MenuContent.
        .environment(\.introTick, model.introTick)
        .environment(\.introBarDelay, model.introBarDelay)
    }

    /// MenuContent's wide branch, minus the mac-only action buttons: the
    /// spacings (8), the footer's chip spacing (6), the popup padding
    /// (10) and the wide layout's 560 floor are all copied from there.
    private var popup: some View {
        VStack(alignment: .leading, spacing: 8) {
            InfinitusHeader(model: model)
            mirrorState
            accountArea
            AllDeadBanner(model: model)
            sessionsCard
            Divider()
            HStack(spacing: 6) {
                Spacer()
                FooterChips(model: model, progress: model.sessionProgress,
                            status: model.serviceStatus)
            }
        }
        .padding(10)
        .frame(minWidth: model.popupLayout == "wide" ? 560 : nil)
        .background(PopupChrome(theme: model.rowTheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The phone's own lines: a read error, the first-launch "no
    /// snapshot yet" card, and the staleness note. All three are silent
    /// on a healthy mirror, so the popup above stays the mac's.
    @ViewBuilder private var mirrorState: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if model.snapshot == nil, model.error == nil {
            ThemedPlaceholder(theme: model.rowTheme, key: "searching", plainSymbol: "antenna.radiowaves.left.and.right",
                              description: "Pair with the Mac in Settings — its accounts show up as soon as it answers.")
        }
        if let snapshot = model.snapshot, isStale(snapshot.capturedAt) {
            StalenessBanner(capturedAt: snapshot.capturedAt)
        }
    }

    /// The shared popup rows — one section per engine fleet (#9 issue 9),
    /// cards in portrait, the wide grid in landscape
    /// (MirrorModel.popupLayout). Both render at their natural width now;
    /// PopupFit scales the whole popup to the screen.
    /// Fleets with prefix "claude-code-" that have no accounts (like Windows)
    /// are hidden from the Fleet tab (04-phone.md).
    @ViewBuilder private var accountArea: some View {
        Group {
            let visibleFleets = model.fleets.filter { fleet in
                !(fleet.engineID.hasPrefix("claude-code-") && fleet.accounts.isEmpty)
            }
            if visibleFleets.allSatisfy({ $0.accounts.isEmpty }) {
                EmptyView()
            } else {
                FleetStack(fleets: visibleFleets)
            }
        }
        .introContent(model)
    }

    /// The mac pops this card over the brain chip; the phone has no
    /// hover and a popover on a phone is a sheet, so it rides inline
    /// whenever the Mac has sessions at all.
    @ViewBuilder private var sessionsCard: some View {
        if let live = model.liveSessions, live.total > 0 {
            SessionListCard(live: live, progress: model.sessionProgress)
        }
    }

    private func isStale(_ capturedAt: Date) -> Bool {
        Date().timeIntervalSince(capturedAt) > 180
    }
}

private struct StalenessBanner: View {
    let capturedAt: Date

    var body: some View {
        Text("as of \(capturedAt.formatted(date: .omitted, time: .shortened)) — is the Mac awake?")
            .font(.caption).foregroundStyle(.orange)
    }
}
