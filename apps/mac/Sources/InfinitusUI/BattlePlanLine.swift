import SwiftUI
import InfinitusCore

/// The reset battle plan (#7 MVP step 3, manual mode): one caption line
/// naming the steps the planner proposes, and — when a step is an
/// ignition — a confirm-gated button that runs it. Two taps: the first
/// arms ("Sure?"), the second fires; the arm times out on its own so a
/// stray click never ignites. Nothing runs by itself. After it fires the
/// chip's place says what happened for a few seconds (#338: a silent
/// success read as "nothing happens").
public struct BattlePlanLine<M: FleetModel>: View {
    @ObservedObject var model: M
    @State private var armed = false

    public init(model: M) {
        self.model = model
    }

    @ViewBuilder public var body: some View {
        if let plan = model.battlePlan {
            HStack(spacing: 6) {
                (Text(Image(systemName: "flag.checkered"))
                    .foregroundStyle(.orange)
                 + Text(" " + summary(plan)))
                    .font(PopupFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let result = model.igniteResult {
                    (Text(Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle"))
                     + Text(" " + result.text))
                        .font(PopupFont.caption)
                        .foregroundStyle(result.ok ? Color.green : Color.red)
                        .lineLimit(1)
                        .transition(.opacity)
                } else if model.canIgnite, let n = plan.igniteNumber {
                    igniteButton(n)
                }
            }
            .fixedSize()
            .help(plan.steps.map(\.why).joined(separator: "\n"))
        }
    }

    @ViewBuilder private func igniteButton(_ n: Int) -> some View {
        if model.igniting == n {
            ProgressView().controlSize(.mini)
        } else {
            Button {
                if armed {
                    armed = false
                    model.ignite(n)
                } else {
                    armed = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        armed = false
                    }
                }
            } label: {
                // Armed: a solid orange pill, not a tint under the caption
                // font — the 6 s window has to be seen to be used (#338).
                (Text(Image(systemName: armed ? "flame.fill" : "flame"))
                 + Text(armed ? " Sure? Ignite \(name(n))" : " Ignite \(name(n))"))
                    .font(PopupFont.caption.weight(armed ? .semibold : .regular))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(armed ? Color.orange : Color.secondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(armed ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .help(armed ? "Click again within 6 s to start \(name(n))'s window now"
                        : "Starts \(name(n))'s 5h window now with one tiny request (asks again before it fires)")
        }
    }

    /// Plain words, one clause per step, in time order: the switch/hold
    /// clause carries the trigger ("when main hits its MP limit ~4:00 PM")
    /// so the reader knows what the times refer to.
    private func summary(_ plan: WindowPlanner.Plan) -> String {
        let session = model.rowTheme.sessionLabel
        let activeName = model.accounts.first { $0.active }
            .map { name($0.number) } ?? "the active account"
        let bind = plan.bindAt <= Date().timeIntervalSince1970 + 30
            ? "now" : "~" + clock(plan.bindAt)
        let trigger = "\(activeName) hits its \(session) limit \(bind)"
        let clauses = plan.steps.sorted { $0.at < $1.at }.map { step -> String in
            switch step.action {
            case .ignite(let n): return "start \(name(n)) now"
            case .switchTo(let n): return "when \(trigger) switch to \(name(n))"
            case .hold(let n): return "stay on \(name(n)) when \(trigger)"
            case .reset(let n): return "\(name(n))'s \(session) resets \(clock(step.at))"
            }
        }
        return "Plan: " + clauses.joined(separator: " → ")
    }

    private func name(_ n: Int) -> String {
        model.accounts.first { $0.number == n }
            .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(n)"
    }

    private func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
