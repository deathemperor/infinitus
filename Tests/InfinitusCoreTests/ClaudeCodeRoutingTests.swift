import XCTest
@testable import InfinitusCore

/// `ClaudeCodeRouting` — whether Claude Code's settings.json points its
/// API at the 9Router endpoint. A false negative leaves the app
/// pretending cswap is under Claude Code when it isn't; a false
/// positive hands the facade to an idle engine — both are wrong, so
/// the match rules are pinned here.
final class ClaudeCodeRoutingTests: XCTestCase {
    private func writeSettings(_ env: [String: Any]? = ["ANTHROPIC_BASE_URL": "http://127.0.0.1:20128"],
                               in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        var root: [String: Any] = [:]
        if let env { root["env"] = env }
        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: url)
        return url.deletingLastPathComponent()
    }

    func testReadsBaseURLOutOfEnv() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccr-\(UUID().uuidString)")
        let home = try writeSettings(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(ClaudeCodeRouting.anthropicBaseURL(configHome: home)?.absoluteString,
                       "http://127.0.0.1:20128")
    }

    func testMissingFileMissingEnvOrMissingKeyAllReadUnset() throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccr-\(UUID().uuidString)")
        XCTAssertNil(ClaudeCodeRouting.anthropicBaseURL(configHome: absent))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(ClaudeCodeRouting.anthropicBaseURL(configHome: dir))

        try writeSettings(["OTHER_KEY": "x"], in: dir)
        XCTAssertNil(ClaudeCodeRouting.anthropicBaseURL(configHome: dir))
    }

    func testOriginDropsGatewayPathAndKeepsPort() {
        XCTAssertEqual(
            ClaudeCodeRouting.origin(of: URL(string: "http://192.168.2.12:20128/v1")),
            URL(string: "http://192.168.2.12:20128"))
        XCTAssertEqual(
            ClaudeCodeRouting.origin(of: URL(string: "http://127.0.0.1:20128")),
            URL(string: "http://127.0.0.1:20128"))
        // No explicit port — no origin to adopt.
        XCTAssertNil(ClaudeCodeRouting.origin(of: URL(string: "http://router.example.com")))
        XCTAssertNil(ClaudeCodeRouting.origin(of: nil))
    }

    func testMatchRules() {
        let router = URL(string: "http://127.0.0.1:20128")!
        XCTAssertTrue(ClaudeCodeRouting.isRouted(URL(string: "http://127.0.0.1:20128"), to: router))
        // localhost names the same loopback endpoint.
        XCTAssertTrue(ClaudeCodeRouting.isRouted(URL(string: "http://localhost:20128"), to: router))
        XCTAssertTrue(ClaudeCodeRouting.isRouted(URL(string: "http://127.0.0.1:20128/"), to: router))
        // A different port or scheme is somebody else's endpoint.
        XCTAssertFalse(ClaudeCodeRouting.isRouted(URL(string: "http://127.0.0.1:8080"), to: router))
        XCTAssertFalse(ClaudeCodeRouting.isRouted(URL(string: "https://127.0.0.1:20128"), to: router))
        XCTAssertNil(ClaudeCodeRouting.anthropicBaseURL(configHome: URL(fileURLWithPath: "/nonexistent")))
        XCTAssertFalse(ClaudeCodeRouting.isRouted(nil, to: router))
        // The port signature needs no configured base URL at all, and
        // holds across the LAN — this Mac's own settings point at
        // 192.168.2.12:20128/v1. Gateway path suffixes don't matter.
        XCTAssertTrue(ClaudeCodeRouting.isRouted(router, to: nil))
        XCTAssertFalse(ClaudeCodeRouting.isRouted(URL(string: "http://127.0.0.1:8080"), to: nil))
        XCTAssertTrue(ClaudeCodeRouting.isRouted(URL(string: "http://192.168.2.12:20128/v1"), to: nil))
        XCTAssertTrue(ClaudeCodeRouting.isRouted(URL(string: "http://10.0.0.5:20128"), to: nil))
    }
}
