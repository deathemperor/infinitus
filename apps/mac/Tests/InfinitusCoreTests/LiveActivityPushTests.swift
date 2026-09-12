import XCTest
@testable import InfinitusCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class LiveActivityPushTests: XCTestCase {
    #if canImport(CryptoKit)
    func testJWTIsES256SignedWithTheKeyAndCarriesKidAndIss() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try APNsJWT.make(.init(keyID: "KEY1234567", teamID: "TEAM123456",
                                         privateKeyPEM: key.pemRepresentation),
                                   now: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: Any]
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KEY1234567")
        XCTAssertEqual(claims["iss"] as? String, "TEAM123456")
        XCTAssertEqual(claims["iat"] as? Int, 1_700_000_000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    func testBadKeyIsRefused() {
        XCTAssertThrowsError(try APNsJWT.make(.init(keyID: "K", teamID: "T", privateKeyPEM: "nope")))
    }
    #endif

    // #226: ActivityKit decodes content-state with a default JSONDecoder,
    // so a Date must travel as seconds since the 2001 reference date —
    // Unix seconds landed 31 years out.
    func testContentStateDatesAreReferenceDateSeconds() throws {
        struct S: Encodable { let at: Date }
        let at = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let update = try JSONSerialization.jsonObject(with: LiveActivityPush.updatePayload(
            state: S(at: at), staleDate: nil)) as! [String: Any]
        let state = (update["aps"] as! [String: Any])["content-state"] as! [String: Any]
        XCTAssertEqual(state["at"] as? Double, 812_000_000)
    }

    func testPayloadShapes() throws {
        struct S: Encodable { let a = 1 }
        let now = Date(timeIntervalSince1970: 100)
        let update = try JSONSerialization.jsonObject(with: LiveActivityPush.updatePayload(
            state: S(), staleDate: now.addingTimeInterval(60), now: now)) as! [String: Any]
        let aps = update["aps"] as! [String: Any]
        XCTAssertEqual(aps["event"] as? String, "update")
        XCTAssertEqual(aps["timestamp"] as? Int, 100)
        XCTAssertEqual(aps["stale-date"] as? Int, 160)
        XCTAssertEqual((aps["content-state"] as! [String: Any])["a"] as? Int, 1)

        let start = try JSONSerialization.jsonObject(with: LiveActivityPush.startPayload(
            attributesType: "WorkingActivity", machine: "Mac", state: S(), staleDate: nil,
            alertTitle: "t", alertBody: "b", now: now)) as! [String: Any]
        let saps = start["aps"] as! [String: Any]
        XCTAssertEqual(saps["event"] as? String, "start")
        XCTAssertEqual(saps["attributes-type"] as? String, "WorkingActivity")
        XCTAssertEqual((saps["attributes"] as! [String: Any])["machine"] as? String, "Mac")
        XCTAssertEqual((saps["alert"] as! [String: Any])["title"] as? String, "t")
        // No alert given: the activity lands silently.
        let silent = try JSONSerialization.jsonObject(with: LiveActivityPush.startPayload(
            attributesType: "WorkingActivity", machine: "Mac", state: S(), staleDate: nil,
            now: now)) as! [String: Any]
        XCTAssertNil((silent["aps"] as! [String: Any])["alert"])
        // No key from the phone: the attributes stay as they were (#144).
        XCTAssertNil(((silent["aps"] as! [String: Any])["attributes"] as! [String: Any])["macId"])
        // The registration's key rides in the attributes so the phone files the card under its Mac.
        let keyed = try JSONSerialization.jsonObject(with: LiveActivityPush.startPayload(
            attributesType: "WorkingActivity", machine: "Mac", macId: "3f9a1c0b7e2d", state: S(), staleDate: nil,
            now: now)) as! [String: Any]
        let kattrs = (keyed["aps"] as! [String: Any])["attributes"] as! [String: Any]
        XCTAssertEqual(kattrs["machine"] as? String, "Mac")
        XCTAssertEqual(kattrs["macId"] as? String, "3f9a1c0b7e2d")

        let end = try JSONSerialization.jsonObject(with: LiveActivityPush.endPayload(
            state: S(), dismissalDate: now, now: now)) as! [String: Any]
        XCTAssertEqual((end["aps"] as! [String: Any])["dismissal-date"] as? Int, 100)

        let alert = try JSONSerialization.jsonObject(with: LiveActivityPush.alertPayload(
            title: "claude-swap", body: "switched to account 2")) as! [String: Any]
        let aaps = alert["aps"] as! [String: Any]
        XCTAssertEqual((aaps["alert"] as! [String: Any])["body"] as? String, "switched to account 2")
        XCTAssertEqual(aaps["sound"] as? String, "default")
        XCTAssertEqual(ActivityPushRegistration.Kind.alert.rawValue, "alert")
    }

    /// The expo-widgets envelope (#572 N3): one attributes type, the
    /// layout named in the content state, the same state JSON as a string.
    func testExpoLayoutWrapsTheSameStateAsNameAndProps() throws {
        struct S: Encodable { let b = 2; let a = 1 }
        let now = Date(timeIntervalSince1970: 100)
        let start = try JSONSerialization.jsonObject(with: LiveActivityPush.startPayload(
            attributesType: "WorkingActivity", machine: "Mac", macId: "3f9a", state: S(), staleDate: nil,
            expo: LiveActivityPush.expoWorkingName, now: now)) as! [String: Any]
        let aps = start["aps"] as! [String: Any]
        XCTAssertEqual(aps["attributes-type"] as? String, "LiveActivityAttributes")
        XCTAssertEqual(aps["attributes"] as! [String: String], ["url": "t3code://settings/accounts?mac=3f9a"])
        let content = aps["content-state"] as! [String: Any]
        XCTAssertEqual(content["name"] as? String, "InfinitusWorking")
        XCTAssertEqual(content["props"] as? String, #"{"a":1,"b":2}"#)
        // Update and end carry the same envelope; the native shape is untouched.
        let update = try JSONSerialization.jsonObject(with: LiveActivityPush.updatePayload(
            state: S(), staleDate: nil, expo: LiveActivityPush.expoRevivalName, now: now)) as! [String: Any]
        XCTAssertEqual(((update["aps"] as! [String: Any])["content-state"] as! [String: Any])["name"] as? String, "InfinitusRevival")
        let end = try JSONSerialization.jsonObject(with: LiveActivityPush.endPayload(
            state: S(), dismissalDate: nil, expo: LiveActivityPush.expoWorkingName, now: now)) as! [String: Any]
        XCTAssertEqual(((end["aps"] as! [String: Any])["content-state"] as! [String: Any])["props"] as? String, #"{"a":1,"b":2}"#)
        let native = try JSONSerialization.jsonObject(with: LiveActivityPush.updatePayload(
            state: S(), staleDate: nil, now: now)) as! [String: Any]
        XCTAssertEqual(((native["aps"] as! [String: Any])["content-state"] as! [String: Any])["a"] as? Int, 1)
        XCTAssertEqual(LiveActivityPush.expoDeepLink(macId: nil), "t3code://settings/accounts")
    }

    func testHostsAndTopic() {
        XCTAssertEqual(LiveActivityPush.host(sandbox: true), "api.sandbox.push.apple.com")
        XCTAssertEqual(LiveActivityPush.url(token: "ab12", sandbox: false).absoluteString,
                       "https://api.push.apple.com/3/device/ab12")
        XCTAssertEqual(LiveActivityPush.topic, "run.infinitus.mobile.push-type.liveactivity")
    }

    func testOnOtherGatewayFlipsOnlyTheEnvironment() {
        let reg = ActivityPushRegistration(kind: .working, token: "ff", deviceId: "d1", deviceName: "Titan",
                                           environment: "production", themeID: nil, macId: "m1", layout: "expo")
        let other = reg.onOtherGateway()
        XCTAssertTrue(other.isSandbox)
        XCTAssertEqual(LiveActivityPush.url(token: other.token, sandbox: other.isSandbox).host, "api.sandbox.push.apple.com")
        XCTAssertEqual(other.onOtherGateway().environment, "production")
        XCTAssertEqual(other.slot, reg.slot)
        XCTAssertEqual(other.token, reg.token)
        XCTAssertEqual(other.macId, reg.macId)
        XCTAssertEqual(other.layout, reg.layout)
    }

    func testRegistrationSlotAndRoundTrip() throws {
        let reg = ActivityPushRegistration(kind: .working, token: "ff", deviceId: "d1", deviceName: "Titan",
                                           environment: "sandbox", themeID: "rpg",
                                           registeredAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(reg.slot, "d1/working")
        XCTAssertTrue(reg.isSandbox)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ActivityPushRegistration.self, from: try encoder.encode(reg)), reg)
        XCTAssertNil(reg.macId)
        // The phone's key for this Mac rides along and round-trips (#144); a
        // registration persisted before the field decodes without it.
        let keyed = ActivityPushRegistration(kind: .workingStart, token: "ff", deviceId: "d1", deviceName: "Titan",
                                             environment: "sandbox", themeID: nil, macId: "3f9a1c0b7e2d")
        XCTAssertEqual(try decoder.decode(ActivityPushRegistration.self, from: try encoder.encode(keyed)).macId, "3f9a1c0b7e2d")
        let legacy = Data("""
        {"kind":"working","token":"ff","deviceId":"d1","deviceName":"Titan","environment":"sandbox","registeredAt":"2026-09-09T00:00:00Z"}
        """.utf8)
        XCTAssertNil(try decoder.decode(ActivityPushRegistration.self, from: legacy).macId)
        // `layout` (#572 N3): absent or "native" is the native app; "expo" the
        // fork's host; a value this build does not know is not a decode failure.
        XCTAssertFalse(try decoder.decode(ActivityPushRegistration.self, from: legacy).isExpo)
        let expo = ActivityPushRegistration(kind: .working, token: "ff", deviceId: "d1", deviceName: "Titan",
                                            environment: "sandbox", themeID: nil, layout: "expo")
        XCTAssertTrue(expo.isExpo)
        XCTAssertTrue(try decoder.decode(ActivityPushRegistration.self, from: try encoder.encode(expo)).isExpo)
        let odd = Data("""
        {"kind":"working","token":"ff","deviceId":"d1","deviceName":"Titan","environment":"sandbox","registeredAt":"2026-09-09T00:00:00Z","layout":"flutter"}
        """.utf8)
        XCTAssertFalse(try decoder.decode(ActivityPushRegistration.self, from: odd).isExpo)
    }
}

final class LiveActivityBuilderTests: XCTestCase {
    private func account(_ n: Int, active: Bool, five: Double, seven: Double, alias: String? = nil,
                         resets: String? = nil) -> Account {
        Account(number: n, email: "p\(n)@x.com", organizationName: "", organizationUuid: "",
                isOrganization: false, active: active, usageStatus: "ok",
                usage: Usage(fiveHour: UsageWindow(pct: five, resetsAt: resets),
                             sevenDay: UsageWindow(pct: seven, resetsAt: resets),
                             scoped: [UsageWindow(pct: 74, resetsAt: resets, name: "Fable")], spend: nil),
                alias: alias, icon: nil, plan: "Max 20x", disabled: nil, preferred: nil,
                usageFetchedAt: nil, usageAgeSeconds: nil, lastGoodUsage: nil,
                lastGoodFetchedAt: nil, lastGoodAgeSeconds: nil)
    }

    private func fleet(accounts: [Account], next: Int?, recovery: NextRecovery? = nil,
                       busy: Int) -> EngineFleet {
        EngineFleet(engineID: "swapd", provider: .claude, accounts: accounts, activeNumber: nil,
                    nextCandidate: next, nextRecovery: recovery,
                    liveSessions: LiveSessions(busy: busy, total: 12, idle: nil, waiting: 2, shell: nil,
                                               unknown: nil, sessions: nil), raw: nil)
    }

    func testWorkingStateIsThemedAndPicksTheBindingWindow() throws {
        let rpg = try XCTUnwrap(RowTheme.builtins.first { $0.id == "rpg" })
        let f = fleet(accounts: [account(1, active: true, five: 44, seven: 63, alias: "death2"),
                                 account(2, active: false, five: 0, seven: 0)], next: 2, busy: 3)
        let state = try XCTUnwrap(LiveActivityBuilder.working(
            fleet: f, theme: rpg, report: nil, tokenRate: TokenRate(perMinute: 900, peakPerMinute: 1800)))
        XCTAssertEqual(state.active, "death2")
        XCTAssertEqual(state.windows.map(\.label).count, 3)
        XCTAssertEqual(state.binding, 2)            // Fable 74% > 63 > 44
        XCTAssertEqual(state.busy, 3)
        XCTAssertEqual(state.waiting, 2)
        XCTAssertEqual(state.tokensPerMinute, 900)
        XCTAssertEqual(state.tokenFraction, 0.5)
        XCTAssertTrue(state.next?.hasSuffix("p2") == true)
        XCTAssertFalse(state.plain)
        XCTAssertNil(LiveActivityBuilder.working(fleet: fleet(accounts: f.accounts, next: 2, busy: 0),
                                                 theme: rpg, report: nil, tokenRate: nil))
    }

    func testRevivalStateOnlyWhenAllDead() throws {
        let plain = RowTheme.off
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let dead = fleet(accounts: [account(1, active: true, five: 100, seven: 40, alias: "loc", resets: soon)],
                         next: nil, recovery: NextRecovery(number: 1, at: soon), busy: 0)
        let state = try XCTUnwrap(LiveActivityBuilder.revival(fleet: dead, theme: plain))
        XCTAssertEqual(state.reviver, "loc")
        XCTAssertEqual(state.reviveWord, "recovers")
        XCTAssertFalse(state.revived)
        XCTAssertNil(LiveActivityBuilder.revival(
            fleet: fleet(accounts: dead.accounts, next: 1, recovery: dead.nextRecovery, busy: 0), theme: plain))
        // #226: the engine's own word is gated by the same horizon as the
        // ranked accounts — a 2057 reset never reaches the lock screen.
        let farOut = "2057-05-16T08:28:25Z"
        XCTAssertNil(LiveActivityBuilder.revival(
            fleet: fleet(accounts: [account(1, active: true, five: 100, seven: 40, alias: "loc", resets: farOut)],
                         next: nil, recovery: NextRecovery(number: 1, at: farOut), busy: 0), theme: plain))
    }

    func testDiffersIgnoresSmallMoves() throws {
        let rpg = try XCTUnwrap(RowTheme.builtins.first { $0.id == "rpg" })
        let a = try XCTUnwrap(LiveActivityBuilder.working(
            fleet: fleet(accounts: [account(1, active: true, five: 40, seven: 60)], next: nil, busy: 1),
            theme: rpg, report: nil, tokenRate: nil))
        var b = a
        b.windows[0].pct = 43
        XCTAssertFalse(LiveActivityBuilder.differs(a, b))
        b.windows[0].pct = 46
        XCTAssertTrue(LiveActivityBuilder.differs(a, b))
        b = a; b.busy = 2
        XCTAssertTrue(LiveActivityBuilder.differs(a, b))
    }

    func testDeadTokensIncludeTheOldBundleIdsRegistrations() {
        XCTAssertTrue(LiveActivityPush.isDeadToken(status: 410, body: #"{"reason":"Unregistered"}"#))
        XCTAssertTrue(LiveActivityPush.isDeadToken(status: 400, body: #"{"reason":"BadDeviceToken"}"#))
        XCTAssertTrue(LiveActivityPush.isDeadToken(status: 400, body: #"{"reason":"DeviceTokenNotForTopic"}"#))
        XCTAssertFalse(LiveActivityPush.isDeadToken(status: 403, body: #"{"reason":"InvalidProviderToken"}"#))
        XCTAssertFalse(LiveActivityPush.isDeadToken(status: 200, body: ""))
    }
}
