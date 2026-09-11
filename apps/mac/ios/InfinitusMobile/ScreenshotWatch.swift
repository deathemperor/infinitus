import SwiftUI
import UIKit
import Photos
import InfinitusCore

/// Screenshots taken since the phone last looked — offered on a session's
/// chat as a one-tap send (user 2026-09-04: "a lot of screenshots that
/// come from this app … send it right away", "react system screenshots
/// too as I may take screenshots from other apps").
///
/// Reading the library needs full Photos access: a "limited" grant never
/// includes a screenshot taken after it, so it counts as no access here.
/// A screenshot taken while the app is in front doesn't need the library
/// at all — the app renders its own window (`ScreenshotWatch.captureApp`).
@MainActor
final class ScreenshotWatch: ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: String
        let takenAt: Date
        let thumbnail: UIImage?
    }

    static let enabledKey = "screenshots_offer"
    private static let watermarkKey = "screenshots_watermark"
    /// A shot older than this is never offered — a day away shouldn't
    /// resurface last night's screenshots.
    private static let maxAge: TimeInterval = 10 * 60

    @Published private(set) var found: [Found] = []
    @Published private(set) var access: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var hasAccess: Bool { access == .authorized }

    /// The moment before which nothing is offered. Set to "now" the first
    /// time the feature can look, so shots from before it never surface.
    private var watermark: Date {
        get {
            if let t = UserDefaults.standard.object(forKey: Self.watermarkKey) as? Double { return Date(timeIntervalSince1970: t) }
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.watermarkKey)
            return now
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.watermarkKey) }
    }

    /// Asks for full library access (a system prompt, once). Returns the
    /// resulting status.
    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = status
        if status == .authorized { _ = watermark }   // start the clock at the grant
        return status
    }

    /// Screenshots newer than the watermark (and younger than `maxAge`),
    /// newest last. Quiet when the feature is off or unauthorized.
    func check() {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.enabled, hasAccess else { found = []; return }
        let since = max(watermark, Date().addingTimeInterval(-Self.maxAge))
        // Minutes of photos at most, so the subtype filter runs in Swift
        // rather than as a predicate key (a wrong key name throws).
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@", since as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var out: [Found] = []
        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            out.append(Found(id: asset.localIdentifier, takenAt: asset.creationDate ?? Date(),
                             thumbnail: Self.image(for: asset, longest: 160)))
        }
        if out != found { found = out }
    }

    /// Full-size images for the newest `limit` offered shots, oldest first.
    func images(limit: Int) -> [UIImage] {
        let ids = found.suffix(limit).map(\.id)
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: UIImage] = [:]
        assets.enumerateObjects { asset, _, _ in
            if let image = Self.image(for: asset, longest: 2048) { byId[asset.localIdentifier] = image }
        }
        return ids.compactMap { byId[$0] }
    }

    /// Done with the current batch (sent or dismissed): nothing before
    /// now is offered again.
    func dismiss() {
        watermark = Date()
        found = []
    }

    private static func image(for asset: PHAsset, longest: CGFloat) -> UIImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        var result: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: longest, height: longest),
                                              contentMode: .aspectFit, options: options) { image, _ in
            result = image
        }
        return result
    }

    /// The app's own screen, as the user sees it — the key window drawn
    /// at device scale, returned as a scale-1 image so a pixel is a
    /// pixel for the JPEG step (whose sizing treats `size` as pixels).
    static func captureApp() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
        else { return nil }
        let scale = window.traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cg = rendered.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}
