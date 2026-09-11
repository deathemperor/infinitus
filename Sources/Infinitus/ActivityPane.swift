import SwiftUI
import InfinitusCore

/// Switch history + the live engine event log — moved here from the popup
/// footer so the popup stays about the accounts.
struct ActivityPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                SwitchHistoryView(cli: model.swapd, names: accountNames)
            } header: {
                Text("Switch history")
            } footer: {
                Text("Every account change Infinitus made, newest first.")
            }
            .settingsAnchor("Activity/Switch history")
            Section {
                if model.eventLog.isEmpty {
                    Text("No events yet this session").foregroundStyle(.secondary)
                } else {
                    ForEach(model.eventLog.suffix(30).reversed()) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.icon)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(entry.text)
                            Spacer()
                            Text(entry.at, format: .dateTime.hour().minute())
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text("Engine events")
            } footer: {
                Text("The last thirty events since this launch; the list "
                     + "starts fresh each time Infinitus opens.")
            }
            .settingsAnchor("Activity/Engine events")
        }
        .formStyle(.grouped)
    }

    /// Alias (or the email's local part) per account number.
    private var accountNames: [Int: String] {
        Dictionary(uniqueKeysWithValues: model.accounts.map { a in
            (a.number, a.alias ?? String(a.email.split(separator: "@").first ?? "?"))
        })
    }
}

extension ActivityPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "Activity", section: "Switch history", label: "Switch history",
                            keywords: ["switches", "history", "log"], anchor: "Activity/Switch history"),
        SettingsSearchEntry(pane: "Activity", section: "Engine events", label: "Engine events",
                            keywords: ["events", "log", "engine"], anchor: "Activity/Engine events"),
    ]
}
