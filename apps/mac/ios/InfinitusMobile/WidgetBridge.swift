import Foundation
import InfinitusCore
import WidgetKit
import os

/// What the home-screen and lock-screen widgets draw (#80): the same
/// themed states the Live Activities use, handed over through the shared
/// keychain item (no App Group, see SharedKeychain). The app writes it
/// on every poll that changed something and reloads the timelines; the
/// widget's provider reads it. One payload per paired Mac (#144), the
/// primary's first.
enum WidgetBridge {
    struct Payload: Codable, Equatable {
        /// The Mac's pairing id, `WidgetBridge.primary` for the primary.
        var id: String
        var working: WorkingActivityState?
        var revival: RevivalActivityState?
        var machine: String
        var capturedAt: Date
    }

    static let primary = "primary"
    static let service = "run.infinitus.widget"
    static let account = "fleet"
    private static let log = Logger(subsystem: "run.infinitus.mobile", category: "widgets")
    private static var lastWritten: [Payload]?

    @MainActor
    static func publish(_ payloads: [Payload]) {
        guard payloads != lastWritten else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payloads) else { return }
        let status = SharedKeychain.write(service: service, account: account, data: data)
        guard status == errSecSuccess else {
            if lastWritten == nil { log.error("widget bridge write failed: \(status)") }
            return
        }
        lastWritten = payloads
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> [Payload] {
        guard let data = SharedKeychain.read(service: service, account: account) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([Payload].self, from: data) { return list }
        // The single-Mac item from before #144, until the app's next poll
        // rewrites it — no blank widget across the update.
        return (try? decoder.decode(Payload.self, from: data)).map { [$0] } ?? []
    }

    /// The primary Mac's payload — what the original Fleet widget draws.
    static func primaryPayload(in payloads: [Payload]) -> Payload? {
        payloads.first { $0.id == primary } ?? payloads.first
    }
}

extension WidgetBridge.Payload {
    // Declared in an extension so the memberwise init survives: the
    // pre-#144 item has no `id` and is the primary's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? WidgetBridge.primary
        working = try c.decodeIfPresent(WorkingActivityState.self, forKey: .working)
        revival = try c.decodeIfPresent(RevivalActivityState.self, forKey: .revival)
        machine = try c.decode(String.self, forKey: .machine)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
    }
}
