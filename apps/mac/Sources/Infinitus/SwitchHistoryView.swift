import SwiftUI
import AppKit
import InfinitusCore

/// Recent account switches via `swapd history --json` — the engine parses
/// its own log; this view never touches engine-internal files.
/// Slots resolve to the accounts' display names; times render as
/// "20:20" / "yesterday 17:21" / "Aug 28 06:44" (user 2026-08-30:
/// raw "3 → 5   2026-08-30 20:20" rows floating mid-pane).
struct SwitchHistoryView: View {
    let cli: SwapdCLI?
    var names: [Int: String] = [:]
    @State private var entries: [SwapdHistory.Switch] = []

    var body: some View {
        if entries.isEmpty {
            Text("No switches logged yet").foregroundStyle(.secondary)
                .onAppear(perform: load)
        } else {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, sw in
                HStack(spacing: 6) {
                    Text(sw.from.map { name($0.slot) } ?? "\u{2014}")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(name(sw.to.slot))
                    Spacer()
                    Text(when(sw.ts))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func name(_ number: Int) -> String {
        names[number] ?? "account \(number)"
    }

    /// "2026-08-30T20:20:15Z" from the engine, shown in local time.
    private static let parse = ISO8601DateFormatter()

    private func when(_ raw: String) -> String {
        guard let date = Self.parse.date(from: raw) else { return raw }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " \(time)"
    }

    private func load() {
        guard let cli else { return }
        Task {
            guard let list = try? await cli.history(provider: .claude) else { return }
            // The engine logs oldest first; the pane reads newest first.
            entries = list.switches.suffix(20).reversed()
        }
    }
}
