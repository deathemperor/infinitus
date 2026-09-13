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

    func testAlertPayloadShape() throws {
        let alert = try JSONSerialization.jsonObject(with: LiveActivityPush.alertPayload(
            title: "claude-swap", body: "switched to account 2")) as! [String: Any]
        let aaps = alert["aps"] as! [String: Any]
        XCTAssertEqual((aaps["alert"] as! [String: Any])["body"] as? String, "switched to account 2")
        XCTAssertEqual(aaps["sound"] as? String, "default")
        XCTAssertEqual(ActivityPushRegistration.Kind.alert.rawValue, "alert")
    }

    func testHostsAndURL() {
        XCTAssertEqual(LiveActivityPush.host(sandbox: true), "api.sandbox.push.apple.com")
        XCTAssertEqual(LiveActivityPush.url(token: "ab12", sandbox: false).absoluteString,
                       "https://api.push.apple.com/3/device/ab12")
    }

    func testOnOtherGatewayFlipsOnlyTheEnvironment() {
        let reg = ActivityPushRegistration(kind: .alert, token: "ff", deviceId: "d1", deviceName: "Titan",
                                           environment: "production", themeID: nil, macId: "m1")
        let other = reg.onOtherGateway()
        XCTAssertTrue(other.isSandbox)
        XCTAssertEqual(LiveActivityPush.url(token: other.token, sandbox: other.isSandbox).host, "api.sandbox.push.apple.com")
        XCTAssertEqual(other.onOtherGateway().environment, "production")
        XCTAssertEqual(other.slot, reg.slot)
        XCTAssertEqual(other.token, reg.token)
        XCTAssertEqual(other.macId, reg.macId)
    }

    func testRegistrationSlotAndRoundTrip() throws {
        let reg = ActivityPushRegistration(kind: .alert, token: "ff", deviceId: "d1", deviceName: "Titan",
                                           environment: "sandbox", themeID: "rpg",
                                           registeredAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(reg.slot, "d1/alert")
        XCTAssertTrue(reg.isSandbox)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ActivityPushRegistration.self, from: try encoder.encode(reg)), reg)
        XCTAssertNil(reg.macId)
        // The phone's key for this Mac rides along and round-trips (#144); a
        // registration persisted before the field decodes without it.
        let keyed = ActivityPushRegistration(kind: .alert, token: "ff", deviceId: "d1", deviceName: "Titan",
                                             environment: "sandbox", themeID: nil, macId: "3f9a1c0b7e2d")
        XCTAssertEqual(try decoder.decode(ActivityPushRegistration.self, from: try encoder.encode(keyed)).macId, "3f9a1c0b7e2d")
        let legacy = Data("""
        {"kind":"alert","token":"ff","deviceId":"d1","deviceName":"Titan","environment":"sandbox","registeredAt":"2026-09-09T00:00:00Z"}
        """.utf8)
        XCTAssertNil(try decoder.decode(ActivityPushRegistration.self, from: legacy).macId)
    }

    func testDeadTokensIncludeTheOldBundleIdsRegistrations() {
        XCTAssertTrue(LiveActivityPush.isDeadToken(status: 410, body: #"{"reason":"Unregistered"}"#))
        XCTAssertTrue(LiveActivityPush.isDeadToken(status: 400, body: #"{"reason":"BadDeviceToken"}"#))
        XCTAssertTrue(LiveActivityPush.isDeadToken(status: 400, body: #"{"reason":"DeviceTokenNotForTopic"}"#))
        XCTAssertFalse(LiveActivityPush.isDeadToken(status: 403, body: #"{"reason":"InvalidProviderToken"}"#))
        XCTAssertFalse(LiveActivityPush.isDeadToken(status: 200, body: ""))
    }
}
