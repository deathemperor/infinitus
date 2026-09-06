import XCTest
@testable import InfinitusCore

final class FleetMirrorTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-\(UUID().uuidString)")
            .appendingPathComponent("mirror-snapshot.json")
    }

    func testRoundTrip() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = MirrorSnapshot(
            capturedAt: Date(),
            machineName: "Test Mac",
            listJSON: Data("{\"accounts\":[]}".utf8),
            sessions: [SessionPanelRow(repo: "limitless", status: "busy")])
        try MirrorWriter.write(snapshot, to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.machineName, snapshot.machineName)
        XCTAssertEqual(got.listJSON, snapshot.listJSON)
        XCTAssertEqual(got.sessions, snapshot.sessions)
        XCTAssertEqual(got.capturedAt.timeIntervalSince1970,
                       snapshot.capturedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testRoundTripWithPrefs() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prefs = FleetPrefs(themeID: "rpg", compactRows: true, popupLayout: "stacked",
                                burnStyle: "ash", introStyle: "fade", introTitle: "slide",
                                introSpeed: 1.5, customThemes: [.off],
                                sortByHeadroom: false, popupTextSize: "large",
                                reviveLeadMinutes: 25)
        let usageJSON = Data("{\"days\":7,\"totalCost\":1.5}".utf8)
        let snapshot = MirrorSnapshot(
            capturedAt: Date(),
            machineName: "Test Mac",
            listJSON: Data("{\"accounts\":[]}".utf8),
            sessions: [],
            prefs: prefs,
            usageJSON: usageJSON)
        try MirrorWriter.write(snapshot, to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.prefs, prefs)
        XCTAssertEqual(got.usageJSON, usageJSON)
    }

    func testMissingPrefsDecodesToNil() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Hand-written JSON matching a pre-#9-C1 snapshot (no "prefs" key)
        // to prove old snapshots still decode.
        let json = """
        {"capturedAt":"2026-01-01T00:00:00Z","machineName":"Old Mac",
         "listJSON":"e30=","sessions":[]}
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertNil(got.prefs)
        XCTAssertNil(got.usageJSON)
    }

    func testPrefsWithoutNewFieldsDefaultsToHeadroomSortAndDefaultTextSize() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Hand-written JSON matching a pre-D1a prefs object (only the
        // original eight keys) to prove old snapshots still decode.
        let json = """
        {"capturedAt":"2026-01-01T00:00:00Z","machineName":"Old Mac",
         "listJSON":"e30=","sessions":[],
         "prefs":{"themeID":"off","compactRows":false,"popupLayout":"wide",
         "burnStyle":"ember","introStyle":"top","introTitle":"zoom",
         "introSpeed":1.0,"customThemes":[]}}
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read?.prefs)
        XCTAssertEqual(got.sortByHeadroom, true)
        XCTAssertEqual(got.popupTextSize, "default")
        XCTAssertEqual(got.reviveLeadMinutes, 10)
    }

    func testRoundTripWithFooterChipStateAndProgress() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let progress = SessionProgress(nowDoing: "Edit FleetMirror.swift",
                                       todos: .init(done: 1, total: 3, activeForm: "wiring"),
                                       retrying: false)
        let snapshot = MirrorSnapshot(
            capturedAt: Date(),
            machineName: "Test Mac",
            listJSON: Data("{\"accounts\":[]}".utf8),
            sessions: [],
            serviceStatus: ServiceStatusSummary(indicator: "minor"),
            engine: .backingOff(seconds: 12),
            progressByPid: [4242: progress])
        try MirrorWriter.write(snapshot, to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.serviceStatus, ServiceStatusSummary(indicator: "minor"))
        XCTAssertEqual(got.engine, .backingOff(seconds: 12))
        XCTAssertEqual(got.progressByPid?[4242]?.nowDoing, progress.nowDoing)
        XCTAssertEqual(got.progressByPid?[4242]?.todos, progress.todos)
    }

    func testMissingFooterChipStateDecodesToNil() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Hand-written JSON matching a pre-D2 snapshot (no serviceStatus /
        // engine / progressByPid keys) to prove old snapshots still decode.
        let json = """
        {"capturedAt":"2026-01-01T00:00:00Z","machineName":"Old Mac",
         "listJSON":"e30=","sessions":[]}
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertNil(got.serviceStatus)
        XCTAssertNil(got.engine)
        XCTAssertNil(got.progressByPid)
    }

    func testRoundTripWithEveryFleet() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let account = Account(number: 1, email: "one@example.com", organizationName: "One",
                              active: true)
        let fleet = EngineFleet(engineID: "cliproxy", provider: .claude, accounts: [account],
                                activeNumber: 1)
        let snapshot = MirrorSnapshot(
            capturedAt: Date(), machineName: "Test Mac",
            listJSON: Data("{\"accounts\":[]}".utf8), sessions: [], fleets: [fleet])
        try MirrorWriter.write(snapshot, to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.fleets?.count, 1)
        XCTAssertEqual(got.fleets?[0].engineID, "cliproxy")
        XCTAssertEqual(got.fleets?[0].accounts.first?.email, "one@example.com")
        XCTAssertEqual(got.fleets?[0].activeNumber, 1)
    }

    func testMissingFleetsDecodesToNil() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let json = """
        {"capturedAt":"2026-01-01T00:00:00Z","machineName":"Old Mac",
         "listJSON":"e30=","sessions":[]}
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertNil(got.fleets)
    }

    func testRoundTripWithAppInfo() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let app = AppInfo(version: "0.4.4", sha: "abc1234", updateVersion: "0.4.5",
                          updateChannel: "stable", phoneLatest: "0.4.5")
        let snapshot = MirrorSnapshot(
            capturedAt: Date(), machineName: "Test Mac",
            listJSON: Data("{\"accounts\":[]}".utf8), sessions: [], app: app)
        try MirrorWriter.write(snapshot, to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertEqual(got.app, app)
    }

    func testMissingAppDecodesToNil() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Hand-written JSON matching a pre-#121 snapshot (no "app" key)
        // to prove old Macs' snapshots still decode on a new phone.
        let json = """
        {"capturedAt":"2026-01-01T00:00:00Z","machineName":"Old Mac",
         "listJSON":"e30=","sessions":[]}
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let read = try await FileFleetMirror(url: url).latest()
        let got = try XCTUnwrap(read)
        XCTAssertNil(got.app)
    }

    func testServiceStatusSummaryWording() {
        XCTAssertEqual(ServiceStatusSummary(indicator: "none").shortText, "claude ok")
        XCTAssertEqual(ServiceStatusSummary(indicator: "critical").shortText, "critical outage")
        XCTAssertEqual(ServiceStatusSummary(indicator: nil).shortText, "status")
    }

    func testMissingFileReturnsNil() async throws {
        let url = tempURL()
        let read = try await FileFleetMirror(url: url).latest()
        XCTAssertNil(read)
    }

    func testCorruptFileThrows() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        do {
            _ = try await FileFleetMirror(url: url).latest()
            XCTFail("expected a decode error")
        } catch {
            // corrupt content must throw, not decode to nil
        }
    }

    func testShouldWriteThrottlesToOnePerInterval() {
        let now = Date()
        XCTAssertTrue(MirrorWriter.shouldWrite(lastWrite: nil, now: now))
        XCTAssertFalse(MirrorWriter.shouldWrite(lastWrite: now, now: now.addingTimeInterval(10)))
        XCTAssertTrue(MirrorWriter.shouldWrite(lastWrite: now, now: now.addingTimeInterval(31)))
    }

    func testLinuxStateDirPrefersXDGStateHome() {
        let withXDG = MirrorWriter.linuxStateDir(
            env: ["XDG_STATE_HOME": "/custom/state"], home: "/home/test")
        XCTAssertEqual(withXDG.path, "/custom/state/infinitus")
        let fallback = MirrorWriter.linuxStateDir(env: [:], home: "/home/test")
        XCTAssertEqual(fallback.path, "/home/test/.local/state/infinitus")
    }

    func testCloudKitFleetMirrorThrowsNotConfigured() async throws {
        do {
            _ = try await CloudKitFleetMirror().latest()
            XCTFail("expected MirrorError.notConfigured")
        } catch MirrorError.notConfigured {
            // expected
        }
    }
}
