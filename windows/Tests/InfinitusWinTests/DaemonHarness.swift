import XCTest
import Foundation
#if os(Windows)
import WinSDK
#endif

/// Plumbing the W3/W5 tests share. Nothing here imports InfinitusWin —
/// linking the executable's module kills the test host (W2), so the
/// daemon is exercised as a subprocess and everything pure comes from
/// InfinitusCore.
enum DaemonHarness {
    /// This package's test fixtures (synthetic sessions, a damaged token).
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// The built daemon: `INFINITUS_WIN_EXE` wins, then a search upward
    /// from the test host for `.build/debug/infinitus-win.exe` (or the
    /// target-shaped `InfinitusWin.exe` `swift test` leaves behind).
    static func executable() -> URL? {
        if let override = ProcessInfo.processInfo.environment["INFINITUS_WIN_EXE"],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
        for _ in 0..<5 {
            for name in ["infinitus-win.exe", "InfinitusWin.exe"] {
                let candidate = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Runs one subcommand and returns its streams split on any newline —
    /// autocrlf is on here, so output may carry CRLF.
    static func run(_ arguments: [String],
                    environment: [String: String] = [:]) throws
        -> (output: [String], error: [String], status: Int32) {
        guard let executable = executable() else {
            throw XCTSkip("infinitus-win.exe not built — run `swift build --product infinitus-win` first")
        }
        let output = tempFile("out")
        let error = tempFile("err")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: error)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        try process.run()
        process.waitUntilExit()
        let read = { (url: URL) -> [String] in
            (try? String(contentsOf: url, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).map(String.init) ?? []
        }
        return (read(output), read(error), process.terminationStatus)
    }

    /// An empty scratch file the child's streams can be redirected into.
    static func tempFile(_ suffix: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("infinitus-win-\(suffix)-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// A fresh scratch directory, removed when the block returns.
    static func scratch(_ block: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("infinitus-win-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try block(dir)
    }
}

/// This test process's pid and its creation FILETIME — the live pid a
/// synthetic session record can point at so the daemon's liveness path
/// (OpenProcess + GetProcessTimes) has something real to walk.
enum SelfProcess {
    static var pid: Int32 {
        #if os(Windows)
        return Int32(GetCurrentProcessId())
        #else
        return Int32(ProcessInfo.processInfo.processIdentifier)
        #endif
    }

    /// The record's `procStart`: a decimal FILETIME string.
    static var procStart: String? {
        #if os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION),
                                       false, DWORD(UInt32(bitPattern: pid))) else { return nil }
        defer { CloseHandle(handle) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(handle, &created, &exited, &kernel, &user) else { return nil }
        return String((UInt64(created.dwHighDateTime) << 32) | UInt64(created.dwLowDateTime))
        #else
        return nil
        #endif
    }
}
