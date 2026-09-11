import AppIntents

/// The Mac a per-Mac fleet widget shows (#144), picked in the widget's
/// editor from the Macs the app last handed over (WidgetBridge); the
/// widget target can't see the app's pairings, so the bridge is its
/// list. Blank means the primary Mac.
struct PickMacIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Mac"
    static let description = IntentDescription("Which paired Mac the widget shows.")

    @Parameter(title: "Mac")
    var mac: WidgetMac?
}

struct WidgetMac: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mac"
    static let defaultQuery = WidgetMacQuery()

    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static func all() -> [WidgetMac] {
        WidgetBridge.load().map { WidgetMac(id: $0.id, name: $0.machine) }
    }
}

struct WidgetMacQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetMac] {
        WidgetMac.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetMac] { WidgetMac.all() }

    func defaultResult() async -> WidgetMac? {
        WidgetMac.all().first { $0.id == WidgetBridge.primary }
    }
}
