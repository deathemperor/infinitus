import XCTest
@testable import InfinitusCore

final class TeamDeflateTests: XCTestCase {
    func testRoundTripAndShrinksRepetitiveInput() throws {
        let text = Data(String(repeating: "{\"type\":\"assistant\",\"n\":1}\n", count: 2000).utf8)
        let packed = try Deflate.compress(text)
        XCTAssertLessThan(packed.count, text.count / 10)
        XCTAssertEqual(try Deflate.decompress(packed), text)
        XCTAssertEqual(try Deflate.decompress(try Deflate.compress(Data())), Data())
    }

    func testGarbageAndOversizedOutputAreRejected() throws {
        XCTAssertThrowsError(try Deflate.decompress(Data([1, 2, 3, 4])))
        XCTAssertThrowsError(try Deflate.decompress(Data()))   // nothing is not an empty stream
        let big = Data(repeating: 0, count: 100_000)
        XCTAssertThrowsError(try Deflate.decompress(try Deflate.compress(big), maxBytes: 50_000))
        // A cap below the 1 KiB floor still holds.
        let small = Data(repeating: 7, count: 512)
        XCTAssertThrowsError(try Deflate.decompress(try Deflate.compress(small), maxBytes: 16))
        XCTAssertEqual(try Deflate.decompress(try Deflate.compress(small), maxBytes: 512), small)
    }
}
