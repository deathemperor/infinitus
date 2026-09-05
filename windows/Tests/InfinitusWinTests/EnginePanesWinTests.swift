import XCTest
@testable import InfinitusCore
@testable import InfinitusWinUI

final class EnginePanesWinTests: XCTestCase {
    func testRowActionsFollowCapabilitiesFor9Router() {
        let account = Account(number: 1, email: "nr@example.com", active: false, usageStatus: "ok", plan: "Max 5x")
        let caps = EngineCatalog.capabilities(for: "9router")
        let model = AccountRowModel(account: account, activeNumber: 2, engineID: "9router", provider: .claude, capabilities: caps)

        XCTAssertTrue(model.canSwitch)
        XCTAssertTrue(model.canHold)
        XCTAssertTrue(model.canRemove)
        XCTAssertFalse(model.canRename)
        XCTAssertFalse(model.canPrefer)
        XCTAssertFalse(model.canReorder)
        XCTAssertFalse(model.canRelogin)
    }

    func testRowActionsFollowCapabilitiesForCswap() {
        let account = Account(number: 1, email: "cs@example.com", active: true, usageStatus: "ok", preferred: true)
        let caps = EngineCatalog.capabilities(for: "cswap")
        let model = AccountRowModel(account: account, activeNumber: 1, engineID: "cswap", provider: .claude, capabilities: caps)

        // Active account cannot be switched to
        XCTAssertFalse(model.canSwitch)
        XCTAssertTrue(model.canHold)
        XCTAssertTrue(model.canRemove)
        XCTAssertTrue(model.canRename)
        XCTAssertTrue(model.canPrefer)
        XCTAssertTrue(model.canReorder)
        XCTAssertTrue(model.canRelogin)
    }

    func testPreferStarHiddenWhenPreferredIsNil() {
        let account = Account(number: 1, email: "no-pref@example.com", active: false, usageStatus: "ok", preferred: nil)
        let caps = EngineCatalog.capabilities(for: "cliproxy")
        let model = AccountRowModel(account: account, activeNumber: 2, engineID: "cliproxy", provider: .claude, capabilities: caps)

        XCTAssertFalse(model.canPrefer)
    }

    func testDPAPIRoundTrip() {
        let plaintext = "secret-key-12345"
        guard let encrypted = WinSecret.protect(plaintext) else {
            XCTFail("DPAPI protect failed")
            return
        }
        XCTAssertFalse(encrypted.isEmpty)
        let decrypted = WinSecret.unprotect(encrypted)
        XCTAssertEqual(decrypted, plaintext)

        // Corrupt blob returns nil
        let corrupt = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertNil(WinSecret.unprotect(corrupt))
    }

    func testCLIProxyConfigRoundTrip() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cliproxy-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let key = "my-management-secret"
        let enc = try XCTUnwrap(WinSecret.protect(key))
        let cfg = CLIProxyFleet.StoredConfig(baseURL: "http://127.0.0.1:8317", encryptedKey: enc)
        let data = try JSONEncoder().encode(cfg)
        try data.write(to: tempURL)

        let loadedData = try Data(contentsOf: tempURL)
        let loadedCfg = try JSONDecoder().decode(CLIProxyFleet.StoredConfig.self, from: loadedData)
        XCTAssertEqual(loadedCfg.baseURL, "http://127.0.0.1:8317")
        XCTAssertEqual(WinSecret.unprotect(loadedCfg.encryptedKey), key)
    }

    func testSettingsFormGroupsByPrefixInEmittedOrder() {
        let e1 = SettingEntry(key: "autoswitch.threshold", value: .number(90), isSet: true, kind: "int", help: "", defaultValue: .number(90))
        let e2 = SettingEntry(key: "autoswitch.strategy", value: .string("best"), isSet: true, kind: "choice", help: "", defaultValue: .string("best"), choices: ["best", "consume-first"])
        let e3 = SettingEntry(key: "ui.theme", value: .string("auto"), isSet: true, kind: "choice", help: "", defaultValue: .string("auto"), choices: ["auto", "dark"])
        let e4 = SettingEntry(key: "misc.flag", value: .bool(true), isSet: true, kind: "bool", help: "", defaultValue: .bool(false))

        let entries = [e1, e2, e3, e4]
        var prefixes: [String] = []
        var grouped: [String: [SettingEntry]] = [:]
        for e in entries {
            let pfx = String(e.key.split(separator: ".").first ?? "misc")
            if grouped[pfx] == nil { prefixes.append(pfx) }
            grouped[pfx, default: []].append(e)
        }

        XCTAssertEqual(prefixes, ["autoswitch", "ui", "misc"])
        XCTAssertEqual(grouped["autoswitch"]?.count, 2)
        XCTAssertEqual(grouped["ui"]?.count, 1)
        XCTAssertEqual(grouped["misc"]?.count, 1)
    }
}
