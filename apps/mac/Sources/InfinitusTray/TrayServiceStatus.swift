import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux
#endif
import InfinitusCore

/// Anthropic service status for the Quickshell footer chip (#9 parity)
/// — same source and wording as the mac's `ServiceStatusModel`, but the
/// tray is a fresh process per poll, so the 5-minute cache that model
/// keeps in memory lives in a sidecar file here instead (same shape as
/// `TrayHistory`'s state files). Waybar's frequent polling must not turn
/// into a fetch against status.anthropic.com on every tick.
enum TrayServiceStatus {
    private static let api = URL(string: "https://status.anthropic.com/api/v2/status.json")!
    private static let ttl: TimeInterval = 300

    static var cacheURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            ?? NSHomeDirectory() + "/.cache"
        return URL(fileURLWithPath: base).appendingPathComponent("infinitus/service-status.json")
    }

    private struct Cached: Codable {
        let indicator: String   // none | minor | major | critical | unknown
        let fetchedAt: Date
    }

    /// `indicator` is "none"/"minor"/"major"/"critical", or "unknown" when
    /// there's nothing fresh on disk and the live fetch failed or timed
    /// out (offline, degrades rather than stalling the caller).
    static func current(now: Date = Date()) async -> String {
        if let cached = readCache(), now.timeIntervalSince(cached.fetchedAt) < ttl {
            return cached.indicator
        }
        let indicator = await fetchLive() ?? "unknown"
        // Cache the failure too — offline, every waybar tick would
        // otherwise eat the full request timeout instead of a file read.
        writeCache(Cached(indicator: indicator, fetchedAt: now))
        return indicator
    }

    /// Same wording as `ServiceStatusSummary.shortText` / the mac's
    /// `ServiceStatusModel.shortText`; "unknown" is the tray's own
    /// offline word (the mac has no equivalent state — it just hasn't
    /// fetched yet, which reads as "status" there).
    static func word(for indicator: String) -> String {
        indicator == "unknown" ? "unknown" : ServiceStatusSummary(indicator: indicator).shortText
    }

    private static func readCache() -> Cached? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Cached.self, from: data)
    }

    private static func writeCache(_ cached: Cached) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(cached) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func fetchLive() async -> String? {
        struct Payload: Decodable {
            struct Status: Decodable { let indicator: String }
            let status: Status
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)
        guard let (data, _) = try? await session.data(for: URLRequest(url: api)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return payload.status.indicator
    }
}
