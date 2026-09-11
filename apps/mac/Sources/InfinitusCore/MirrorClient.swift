import Foundation

/// A phone that is talking to the mirror right now (user 2026-09-03:
/// "show active/connected devices"). Identified by the headers the app
/// sends on every request — a per-install id and the device's name —
/// and placed on a route by the Host header it used, so the Sync pane
/// can say "iPhone · Tailscale · 4 s ago" without the user opening the
/// phone. Older phone builds send no headers and show as "a phone".
public struct MirrorClient: Sendable, Equatable, Identifiable {
    public static let idHeader = "x-infinitus-device-id"
    public static let nameHeader = "x-infinitus-device"
    /// Silence longer than this and the row goes grey: the phone
    /// long-polls a session tail for 25 s and refreshes the fleet every
    /// half minute, so a live one is never quieter than that.
    public static let activeWindow: TimeInterval = 90

    public let id: String
    public let name: String
    public let route: String
    public var lastSeen: Date

    public init(id: String, name: String, route: String, lastSeen: Date) {
        self.id = id
        self.name = name
        self.route = route
        self.lastSeen = lastSeen
    }

    public init(request: MirrorTransport.Request, now: Date = Date()) {
        let id = request.headers[Self.idHeader].flatMap { $0.isEmpty ? nil : $0 } ?? "legacy"
        let name = request.headers[Self.nameHeader].flatMap { $0.isEmpty ? nil : $0 } ?? "a phone"
        let host = request.headers["host"]?.split(separator: ":").first.map(String.init) ?? ""
        self.init(id: id, name: String(name.prefix(40)), route: Self.route(host: host), lastSeen: now)
    }

    public func isActive(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) < Self.activeWindow
    }

    /// Which way in the request came, from the host the phone dialed.
    public static func route(host: String) -> String {
        let lower = host.lowercased()
        if lower.hasSuffix(".trycloudflare.com") { return "quick tunnel" }
        if MirrorPairing.tailnetAddress(in: [lower]) != nil { return "Tailscale" }
        if MirrorPairing.lanAddress(in: [lower]) != nil || lower == "infinitus" || lower.hasSuffix(".local") {
            return "Wi-Fi"
        }
        if lower.contains(".") { return lower }
        return "unknown route"
    }

    /// Newest first, one row per device, capped — the pane is a glance,
    /// not a log.
    public static func merge(_ client: MirrorClient, into list: [MirrorClient], cap: Int = 8) -> [MirrorClient] {
        var out = list.filter { $0.id != client.id }
        out.insert(client, at: 0)
        return Array(out.prefix(cap))
    }
}
