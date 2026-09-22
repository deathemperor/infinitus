import XCTest
@testable import InfinitusCore

#if os(macOS)
final class SwapdLaunchAgentTests: XCTestCase {
    private actor Launchd {
        var loaded = false
        var commands: [[String]] = []
        func run(_ args: [String]) throws -> Data {
            commands.append(args)
            switch args.first {
            case "print":
                guard loaded else { throw CLIError(message: "not loaded") }
                return Data("state = running\n pid = 42\n".utf8)
            case "bootstrap": loaded = true
            case "bootout": loaded = false
            default: break
            }
            return Data()
        }
    }

    private func fixture() throws -> (URL, URL, SwapdLaunchAgent.Location) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("bundled-swapd")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        return (home, source, .init(home: home, label: "run.infinitus.swapd.test"))
    }

    // Opt-in host integration: a separate process installs a uniquely named
    // job with a fake engine and exits. No real account state is opened.
    func testLaunchdOutlivesItsInstallingProcess() async throws {
        guard ProcessInfo.processInfo.environment["INFINITUS_TEST_LAUNCHD"] == "1" else {
            throw XCTSkip("requires a macOS GUI launchd session")
        }
        let (home, source, _) = try fixture()
        let label = "run.infinitus.swapd.test." + UUID().uuidString.lowercased()
        let location = SwapdLaunchAgent.Location(home: home, label: label)
        try Data("#!/bin/sh\nexec /bin/sleep 300\n".utf8).write(to: source)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest",
                           "InfinitusCoreTests.SwapdLaunchAgentTests/testInstallFromSeparateProcess",
                           Bundle(for: Self.self).bundleURL.path]
        var env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        env["INFINITUS_TEST_SERVICE_HOME"] = home.path
        env["INFINITUS_TEST_SERVICE_LABEL"] = label
        child.environment = env
        try child.run()
        child.waitUntilExit()
        let client = SwapdLaunchAgent(binaryPath: source.path, location: location,
                                     onLine: { _ in }, onState: { _ in })
        do {
            XCTAssertEqual(child.terminationStatus, 0)
            let before = try await SwapdCLI(binaryPath: "/bin/launchctl").run(["print", location.service])
            XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("pid ="),
                          "launchd must retain the daemon after its installing process exits")
            await client.start()
            let after = try await SwapdCLI(binaryPath: "/bin/launchctl").run(["print", location.service])
            let pidLine: (Data) -> Substring? = { data in
                String(decoding: data, as: UTF8.self).split(separator: "\n").first { $0.contains("pid =") }
            }
            XCTAssertEqual(pidLine(before), pidLine(after), "reopening must retain the same process")
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.plist.path))
    }

    func testInstallFromSeparateProcess() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["INFINITUS_TEST_SERVICE_HOME"],
              let label = env["INFINITUS_TEST_SERVICE_LABEL"] else { return }
        let location = SwapdLaunchAgent.Location(home: URL(fileURLWithPath: home), label: label)
        let service = SwapdLaunchAgent(binaryPath: home + "/bundled-swapd", location: location,
                                      onLine: { _ in }, onState: { _ in })
        await service.start()
        // Intentionally do not stop or disconnect: process exit is the test.
    }

    func testDisconnectLeavesServiceRunningAndReopeningDoesNotRestartIt() async throws {
        let (_, source, location) = try fixture()
        let launchd = Launchd()
        let first = SwapdLaunchAgent(binaryPath: source.path, location: location,
                                    run: { try await launchd.run($0) }, onLine: { _ in }, onState: { _ in })
        await first.start()
        await first.disconnect()
        let stillRunning = await launchd.loaded
        XCTAssertTrue(stillRunning, "quitting the UI must leave account switching alive")

        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: location.plist), format: nil) as? [String: Any])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [location.binary.path, "auto", "--json"])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?["SWAPD_SUPERVISED"], "0")

        let reopened = SwapdLaunchAgent(binaryPath: source.path, location: location,
                                       run: { try await launchd.run($0) }, onLine: { _ in }, onState: { _ in })
        await reopened.start()
        let commands = await launchd.commands
        XCTAssertEqual(commands.filter { $0.first == "bootstrap" }.count, 1)
        XCTAssertFalse(commands.contains { $0.first == "bootout" })
        await reopened.stop()
        let stopped = await launchd.loaded
        XCTAssertFalse(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.plist.path),
                       "an explicit stop must also prevent restarting at login")
    }

    func testAnUpgradeReplacesTheServiceBinaryAndRestartsTheJob() async throws {
        let (_, source, location) = try fixture()
        let launchd = Launchd()
        let service = SwapdLaunchAgent(binaryPath: source.path, location: location,
                                      run: { try await launchd.run($0) }, onLine: { _ in }, onState: { _ in })
        await service.start()
        let updated = Data("#!/bin/sh\nexit 1\n".utf8)
        try updated.write(to: source)
        await service.start()
        XCTAssertEqual(try Data(contentsOf: location.binary), updated)
        let commands = await launchd.commands
        XCTAssertEqual(commands.filter { $0.first == "bootstrap" }.count, 2)
        XCTAssertEqual(commands.filter { $0.first == "bootout" }.count, 1)
        await service.stop()
    }

    func testServiceEventsArriveWithoutOwningTheDaemonPipe() async throws {
        let (_, source, location) = try fixture()
        let launchd = Launchd()
        let switched = expectation(description: "switch event from the service log")
        let service = SwapdLaunchAgent(binaryPath: source.path, location: location,
                                      run: { try await launchd.run($0) }, onLine: { line in
            if case .event(let event) = line, event.kind == "switch" { switched.fulfill() }
        }, onState: { _ in })
        await service.start()
        let writer = try FileHandle(forWritingTo: location.output)
        try writer.write(contentsOf: Data("{\"schemaVersion\":1,\"event\":\"switch\"}".utf8))
        await service.poll()
        try writer.write(contentsOf: Data("\n".utf8))
        await service.poll()
        await fulfillment(of: [switched], timeout: 2)
        try writer.close()
        await service.stop()
    }
}
#endif
