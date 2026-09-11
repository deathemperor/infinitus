import UIKit
import XCTest
@testable import InfinitusMobile

/// The T3 composer's staging rules (C-2): images become capped JPEGs,
/// files keep their bytes but must be an allowed type under the cap.
final class ComposerAttachmentsTests: XCTestCase {
    func testAnImageBecomesAJPEGWithAThumbnail() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let staged = try ComposerAttachments.image(image, prefix: "camera").get()
        XCTAssertEqual(staged.mime, "image/jpeg")
        XCTAssertTrue(staged.name.hasPrefix("camera-"))
        XCTAssertTrue(staged.name.hasSuffix(".jpg"))
        XCTAssertNotNil(staged.thumbnail)
        XCTAssertEqual(ComposerAttachments.photo(Data([1, 2, 3])), .failure(.unreadable("photo")))
    }

    func testAFileKeepsItsBytesButMustBeAllowedAndUnderTheCap() {
        let text = Data("hello".utf8)
        XCTAssertEqual(try ComposerAttachments.file(named: "notes.txt", data: text).get().mime, "text/plain")
        XCTAssertEqual(try ComposerAttachments.file(named: "notes.txt", data: text).get().data, text)
        XCTAssertEqual(ComposerAttachments.file(named: "app.zip", data: text), .failure(.unsupported("app.zip")))
        let big = Data(count: ComposerAttachments.capBytes + 1)
        XCTAssertEqual(ComposerAttachments.file(named: "big.pdf", data: big),
                       .failure(.tooLarge(bytes: big.count, compressed: false, name: "big.pdf")))
        XCTAssertEqual(ComposerAttachments.Failure.tooLarge(bytes: big.count, compressed: false, name: "big.pdf").message,
                       "big.pdf is over 5 MB")
    }
}
