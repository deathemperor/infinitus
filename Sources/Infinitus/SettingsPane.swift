import SwiftUI
import InfinitusCore

/// The cswap settings pane, rendered from the SettingSpec metadata that
/// `cswap config list --json` exports (spec §3.1). No per-key widgets: a new
/// SettingSpec in Python appears here with no Swift change.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var entries: [SettingEntry] = []
    @Published var drafts: [String: String] = [:]
    @Published var errors: [String: String] = [:]
    @Published var loadError: String?
    // True while load() repopulates drafts: that mutation fires the choice
    // pickers' .onChange, which without this guard auto-committed a
    // `cswap config set` for every choice key each time the pane opened
    // (observed as a spurious settings.json write on 2026-08-28).
    private(set) var loading = false

    let cli: CswapCLI?
    init(cli: CswapCLI?) { self.cli = cli }

    func load() async {
        guard let cli else { return }
        loading = true
        defer { loading = false }
        do {
            let cfg = try await cli.configList()
            entries = cfg.settings
            drafts = Dictionary(uniqueKeysWithValues: cfg.settings.map {
                ($0.key, $0.isSet ? $0.value.editableText : "")
            })
            loadError = nil
        } catch { loadError = "\(error)" }
    }

    func commit(_ entry: SettingEntry) {
        guard let cli, !loading else { return }
        let draft = drafts[entry.key] ?? ""
        switch SettingDraft.validate(draft, for: entry) {
        case .invalid(let why):
            errors[entry.key] = why
        case .valid(let value):
            errors[entry.key] = nil
            Task {
                do {
                    _ = try await cli.run(["config", "set", entry.key, value])
                    await load()
                } catch { errors[entry.key] = "\(error)" }
            }
        case .unset:
            errors[entry.key] = nil
            Task {
                do {
                    _ = try await cli.run(["config", "unset", entry.key])
                    await load()
                } catch { errors[entry.key] = "\(error)" }
            }
        }
    }
}

struct SettingsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form { SettingsFormBody(model: model) }
            .formStyle(.grouped)
            .task { await model.load() }
    }
}

/// The spec-driven cswap settings sections, embeddable in any Form —
/// SettingsPane wraps them alone; EnginesPane hosts them under the
/// Claude engine header (engines revamp, 2026-08-30).
struct SettingsFormBody: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            // One section per key prefix ("autoswitch.threshold" → Auto-switch),
            // in the order the CLI emits the keys.
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.entries, id: \.key) { entry in
                        row(entry)
                    }
                }
            }
            if let err = model.loadError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        // NO .task here: a modifier on a Group applies to its CHILDREN,
        // and before the first load the Group is EMPTY — the task never
        // fired and the settings never appeared ("cannot control any of
        // cswap config", 2026-08-30). Hosts own the load.
    }

    private struct PaneSection { let title: String; let entries: [SettingEntry] }

    private var sections: [PaneSection] {
        var order: [String] = []
        var grouped: [String: [SettingEntry]] = [:]
        for entry in model.entries {
            let prefix = String(entry.key.split(separator: ".").first ?? "")
            if grouped[prefix] == nil { order.append(prefix) }
            grouped[prefix, default: []].append(entry)
        }
        return order.map {
            PaneSection(title: Self.sectionTitle($0), entries: grouped[$0] ?? [])
        }
    }

    static func sectionTitle(_ prefix: String) -> String {
        SettingsFormLabels.sectionTitle(prefix)
    }

    /// "limitScanIntervalSeconds" → "Limit scan interval seconds". The raw
    /// key stays reachable as the control's tooltip.
    static func humanLabel(_ key: String) -> String {
        SettingsFormLabels.humanLabel(key)
    }

    @ViewBuilder private func row(_ entry: SettingEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch entry.kind {
            case "bool":
                Toggle(Self.humanLabel(entry.key), isOn: boolBinding(entry))
                    .help(entry.key)
            case "choice":
                Picker(Self.humanLabel(entry.key), selection: draftBinding(entry)) {
                    Text("(default)").tag("")
                    ForEach(entry.choices ?? [], id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model.drafts[entry.key]) { model.commit(entry) }
                .help(entry.key)
            default:
                HStack {
                    Text(Self.humanLabel(entry.key)).help(entry.key)
                    Spacer()
                    TextField(placeholder(entry), text: draftBinding(entry))
                        .frame(maxWidth: 140)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { model.commit(entry) }
                }
            }
            Text(entry.help).font(.caption).foregroundStyle(.secondary)
            if let err = model.errors[entry.key] {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func placeholder(_ entry: SettingEntry) -> String {
        var hint = "default: \(entry.defaultValue.editableText)"
        if let lo = entry.lo, let hi = entry.hi { hint += "  (\(Int(lo))–\(hi))" }
        return hint
    }

    private func draftBinding(_ entry: SettingEntry) -> Binding<String> {
        Binding(
            get: { model.drafts[entry.key] ?? "" },
            set: { model.drafts[entry.key] = $0 }
        )
    }

    private func boolBinding(_ entry: SettingEntry) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let b) = entry.value { return b }
                return false
            },
            set: { newValue in
                model.drafts[entry.key] = newValue ? "true" : "false"
                model.commit(entry)
            }
        )
    }
}

extension JSONValue {
    /// The text a user would type to reproduce this value.
    var editableText: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }
}
