import XCTest
@testable import InfinitusCore

final class PBKDF2Tests: XCTestCase {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testRFC7914Vector() {
        // RFC 7914 §11: P="passwd", S="salt", c=1, dkLen=64
        let dk = PBKDF2.sha256(password: Data("passwd".utf8), salt: Data("salt".utf8), rounds: 1, length: 64)
        XCTAssertEqual(hex(dk), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    func testSHA256VectorsAcrossRoundsAndLengths() {
        // draft-josefsson-pbkdf2-test-vectors (SHA-256)
        XCTAssertEqual(hex(PBKDF2.sha256(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 1, length: 32)),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(hex(PBKDF2.sha256(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 4096, length: 32)),
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(hex(PBKDF2.sha256(password: Data("passwordPASSWORDpassword".utf8), salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8), rounds: 4096, length: 40)),
                       "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
    }

    func testLengthNotAMultipleOfTheBlock() {
        XCTAssertEqual(PBKDF2.sha256(password: Data("p".utf8), salt: Data("s".utf8), rounds: 2, length: 33).count, 33)
        XCTAssertEqual(PBKDF2.sha256(password: Data("p".utf8), salt: Data("s".utf8), rounds: 2, length: 33).prefix(32),
                       PBKDF2.sha256(password: Data("p".utf8), salt: Data("s".utf8), rounds: 2, length: 32))
    }
}
