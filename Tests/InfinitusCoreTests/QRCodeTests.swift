import XCTest
@testable import InfinitusCore

final class QRCodeTests: XCTestCase {
    func testMatrixIsSquareAndOdd() {
        guard let qr = QRCode.encode("HELLO WORLD", correction: .m) else {
            XCTFail("Failed to encode HELLO WORLD")
            return
        }
        XCTAssertEqual(qr.size, 21)
        XCTAssertEqual(qr.modules.count, 21 * 21)
        XCTAssertTrue(qr.size % 2 == 1)
    }

    func testQuietZoneIsCallerOwned() {
        guard let qr = QRCode.encode("HELLO WORLD", correction: .m) else {
            XCTFail("Failed to encode")
            return
        }
        // Finder pattern top-left must start immediately at (0,0) with no quiet zone padding
        XCTAssertTrue(qr[0, 0])
        XCTAssertTrue(qr[1, 0])
        XCTAssertTrue(qr[6, 0])
        XCTAssertFalse(qr[7, 0]) // Separator is white
    }

    func testTooLongReturnsNil() {
        // Version 10 level M accommodates up to ~213 bytes. 300 bytes must return nil.
        let longString = String(repeating: "A", count: 300)
        XCTAssertNil(QRCode.encode(longString, correction: .m))
    }

    func testHelloWorldFixtureRoundTrip() {
        guard let qr = QRCode.encode("HELLO WORLD", correction: .m) else {
            XCTFail("Failed to encode HELLO WORLD")
            return
        }
        XCTAssertEqual(qr.size, 21)

        let expectedBits = "111111101100101111111100000100001001000001101110100101001011101101110101001001011101101110101110101011101100000101001001000001111111101010101111111000000001001100000000100010111111011111001000100001011100001111001111110011011010010111110001100010000000111110101010101100110000000001010111101011111111101110101011010100000100101110110011101110101101011000110101110100100100011011101110100111000111000100000100001010000000111111101111111110101"
        var actualBits = ""
        for b in qr.modules {
            actualBits.append(b ? "1" : "0")
        }
        XCTAssertEqual(actualBits, expectedBits)
    }

    func testPairURLFixtureRoundTrip() {
        let url = "infinitus://pair?url=http://192.168.1.120:47824&url=http://100.104.227.59:47824&token=ABCDEFGH23456789ABCDEFGH"
        guard let qr = QRCode.encode(url, correction: .m) else {
            XCTFail("Failed to encode pair URL")
            return
        }
        XCTAssertEqual(qr.size, 45) // Version 7 -> 45x45

        let expectedFirst50 = "11111110100000110101110100100110100010111111110000"
        var actualBits = ""
        for b in qr.modules {
            actualBits.append(b ? "1" : "0")
        }
        XCTAssertEqual(String(actualBits.prefix(50)), expectedFirst50)
        XCTAssertEqual(actualBits.count, 45 * 45)
    }
}
