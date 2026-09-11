import Foundation
import InfinitusCore

/// Phones talking to the tray's mirror right now (#9 parity with the
/// Mac's Sync-pane device list, `MirrorServer.clients`). `serve` is the
/// process that sees requests; `panel` is a one-shot exec — so the list
/// lives in a sidecar next to the snapshot, one line per device, newest
/// first, capped like the Mac's.
enum TrayClients {
    struct Entry: Codable {
        let id: String
        let name: String
        let route: String
        let lastSeen: Date
    }

    static var url: URL { TrayMirror.stateDir.appendingPathComponent("mirror-clients.json") }
    private static let lock = NSLock()

    static func note(_ request: MirrorTransport.Request, now: Date = Date()) {
        let client = MirrorClient(request: request, now: now)
        lock.lock(); defer { lock.unlock() }
        let merged = MirrorClient.merge(client, into: load().map {
            MirrorClient(id: $0.id, name: $0.name, route: $0.route, lastSeen: $0.lastSeen)
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entries = merged.map { Entry(id: $0.id, name: $0.name, route: $0.route, lastSeen: $0.lastSeen) }
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    /// The panel's chip rows: active (heard from inside the Mac's
    /// 90 s window) first.
    static func panelDevices(now: Date = Date()) -> [PanelDevice] {
        load().map { e in
            PanelDevice(name: e.name, route: e.route,
                        secondsAgo: max(0, Int(now.timeIntervalSince(e.lastSeen))),
                        active: now.timeIntervalSince(e.lastSeen) < MirrorClient.activeWindow)
        }
        .sorted { a, b in a.active != b.active ? a.active : a.secondsAgo < b.secondsAgo }
    }
}
