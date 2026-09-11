import UIKit
import InfinitusCore

/// Image → JPEG for a session attachment. Its own file because the share
/// extension (#64) compiles it too, and ScreenshotWatch's `captureApp`
/// needs UIApplication, which an extension cannot link.
enum AttachmentImage {
    /// A JPEG for the Mac: at most 2048 px on the long side, quality
    /// stepped down until it fits the Mac's attachment cap. `size` is
    /// read as pixels (scale-1 images from the picker and `captureApp`).
    static func jpeg(_ image: UIImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longest)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        for q in [quality, 0.7, 0.55, 0.4] {
            if let data = resized.jpegData(compressionQuality: q),
               data.count <= SessionInput.maxAttachmentBytes { return data }
        }
        return resized.jpegData(compressionQuality: 0.4)
    }
}
