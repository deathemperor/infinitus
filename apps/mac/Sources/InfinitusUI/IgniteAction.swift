import SwiftUI
import InfinitusCore

/// The two-tap ignite: the first press arms, the second fires, and the
/// arm times out on its own so a stray click never starts a window
/// (#338). Every site that offers an ignition shares this state machine
/// and supplies its own label — the plan line's pill and a cold row's
/// chip look nothing alike, but must arm, time out and fire identically.
///
/// `label` and `tip` both receive the armed flag: the whole point of the
/// arm is that it is visible, so both change when it flips.
public struct IgniteAction<M: FleetModel, Label: View>: View {
    @ObservedObject var model: M
    let number: Int
    let tip: (Bool) -> String
    let label: (Bool) -> Label
    @State private var armed = false

    /// How long an armed button stays armed before disarming itself.
    static var armWindow: Duration { .seconds(6) }

    public init(model: M, number: Int,
                tip: @escaping (Bool) -> String,
                @ViewBuilder label: @escaping (Bool) -> Label) {
        self.model = model
        self.number = number
        self.tip = tip
        self.label = label
    }

    @ViewBuilder public var body: some View {
        if model.igniting == number {
            ProgressView().controlSize(.mini)
        } else {
            Button {
                if armed {
                    armed = false
                    model.ignite(number)
                } else {
                    armed = true
                    Task { @MainActor in
                        try? await Task.sleep(for: Self.armWindow)
                        armed = false
                    }
                }
            } label: {
                label(armed)
            }
            .buttonStyle(.plain)
            .instantTip(tip(armed))
        }
    }
}
