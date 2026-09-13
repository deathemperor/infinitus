import Foundation

public struct SubprocessError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A small blocking subprocess runner (moved out of the deleted
/// PtyHosts.swift, #1041 d5 — AWS/gcloud sign-in still shells out to
/// find and run the CLI).
public enum Subprocess {
    /// Blocking run; stdout on success, error on a non-zero exit or timeout.
    public static func run(_ binary: String, _ args: [String], timeout: TimeInterval = 15) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SubprocessError("\(URL(fileURLWithPath: binary).lastPathComponent) exited \(process.terminationStatus): \(msg)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// First existing executable among absolute candidates. A Finder- or
    /// login-item-launched app has no user PATH, so never search it.
    public static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
