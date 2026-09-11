import SwiftUI
import InfinitusCore

/// Every enabled engine's fleet, stacked (#8 multi-engine). With one
/// fleet nothing is added around the rows, so a single-engine popup is
/// pixel-identical to the pre-#8 one; two or more get a slim header
/// each naming the provider and engine.
public struct FleetStack<F: FleetModel & UsageSource & Identifiable>: View {
    let fleets: [F]
    /// Max reported width per column key across every fleet's grid —
    /// see ColumnAlignment.swift.
    @State private var columnWidths: [String: CGFloat] = [:]

    public init(fleets: [F]) { self.fleets = fleets }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fleets) { fleet in
                if fleets.count > 1, let label = fleet.fleetLabel {
                    FleetHeader(label: label)
                }
                FleetSection(model: fleet, lone: fleets.count == 1)
            }
        }
        .environment(\.sharedColumnWidths, fleets.count > 1 ? columnWidths : [:])
        .onPreferenceChange(ColumnWidths.self) { reported in
            guard fleets.count > 1 else { return }
            var next = columnWidths
            next.merge(reported, uniquingKeysWith: max)
            if next != columnWidths { columnWidths = next }
        }
        .onChange(of: fleets.count) { _, _ in columnWidths = [:] }
    }
}

/// One fleet's rows — or, for the only fleet with the only account, the
/// solo card (SoloCard.swift). Its own view so the account count is
/// OBSERVED: FleetStack holds the models as plain values and would
/// never re-decide when the first snapshot lands.
private struct FleetSection<F: FleetModel & UsageSource>: View {
    @ObservedObject var model: F
    let lone: Bool

    var body: some View {
        if lone, model.accounts.count == 1, !model.compactRows,
           let only = model.accounts.first {
            SoloCard(model: model, usage: model, account: only)
            SecondAccountNudge(model: model)
        } else {
            AccountRows(model: model, usage: model)
        }
    }
}

struct FleetHeader: View {
    let label: FleetLabel

    var body: some View {
        HStack(spacing: 6) {
            Text(label.provider.displayName)
                .fontWeight(.semibold)
            Text("·").foregroundStyle(.tertiary)
            Text(label.engineName)
                .foregroundStyle(.secondary)
            if let caveat = label.caveat {
                Text("— " + caveat)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(PopupFont.caption)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}
