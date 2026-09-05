import Foundation
import InfinitusCore

public enum WinEventStore {
    public static let retention: TimeInterval = 400 * 86_400

    public static var url: URL {
        WinSettingsStore.infinitusHome.appendingPathComponent("events.jsonl")
    }

    private static let lock = NSLock()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func append(_ event: StatsEvent, to fileURL: URL = url) {
        lock.lock()
        defer { lock.unlock() }
        guard var data = try? encoder.encode(event) else { return }
        data.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public static func load(from fileURL: URL = url) -> [StatsEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(StatsEvent.self, from: line)
        }
    }

    public static func prune(now: Date = Date(), fileURL: URL = url) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let kept = data.split(separator: UInt8(ascii: "\n")).compactMap { line -> StatsEvent? in
            guard let event = try? decoder.decode(StatsEvent.self, from: line) else { return nil }
            return now.timeIntervalSince(event.at) < retention ? event : nil
        }
        var out = Data()
        for e in kept {
            if let d = try? encoder.encode(e) {
                out.append(d)
                out.append(UInt8(ascii: "\n"))
            }
        }
        try? out.write(to: fileURL, options: .atomic)
    }
}
