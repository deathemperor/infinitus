import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails for the mirror's image route (phone feed, 2026-09-04):
/// ImageIO reads every format the phone can send (PNG, JPEG, HEIC, GIF,
/// WebP) and a terminal screenshot paste, applies the orientation, and
/// scales into a bounding box — a 3 MB screenshot becomes a ~60 KB JPEG
/// for the long-poll's sake.
enum ImageThumbnail {
    static func jpeg(_ data: Data, maxPixels: Int, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// One thumbnail per feed image id, shared by the route's calls (the
/// phone re-renders the feed on every poll).
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSData>()
    init() { cache.countLimit = 64 }
    subscript(key: String) -> Data? {
        get { cache.object(forKey: key as NSString).map { $0 as Data } }
        set { if let newValue { cache.setObject(newValue as NSData, forKey: key as NSString) } }
    }
}
