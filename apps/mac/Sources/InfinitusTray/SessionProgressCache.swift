import Foundation
import InfinitusCore

/// Cheap-skip cache for `SessionProgress.read` across tray invocations
/// (issue #13 step 4). The tray is a fresh process every poll (Waybar
/// interval / Quickshell refresh) — there's no long-lived process to hold
/// SessionProgressModel's in-memory cache, so this is a sidecar file
/// instead, same idea as TrayHistory. Keyed by sessionId + the
/// transcript's size/mtime: an unmoved transcript is not re-parsed.
enum SessionProgressCache {
    struct Entry: Codable {
        let size: Int
        let mtime: Double
        let progress: SessionProgress
    }

    private static var url: URL {
        TrayHistory.dir.appendingPathComponent("session-progress-cache.json")
    }

    /// Current size/mtime of a session's transcript file; -1 when it
    /// can't be stat'd (never matches a cached stamp, so it's re-read).
    static func stamp(sessionId: String, cwd: String, claudeDir: URL) -> (size: Int, mtime: Double) {
        let path = Transcript.locate(cwd: cwd, sessionId: sessionId, claudeDir: claudeDir).path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return (size, mtime)
    }

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ cache: [String: Entry]) {
        try? FileManager.default.createDirectory(at: TrayHistory.dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url)
    }
}
