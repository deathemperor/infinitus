import XCTest
@testable import InfinitusCore

/// The `policy` verbs' engine touchpoints: one `swapd config … --json` each,
/// the key named `<provider>.<key>` for the engine, its reply handed on whole.
final class SwapdPolicyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swapd-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A stub `config`: records its argv and answers one setting the way
    /// `config list|set|unset --json` do; any other verb is a refusal.
    private func makeCLI() throws -> SwapdCLI {
        let argv = dir.appendingPathComponent("argv").path
        let script = """
        #!/bin/sh
        echo "$@" >> "\(argv)"
        case "$1" in
          config) echo '{"schemaVersion":1,"settings":[{"key":"claude.strategy","value":"consume-first","isSet":true,"default":"best","help":"How the auto loop picks the target account"}]}' ;;
          *) echo '{"schemaVersion":1,"error":{"code":"invalid-input","message":"unrecognized subcommand"}}'; exit 1 ;;
        esac
        """
        let binary = dir.appendingPathComponent("swapd")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return SwapdCLI(binaryPath: binary.path)
    }

    private func argv() throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testReadListsTheProvidersKnobsUntouched() async throws {
        let cli = try makeCLI()
        let data = try await cli.policyData(provider: .claude)
        XCTAssertEqual(try argv(), ["config list --json --provider claude"])
        let reply = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let settings)? = reply["settings"], let first = settings.first else {
            return XCTFail("expected the engine's settings array, got \(String(describing: reply["settings"]))")
        }
        XCTAssertEqual(first["key"], .string("claude.strategy"))
        XCTAssertEqual(first["isSet"], .bool(true))
    }

    func testSetAndUnsetNameTheKeyForTheEngine() async throws {
        let cli = try makeCLI()
        _ = try await cli.setPolicy(provider: .claude, key: "strategy", value: "consume-first")
        _ = try await cli.unsetPolicy(provider: .claude, key: "threshold")
        XCTAssertEqual(try argv(), [
            "config set claude.strategy consume-first --json",
            "config unset claude.threshold --json",
        ])
    }

    func testAnUnknownProviderIsRefusedBeforeTheEngineRuns() async throws {
        let cli = try makeCLI()
        do {
            _ = try await cli.setPolicy(provider: .other, key: "strategy", value: "best")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("argv").path))
        }
    }
}
