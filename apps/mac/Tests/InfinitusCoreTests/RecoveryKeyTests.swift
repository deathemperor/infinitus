import XCTest
@testable import InfinitusCore

final class RecoveryKeyTests: XCTestCase {
    func testBase32DecodeInvertsEncode() {
        for s in ["", "f", "fo", "foo", "foob", "fooba", "foobar"] {
            XCTAssertEqual(Base32.decode(Base32.encode(Data(s.utf8))), Data(s.utf8), s)
        }
        XCTAssertEqual(Base32.decode("MZXW6"), Data("foo".utf8), "case-insensitive")
        XCTAssertNil(Base32.decode("mzxw6!"), "bad alphabet")
        XCTAssertNil(Base32.decode("m"), "a lone char carries no whole byte")
    }

    func testRecoveryKeyIsEightGroupsAndRoundTrips() throws {
        let secret = Data((0..<32).map { UInt8($0 &* 7) })
        let key = RecoveryKey.encode(secret)
        let groups = key.split(separator: "-")
        XCTAssertEqual(groups.count, 8)
        XCTAssertEqual(groups.map(\.count), [7, 7, 7, 7, 6, 6, 6, 6])
        XCTAssertEqual(key.count, 52 + 7)
        XCTAssertEqual(RecoveryKey.decode(key), secret)
        XCTAssertEqual(RecoveryKey.decode(key.uppercased().replacingOccurrences(of: "-", with: " ")), secret, "dashes/spaces/case are cosmetic")
        XCTAssertNil(RecoveryKey.decode(String(key.dropLast(2))), "wrong length")
        XCTAssertNil(RecoveryKey.decode("not a key"))
        let identity = try TeamIdentity(secret: secret)
        XCTAssertEqual(try TeamIdentity(secret: RecoveryKey.decode(key)!).kid, identity.kid)
    }
}
