import SwiftUI
import InfinitusCore

/// Instant hover card for the service-status chip: per-product rows,
/// statuspage-style (user screenshot 2026-08-30). Click still opens the
/// status page.
struct StatusHoverCard: ViewModifier {
    @ObservedObject var status: ServiceStatusModel
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .overlay(alignment: .bottomLeading) {
                if hovering, !status.components.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(status.components, id: \.0) { name, state in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(state == "operational" ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                Text(name).font(.caption)
                                Spacer(minLength: 12)
                                Text(state.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Text("Click to open the status page")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(width: 240)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.regularMaterial)
                            .shadow(radius: 4, y: 2))
                    .offset(y: -18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .zIndex(hovering ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
