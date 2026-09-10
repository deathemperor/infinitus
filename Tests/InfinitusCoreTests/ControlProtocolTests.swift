import XCTest
@testable import InfinitusCore

final class ControlProtocolTests: XCTestCase {
    func testRequestRoundTripsAsOneLine() throws {
        let req = ControlRequest(command: "rename", args: ["cswap/claude", "2", "work"],
                                 options: ["yes": "true"], secret: "s3")
        let line = try ControlCodec.encode(req)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "exactly one newline, the terminator")
        XCTAssertEqual(try ControlCodec.decode(ControlRequest.self, from: line), req)
    }

    func testReplyCarriesSchemaVersionAndResult() throws {
        let reply = ControlReply(ok: true, result: .object(["restarting": .bool(true)]), restarting: true)
        let back = try ControlCodec.decode(ControlReply.self, from: try ControlCodec.encode(reply))
        XCTAssertEqual(back.schemaVersion, ControlProtocol.schemaVersion)
        XCTAssertTrue(back.ok)
        XCTAssertTrue(back.restarting)
        XCTAssertEqual(back.result?["restarting"], .bool(true))
        XCTAssertNil(back.error)
    }

    func testNullResultIsAValueNotAnAbsence() throws {
        let v = ControlProtocol.schemaVersion
        let null = try ControlCodec.decode(ControlReply.self, from: Data("{\"schemaVersion\":\(v),\"ok\":true,\"result\":null}\n".utf8))
        XCTAssertEqual(null.result, .null, "team-status with no team answers null; the CLI prints it")
        let absent = try ControlCodec.decode(ControlReply.self, from: Data("{\"schemaVersion\":\(v),\"ok\":true}\n".utf8))
        XCTAssertNil(absent.result)
        let back = try ControlCodec.decode(ControlReply.self, from: try ControlCodec.encode(ControlReply(ok: true, result: .null)))
        XCTAssertEqual(back.result, .null)
    }

    func testJSONValueOfReencodesCodableWithDates() throws {
        struct S: Encodable { let n: Int; let at: Date; let list: [String]; let none: String? }
        let v = try JSONValue.of(S(n: 3, at: Date(timeIntervalSince1970: 0), list: ["a"], none: nil))
        XCTAssertEqual(v["n"], .number(3))
        XCTAssertEqual(v["at"], .string("1970-01-01T00:00:00Z"))
        XCTAssertEqual(v["list"], .array([.string("a")]))
        XCTAssertNil(v["none"], "nil fields are omitted, not null")
    }

    func testManifestNamesAreUniqueAndLookupWorks() {
        let names = ControlCommand.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(ControlCommand.named("remove")?.effect, .destructive)
        XCTAssertEqual(ControlCommand.named("remove")?.options, ["--yes"])
        XCTAssertEqual(ControlCommand.named("engine")?.effect, .restart)
        XCTAssertEqual(ControlCommand.named("rotate")?.requires, "rotate")
        XCTAssertEqual(ControlCommand.named("reorder")?.args, ["<fleet>", "<n>..."])
        XCTAssertEqual(ControlCommand.named("randomize-names")?.args, ["<fleet>", "[n]"])
        XCTAssertEqual(ControlCommand.named("past-sessions")?.options, ["--limit <n, default 50>", "--search <text>"])
        XCTAssertEqual(ControlCommand.named("resume-session")?.args, ["<sessionId>"])
        XCTAssertEqual(ControlCommand.named("profile-set")?.args, ["<name>"])
        XCTAssertEqual(ControlCommand.named("profile-remove")?.effect, .write)
        XCTAssertEqual(ControlCommand.named("checkpoint-restore")?.effect, .destructive)
        XCTAssertEqual(ControlCommand.named("checkpoint-diff")?.args, ["<pid|name>", "<n>", "[m]"])
        XCTAssertEqual(ControlCommand.named("prefer")?.requires, "prefer")
        XCTAssertEqual(ControlCommand.named("lock-status")?.effect, .read)
        XCTAssertEqual(ControlCommand.named("lock-status")?.args, [])
        XCTAssertEqual(ControlCommand.named("team-status")?.effect, .read)
        XCTAssertEqual(ControlCommand.named("team-create")?.args, ["<name>"])
        XCTAssertEqual(ControlCommand.named("team-create")?.effect, .write)
        XCTAssertEqual(ControlCommand.named("session-mode")?.effect, .write)
        XCTAssertEqual(ControlCommand.named("resume-session")?.options, ["--fork"])
        XCTAssertEqual(ControlCommand.named("team-approve")?.args, ["<kid>"])
        XCTAssertEqual(ControlCommand.named("team-publish")?.effect, .write)
        XCTAssertEqual(ControlCommand.named("team-code")?.effect, .write, "fetches the store and (--invite) writes the nonce book")
        XCTAssertEqual(ControlCommand.named("show")?.args, ["popout|settings|wall|workspace [sidebar|thread|composer|draft|switcher]"])
        XCTAssertEqual(ControlCommand.named("hide")?.args, ["popout|settings|workspace"])
        XCTAssertNotNil(ControlCommand.named("team-code")); XCTAssertNotNil(ControlCommand.named("team-fetch")); XCTAssertNotNil(ControlCommand.named("team-decline"))
        XCTAssertNil(ControlCommand.named("nope"))
    }

    func testManifestEncodesForAgents() throws {
        let data = try ControlCodec.encode(ControlCommand.all)
        let back = try ControlCodec.decode([ControlCommand].self, from: data)
        XCTAssertEqual(back, ControlCommand.all)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"effect\":\"human\""), "add is flagged as needing a human")
    }

    func testSocketPathFollowsThisPlatformsRule() {
        #if os(Linux)
        XCTAssertEqual(ControlProtocol.socketURL(home: "/home/x",
                                                 environment: ["XDG_RUNTIME_DIR": "/run/user/1000"]).path,
                       "/run/user/1000/infinitus/control.sock")
        XCTAssertEqual(ControlProtocol.socketURL(home: "/home/x", environment: [:]).path,
                       "/home/x/.local/state/infinitus/control.sock")
        #else
        XCTAssertEqual(ControlProtocol.socketURL(home: "/Users/x", environment: [:]).path,
                       "/Users/x/Library/Application Support/Infinitus/control/control.sock")
        #endif
        // The override comes first on every platform — a dev instance and
        // its infinitusctl meet there instead of the real app's socket.
        XCTAssertEqual(ControlProtocol.socketURL(home: "/Users/x",
                                                 environment: ["INFINITUS_CONTROL_SOCKET": "/tmp/dev.sock",
                                                               "XDG_RUNTIME_DIR": "/run/user/1000"]).path,
                       "/tmp/dev.sock")
    }

    /// Both platforms' rules, checked from either one (#486 slice 3): the
    /// Linux tray's socket lives in the runtime dir, with the state dir as
    /// the stand-in when there is none — an empty variable counts as none.
    func testBothPlatformsSocketRules() {
        XCTAssertEqual(ControlProtocol.macSocketPath(home: "/Users/x"),
                       "/Users/x/Library/Application Support/Infinitus/control/control.sock")
        XCTAssertEqual(ControlProtocol.linuxSocketPath(home: "/home/x",
                                                       environment: ["XDG_RUNTIME_DIR": "/run/user/1000"]),
                       "/run/user/1000/infinitus/control.sock")
        XCTAssertEqual(ControlProtocol.linuxSocketPath(home: "/home/x", environment: [:]),
                       "/home/x/.local/state/infinitus/control.sock")
        XCTAssertEqual(ControlProtocol.linuxSocketPath(home: "/home/x", environment: ["XDG_RUNTIME_DIR": ""]),
                       "/home/x/.local/state/infinitus/control.sock")
    }
}
