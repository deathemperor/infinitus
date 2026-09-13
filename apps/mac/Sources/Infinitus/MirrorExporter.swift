import Foundation
import InfinitusCore

/// Writes a `MirrorSnapshot` after every live refresh so the (future)
/// mobile companion has something to read (#9 phase 1). Off the main
/// actor, mirroring UsageHistoryRecorder's shape — this is all file IO.
actor MirrorExporter {
    private let minInterval: TimeInterval = 30
    private var lastWrite: Date = .distantPast
    /// The LAN server's payload slot (#9), when the phone companion is
    /// on — it serves the very bytes written here, never a re-encode.
    private var payload: MirrorPayloadBox?

    func attach(payload: MirrorPayloadBox) {
        self.payload = payload
    }

    // INFINITUS_MIRROR_SNAPSHOT: a debug/fixture instance's own file, so
    // it never overwrites the real app's mirror snapshot (#474).
    static let url: URL = {
        ProcessInfo.processInfo.environment["INFINITUS_MIRROR_SNAPSHOT"].map { URL(fileURLWithPath: $0) }
            ?? AppSupport.root().appendingPathComponent("mirror-snapshot.json")
    }()

    func record(listJSON: Data, prefs: FleetPrefs,
                serviceStatus: ServiceStatusSummary, engine: EngineBadge,
                fleets: [EngineFleet] = [], forecast: UsageForecast? = nil,
                plan: WindowPlanner.Plan? = nil, awsLogins: [AwsLogin.Item] = [],
                stats: Stats.Bundle? = nil,
                pushesAlerts: Bool = false, app: AppInfo? = nil,
                now: Bool = false) {
        // `now`: news the phone is waiting on (an AWS-login need that just
        // surfaced) skips the 30 s throttle.
        guard now || Date().timeIntervalSince(lastWrite) > minInterval else { return }
        lastWrite = Date()
        let now = Date()
        // Cash column (#9 phase D1a) was `cswap usage`'s cache; the field
        // stays on the wire, empty, until a native estimate (#756).
        let usageJSON: Data? = nil
        let snapshot = MirrorSnapshot(
            capturedAt: now,
            machineName: MachineName.current(),
            listJSON: listJSON,
            prefs: prefs,
            usageJSON: usageJSON,
            serviceStatus: serviceStatus,
            engine: engine,
            fleets: fleets.isEmpty ? nil : fleets,
            tokenRate: nil,
            forecast: forecast, plan: plan,
            awsLogins: awsLogins.isEmpty ? nil : awsLogins, stats: stats,
            pushesAlerts: pushesAlerts, app: app)
        // Encoded once here rather than inside MirrorWriter so the LAN
        // server hands out the same bytes the file holds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        payload?.set(data)
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
