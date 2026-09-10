import XCTest
import InfinitusCore
@testable import InfinitusMobile

/// The file route's two shapes read off the bytes (B-26, #223).
final class T3FileReplyTests: XCTestCase {
    func testJSONEnvelopeIsText() throws {
        let json = Data(#"{"path":"a.md","contents":"hello","byteLength":5,"truncated":false,"mime":"text/markdown"}"#.utf8)
        XCTAssertEqual(try T3FileReply.decode(json),
                       .text(.init(path: "a.md", contents: "hello", byteLength: 5, truncated: false, mime: "text/markdown")))
    }

    func testImageBytesAreImage() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        XCTAssertEqual(try T3FileReply.decode(png), .image(png))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertEqual(try T3FileReply.decode(jpeg), .image(jpeg))
    }

    func testMalformedEnvelopeThrows() {
        XCTAssertThrowsError(try T3FileReply.decode(Data("{not json".utf8)))
    }
}
