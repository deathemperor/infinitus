import Foundation
import InfinitusCore

/// The app's event log on disk — one JSON line per event, appended as
/// they happen, so Stats can count switches and limits over months
/// (the in-memory `eventLog` keeps only the last 100). Off the main
/// actor: file IO.
actor EventStore {
    static let retention: TimeInterval = 400 * 86_400
    static let url: URL = AppSupport.root().appendingPathComponent("events.jsonl")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func append(_ event: StatsEvent) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(UInt8(ascii: "\n"))
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func load() -> [StatsEvent] {
        guard let data = try? Data(contentsOf: Self.url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(StatsEvent.self, from: $0) }
    }

    /// Rewrites the file without events older than `retention`.
    func prune(now: Date = Date()) {
        let kept = load().filter { now.timeIntervalSince($0.at) < Self.retention }
        var out = Data()
        for e in kept {
            if let d = try? encoder.encode(e) { out.append(d); out.append(UInt8(ascii: "\n")) }
        }
        try? out.write(to: Self.url, options: .atomic)
    }
}
