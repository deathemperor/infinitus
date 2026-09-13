import SwiftUI
import InfinitusCore

/// The popup footer's trailing group (#9 phase D2): Claude service
/// status, the engine badge, then the update chips. Everything here is
/// plain SwiftUI, so the phone renders the very same footer the mac does.
///
/// The mac keeps the pieces that need AppKit outside: the action
/// buttons (pin, layout, settings, quit) stay in MenuContent, the
/// service chip's hover card rides in through `serviceChrome`, and the
/// status VALUE is passed rather than read off the model — the mac's
/// ServiceStatusModel is its own observable and a computed hop through
/// AppModel would never publish its updates.
public struct FooterChips<M: FleetModel, Service: ViewModifier>: View {
    @ObservedObject var model: M
    let status: ServiceStatusSummary?
    let onStatusTap: () -> Void
    let serviceChrome: Service

    public init(model: M, status: ServiceStatusSummary?,
                onStatusTap: @escaping () -> Void = {},
                serviceChrome: Service) {
        self.model = model
        self.status = status
        self.onStatusTap = onStatusTap
        self.serviceChrome = serviceChrome
    }

    public var body: some View {
        HStack(spacing: 6) {
            serviceChip
            engineBadge
            Spacer().frame(width: 6)
            if model.appUpdatePending {
                Button {
                    model.relaunchApp()
                } label: {
                    Label("Restart to update",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                .font(PopupFont.body)
                .help("A newer build is on disk")
            }
            if let v = model.appUpdateVersion {
                Button { model.openSettings() } label: {
                    Label("Update \(v)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.orange)
                }
                .font(PopupFont.body)
                .help("Infinitus \(v) is out — About → Updates")
            }
        }
    }

    private var serviceChip: some View {
        Button(action: onStatusTap) {
            HStack(spacing: 4) {
                Circle().fill(ServiceStatusColor.of(status)).frame(width: 7, height: 7)
                Text(status?.shortText ?? "status")
                    .font(PopupFont.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .modifier(serviceChrome)
    }

    /// Clickable on the mac: running <-> stopped ("auto switch status is
    /// clickable to toggle", user 2026-08-30). Other states stay
    /// informational; a mirroring host's toggle is a no-op.
    @ViewBuilder private var engineBadge: some View {
        if let engine = model.engineBadge {
            Button { model.toggleEngine() } label: {
                switch engine {
                case .running: Label("auto", systemImage: "bolt.fill").foregroundStyle(.green)
                case .refused: Label("engine elsewhere", systemImage: "exclamationmark.triangle")
                case .backingOff(let s): Label("retry \(Int(s))s", systemImage: "clock")
                case .schemaMismatch: Label("update app", systemImage: "arrow.down.circle")
                case .stopped: Label("off", systemImage: "pause").foregroundStyle(.secondary)
                }
            }
            // PopupFont.body, not the inherited default: an unstyled
            // Label resolves to 17pt on iOS against the mac's 13pt.
            .font(PopupFont.body)
            .buttonStyle(.plain)
            .instantTip(EngineBadgeText.tip(engine), edge: .above)
        }
    }
}

public extension FooterChips where Service == EmptyModifier {
    /// A host with nothing to hang on the service chip (the phone: no
    /// hover pointer, no status hover card).
    init(model: M, status: ServiceStatusSummary?,
         onStatusTap: @escaping () -> Void = {}) {
        self.init(model: model, status: status,
                  onStatusTap: onStatusTap, serviceChrome: EmptyModifier())
    }
}

/// The status indicator's dot color — the mac's ServiceStatusModel keeps
/// its own copy of this switch (it colors the compact rail's dot too).
public enum ServiceStatusColor {
    public static func of(_ status: ServiceStatusSummary?) -> Color {
        switch status?.indicator {
        case "none": return .green
        case "minor": return .yellow
        case "major": return .orange
        case "critical": return .red
        default: return .gray
        }
    }
}

/// The engine badge's tooltip wording, shared with the mac's rail icon.
public enum EngineBadgeText {
    public static func tip(_ engine: EngineBadge) -> String {
        switch engine {
        case .running: return "auto-switch running — click to stop"
        case .refused: return "Another auto-switch daemon (a stray swapd auto) holds the engine's mutex."
        case .backingOff(let s): return "engine retrying in \(Int(s))s — click to stop"
        case .schemaMismatch: return "update the app"
        case .stopped: return "auto-switch off — click to start"
        }
    }
}

