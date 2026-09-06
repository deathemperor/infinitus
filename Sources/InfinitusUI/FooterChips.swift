import SwiftUI
import InfinitusCore

/// The popup footer's trailing group (#9 phase D2): Claude service
/// status, the agent/brain chip with its sessions card, the engine
/// badge, then the update chips. Everything here is plain SwiftUI, so
/// the phone renders the very same footer the mac does.
///
/// The mac keeps the pieces that need AppKit outside: the action
/// buttons (pin, layout, settings, quit) stay in MenuContent, the
/// service chip's hover card rides in through `serviceChrome`, and the
/// status VALUE is passed rather than read off the model — the mac's
/// ServiceStatusModel is its own observable and a computed hop through
/// AppModel would never publish its updates.
public struct FooterChips<M: FleetModel, P: SessionProgressSource,
                          Service: ViewModifier>: View {
    @ObservedObject var model: M
    @ObservedObject var progress: P
    let status: ServiceStatusSummary?
    let onStatusTap: () -> Void
    let serviceChrome: Service

    public init(model: M, progress: P, status: ServiceStatusSummary?,
                onStatusTap: @escaping () -> Void = {},
                serviceChrome: Service) {
        self.model = model
        self.progress = progress
        self.status = status
        self.onStatusTap = onStatusTap
        self.serviceChrome = serviceChrome
    }

    public var body: some View {
        HStack(spacing: 6) {
            serviceChip
            agentChip
            tokenChip
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

    /// Live Claude Code sessions on the host machine — they all ride the
    /// active account's credential.
    @ViewBuilder private var agentChip: some View {
        if let live = model.liveSessions {
            HStack(spacing: 3) {
                Image(systemName: "brain")
                    .font(PopupFont.caption)
                    .foregroundStyle(live.busy > 0 ? Color.orange : Color.secondary)
                Text(live.busy > 0 ? "\(live.busy) working · \(live.total)"
                                   : "\(live.total)")
                    .font(PopupFont.caption).monospacedDigit()
                    .foregroundStyle(live.busy > 0 ? Color.orange : Color.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.sessionsShown.toggle() }
            .popover(isPresented: Binding(get: { model.sessionsShown },
                                          set: { model.sessionsShown = $0 }),
                     arrowEdge: .bottom) {
                SessionListCard(live: live, progress: progress)
            }
            .instantTip(SessionSummary.tooltip(live), edge: .above)
        }
    }

    /// Output tokens per minute across the live sessions (user
    /// 2026-09-03 "display tokens/minute gauge"), a bar scaled to the
    /// recent peak — shown only while something is actually flowing.
    @ViewBuilder private var tokenChip: some View {
        if let rate = progress.tokenRate, rate.perMinute > 0 {
            // At peak = the current rate IS the recent high (the peak
            // decays, so this is "as fast as it has been lately"): the
            // chip goes into overdrive (user 2026-09-03 "if current at
            // peak, animate it dramatically") — all Core Animation.
            let atPeak = rate.perMinute >= rate.peakPerMinute
            let theme = model.rowTheme
            HStack(spacing: 4) {
                Group {
                    if let glyph = theme.rateGlyph {
                        Text(PopupGlyph.text(glyph))
                    } else {
                        Image(systemName: "bolt.horizontal.fill").foregroundStyle(.yellow)
                    }
                }
                .font(PopupFont.caption)
                .overlay { if atPeak { TokenPeakGlow() } }
                TokenRateBar(fraction: rate.fraction, atPeak: atPeak)
                    .frame(width: 34, height: 6)
                Text(rate.label(theme: theme))
                    .font(PopupFont.caption).monospacedDigit()
                    .fontWeight(atPeak ? .bold : .regular)
                    .foregroundStyle(atPeak ? Color.yellow : Color.secondary)
            }
            .instantTip("Output tokens per minute, every live session, last "
                        + "\(Int(TokenRate.window / 60)) min — "
                        + (atPeak ? "at the recent peak right now"
                                  : "peak lately \(rate.peakPerMinute)/min"),
                        edge: .above)
        }
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
    init(model: M, progress: P, status: ServiceStatusSummary?,
         onStatusTap: @escaping () -> Void = {}) {
        self.init(model: model, progress: progress, status: status,
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
        case .refused: return "Another auto-switch engine (TUI or cswap auto) holds the mutex."
        case .backingOff(let s): return "engine retrying in \(Int(s))s — click to stop"
        case .schemaMismatch: return "update the app"
        case .stopped: return "auto-switch off — click to start"
        }
    }
}

/// The tokens/minute bar: fill = current over the recent peak. Plain
/// (no GaugeBar percent label — "% of peak" would read as usage).
public struct TokenRateBar: View {
    let fraction: Double
    let atPeak: Bool
    public init(fraction: Double, atPeak: Bool = false) {
        self.fraction = fraction
        self.atPeak = atPeak
    }
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.yellow)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                if atPeak {
                    TokenPeakOverdrive()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }
}

/// The bar at peak: a white-hot sheen sweeping the fill, the fill
/// breathing, sparks streaming off the tip — CAAnimations on a
/// LayerEffect host, nothing per frame (#18).
struct TokenPeakOverdrive: View {
    var body: some View {
        LayerEffect { host, bounds in
            let clip = CALayer()
            clip.frame = bounds
            clip.cornerRadius = bounds.height / 2
            clip.masksToBounds = true
            // Breath: the whole fill pulses between gold and white-hot.
            let heat = CALayer()
            heat.frame = bounds
            heat.backgroundColor = rgb(1, 0.95, 0.6)
            heat.add(CABasicAnimation.loop("opacity", from: 0.15, to: 0.6, duration: 0.45,
                                           autoreverses: true, easeInOut: true), forKey: "breath")
            clip.addSublayer(heat)
            // Sheen: a bright band racing left→right, twice a second.
            let sheen = CAGradientLayer()
            sheen.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width, height: bounds.height)
            sheen.startPoint = CGPoint(x: 0, y: 0.5)
            sheen.endPoint = CGPoint(x: 1, y: 0.5)
            sheen.colors = [rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.95), rgb(1, 1, 1, 0)]
            sheen.locations = [0, 0.5, 1]
            sheen.add(CABasicAnimation.loop("position.x", from: -bounds.width / 2,
                                            to: bounds.width * 1.5, duration: 0.55), forKey: "sweep")
            clip.addSublayer(sheen)
            host.addSublayer(clip)
            // Sparks off the right tip, drifting up and out.
            let cell = CAEmitterCell()
            cell.contents = BurnOverlay.sparkDot
            let life: Float = 0.9
            cell.lifetime = life
            cell.lifetimeRange = 0.3
            cell.birthRate = 26
            cell.color = rgb(1, 0.9, 0.35)
            cell.alphaSpeed = -1 / life
            let scale = host.contentsScale
            cell.contentsScale = scale
            cell.scale = 2.2 * scale / 16
            cell.scaleSpeed = -0.5 * cell.scale / CGFloat(life)
            cell.emissionLongitude = -.pi / 2   // .point emitter: up is -π/2
            cell.emissionRange = 1.1
            cell.velocity = 22
            cell.velocityRange = 10
            cell.yAcceleration = 18
            let e = CAEmitterLayer()
            e.contentsScale = scale
            e.frame = CGRect(x: 0, y: -bounds.height * 2, width: bounds.width + 12, height: bounds.height * 5)
            e.emitterShape = .point
            e.emitterPosition = CGPoint(x: bounds.maxX, y: bounds.height * 2.5)
            e.emitterCells = [cell]
            e.beginTime = CACurrentMediaTime() - Double(life)
            host.addSublayer(e)
        }
        .allowsHitTesting(false)
    }
}

/// The bolt at peak: a gold halo that breathes and a quick scale
/// throb, as CAAnimations behind the glyph.
struct TokenPeakGlow: View {
    var body: some View {
        LayerEffect { host, bounds in
            let halo = CALayer()
            let r = max(bounds.width, bounds.height)
            halo.frame = CGRect(x: bounds.midX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r)
            halo.cornerRadius = r
            halo.backgroundColor = rgb(1, 0.85, 0.2, 0.55)
            halo.add(CABasicAnimation.loop("opacity", from: 0.1, to: 0.7, duration: 0.4,
                                           autoreverses: true, easeInOut: true), forKey: "breath")
            halo.add(CABasicAnimation.loop("transform.scale", from: 0.7, to: 1.25, duration: 0.4,
                                           autoreverses: true, easeInOut: true), forKey: "throb")
            host.addSublayer(halo)
        }
        .allowsHitTesting(false)
    }
}
