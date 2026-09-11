import XCTest
import Foundation
@testable import InfinitusCore

/// `tools/demo-swapd` is mock mode's engine once cswap goes (#756): its
/// `list --json` must decode through the real swapd mapping, or mock
/// mode shows an empty popup with no error to point at the script.
final class DemoSwapdTests: XCTestCase {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/demo-swapd").path

    /// The CI Linux image ships no python3; the script's contract is
    /// checked wherever one exists (every Mac, the e2e runner).
    static let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func run(_ args: [String], state: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(Self.python))
        process.arguments = [Self.script] + args
        var env = ProcessInfo.processInfo.environment
        env["INFINITUS_DEMO_STATE"] = state
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, args.joined(separator: " "))
        return data
    }

    func testTheDemoFleetDecodesThroughTheSwapdMapping() throws {
        try XCTSkipIf(Self.python == nil, "no python3 on this runner")
        let state = NSTemporaryDirectory() + "demo-swapd-test-\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: state) }
        let list = try JSONDecoder().decode(SwapdList.self, from: try run(["list", "--json"], state: state))
        let fleets = SwapdMapping.fleets(from: list)
        XCTAssertEqual(fleets.count, 1)
        let fleet = try XCTUnwrap(fleets.first)
        XCTAssertGreaterThanOrEqual(fleet.accounts.count, 8, "one account per demo condition")
        XCTAssertEqual(fleet.activeNumber, 1)
        XCTAssertTrue(fleet.accounts.contains { $0.disabled == true }, "the disabled condition")
        XCTAssertTrue(fleet.accounts.contains { $0.usage?.fiveHour != nil && $0.usage?.sevenDay != nil }, "windows decode")

        _ = try run(["switch", "--provider", "claude", "--slot", "3", "--json"], state: state)
        let after = try JSONDecoder().decode(SwapdList.self, from: try run(["list", "--json"], state: state))
        XCTAssertEqual(SwapdMapping.fleets(from: after).first?.activeNumber, 3, "switch persists in the state file")
    }
}
