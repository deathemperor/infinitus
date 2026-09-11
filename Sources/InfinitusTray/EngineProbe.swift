import Foundation

/// The Linux tray has no engine supervisor of its own (#9 phase D2) — no
/// daemon to start or stop, just this detection, matching the mac's
/// engine badge word for the two states that translate: is an
/// auto-switch engine (`swapd auto`) alive on this host right now?
enum EngineProbe {
    private static var pgrepPath: String? {
        let candidates = ["/usr/bin/pgrep", "/bin/pgrep", "/usr/local/bin/pgrep"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { "\($0)/pgrep" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isRunning() -> Bool {
        guard let pgrep = pgrepPath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pgrep)
        process.arguments = ["-f", "swapd auto"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
