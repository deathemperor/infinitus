import Foundation

/// A crash (or hang) of one of our own apps, as the phone reports it
/// from MetricKit or the Mac reads it from its own diagnostic reports —
/// no third party (user 2026-09-04: "crash tracking… privacy sensitive,
/// free… use built-in for now"). Stored under App Support, listed in
/// Settings › Sync, and sendable into a session's chat for triage.
public struct CrashReport: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    /// "ios" or "mac".
    public let platform: String
    public let device: String
    public let appVersion: String
    public let osVersion: String
    public let at: Date
    /// "crash" or "hang".
    public let kind: String
    /// One line: exception type / signal / termination reason.
    public let reason: String
    /// Top frames of the faulting thread, "binary +offset symbol".
    public var frames: [String]
    /// The raw diagnostic (MetricKit's call-stack tree JSON, or the
    /// Mac's .ips body), capped; nil once a store drops it.
    public var raw: String?

    public static let rawCap = 512 * 1024

    public init(id: String = UUID().uuidString, platform: String, device: String, appVersion: String,
                osVersion: String, at: Date, kind: String, reason: String, frames: [String] = [],
                raw: String? = nil) {
        self.id = id
        self.platform = platform
        self.device = device
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.at = at
        self.kind = kind
        self.reason = reason
        self.frames = frames
        self.raw = raw.map { String($0.prefix(Self.rawCap)) }
    }

    /// "iPhone · crash · EXC_BAD_ACCESS (SIGSEGV)".
    public var summary: String { "\(device) · \(kind) · \(reason)" }

    /// The text a session gets: what happened, then the frames, then the
    /// raw diagnostic for the parts the frames don't show.
    public var transcript: String {
        var out = "Infinitus \(platform == "ios" ? "phone app" : "Mac app") \(kind) on \(device)\n"
        out += "app \(appVersion) · \(osVersion) · \(ISO8601DateFormatter().string(from: at))\n"
        out += "reason: \(reason)\n"
        if !frames.isEmpty { out += "\nfaulting thread:\n" + frames.map { "  " + $0 }.joined(separator: "\n") + "\n" }
        if let raw { out += "\nraw diagnostic:\n" + raw + "\n" }
        return out
    }

    // MARK: MetricKit call-stack tree

    /// The attributed thread's frames out of `MXCallStackTree`'s JSON:
    /// first child at every level, "binary +offset".
    public static func frames(fromCallStackTree data: Data, limit: Int = 40) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks[0]
        var out: [String] = []
        var frame = (stack["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = frame, out.count < limit {
            let name = f["binaryName"] as? String ?? "?"
            let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue ?? 0
            out.append("\(name) +\(offset)")
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return out
    }

    // MARK: the Mac's own .ips reports

    /// A macOS diagnostic report (`~/Library/Logs/DiagnosticReports/
    /// Infinitus-*.ips`): a one-line JSON header, then the JSON body.
    public static func fromIPS(_ text: String, device: String = "Mac", limit: Int = 40) -> CrashReport? {
        guard let split = text.firstIndex(of: "\n") else { return nil }
        let body = String(text[text.index(after: split)...])
        guard let d = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        let exception = d["exception"] as? [String: Any]
        let termination = d["termination"] as? [String: Any]
        var reason = [exception?["type"] as? String, exception?["signal"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        if let why = termination?["indicator"] as? String, !why.isEmpty { reason += reason.isEmpty ? why : " — \(why)" }
        if reason.isEmpty { reason = "crash" }
        let images = d["usedImages"] as? [[String: Any]] ?? []
        let faulting = (d["faultingThread"] as? NSNumber)?.intValue ?? 0
        let threads = d["threads"] as? [[String: Any]] ?? []
        var frames: [String] = []
        if faulting < threads.count, let list = threads[faulting]["frames"] as? [[String: Any]] {
            for f in list.prefix(limit) {
                let idx = (f["imageIndex"] as? NSNumber)?.intValue ?? -1
                let image = idx >= 0 && idx < images.count ? images[idx]["name"] as? String ?? "?" : "?"
                let offset = (f["imageOffset"] as? NSNumber)?.intValue ?? 0
                let symbol = f["symbol"] as? String
                frames.append("\(image) +\(offset)" + (symbol.map { " \($0)" } ?? ""))
            }
        }
        let at = (d["captureTime"] as? String).flatMap(Self.parseCaptureTime) ?? Date()
        let version = (d["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "?"
        let os = (d["osVersion"] as? [String: Any])?["train"] as? String ?? "macOS"
        return CrashReport(platform: "mac", device: device, appVersion: version, osVersion: os, at: at,
                           kind: "crash", reason: reason, frames: frames, raw: body)
    }

    /// "2026-09-04 22:49:12.0000 +0700".
    static func parseCaptureTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return f.date(from: s)
    }
}

/// One JSON file per report under App Support/Infinitus/crashes, newest
/// first, the last `keep` kept.
public struct CrashStore: Sendable {
    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int = 50) {
        self.directory = directory
        self.keep = keep
    }

    /// `appSupport` is the app's own directory (`AppSupport.root()`).
    public static func defaultDirectory(appSupport: URL = AppSupport.root()) -> URL {
        appSupport.appendingPathComponent("crashes")
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public func save(_ report: CrashReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(report).write(to: directory.appendingPathComponent(report.id + ".json"),
                                              options: .atomic)
        for old in list().dropFirst(keep) { remove(old.id) }
    }

    public func list() -> [CrashReport] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name -> CrashReport? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
                return try? Self.decoder.decode(CrashReport.self, from: data)
            }
            .sorted { $0.at > $1.at }
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
    }
}
