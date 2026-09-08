import Foundation
import UIKit
import UniformTypeIdentifiers
import InfinitusCore

/// A staged composer attachment (T3 clone C-2): the bytes the Mac gets,
/// plus a thumbnail when it is an image.
struct ComposerAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data
    let thumbnail: UIImage?

    var wire: SessionInput.Attachment { .init(name: name, mime: mime, data: data) }
}

/// How the T3 composer stages what the user picks — the feed's rules
/// (`SessionFeedScreen.addImage` & co.) as pure builders: every image is
/// downscaled and re-encoded JPEG whatever its source, files keep their
/// bytes but must be an allowed type; both respect the wire's size cap.
/// Failures come back as the sentence the composer shows.
enum ComposerAttachments {
    static let capBytes = SessionInput.maxAttachmentBytes
    static let capCount = SessionInput.maxAttachments

    static func image(_ image: UIImage, prefix: String) -> Result<ComposerAttachment, Failure> {
        guard let jpeg = AttachmentImage.jpeg(image) else { return .failure(.unreadable("photo")) }
        guard jpeg.count <= capBytes else { return .failure(.tooLarge(bytes: jpeg.count, compressed: true)) }
        return .success(.init(name: "\(prefix)-\(UUID().uuidString.prefix(8)).jpg", mime: "image/jpeg",
                              data: jpeg, thumbnail: UIImage(data: jpeg)))
    }

    static func photo(_ data: Data?) -> Result<ComposerAttachment, Failure> {
        guard let data, let picked = UIImage(data: data) else { return .failure(.unreadable("photo")) }
        return image(picked, prefix: "photo")
    }

    /// A picked video, already loaded and checked by `PickedVideo` (#381).
    static func video(_ loaded: Result<PickedVideo.Loaded, PickedVideo.Failure>) -> Result<ComposerAttachment, Failure> {
        switch loaded {
        case .success(let v): return .success(.init(name: v.name, mime: v.mime, data: v.data, thumbnail: v.thumbnail))
        case .failure(let f): return .failure(.video(f.message))
        }
    }

    static func file(named name: String, data: Data) -> Result<ComposerAttachment, Failure> {
        guard data.count <= capBytes else { return .failure(.tooLarge(bytes: data.count, compressed: false, name: name)) }
        let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        guard SessionInput.allowedAttachmentMimes.contains(mime) else { return .failure(.unsupported(name)) }
        return .success(.init(name: name, mime: mime, data: data, thumbnail: nil))
    }

    enum Failure: Error, Equatable {
        case unreadable(String)
        case tooLarge(bytes: Int, compressed: Bool, name: String? = nil)
        case unsupported(String)
        case full
        /// `PickedVideo`'s own sentence.
        case video(String)

        var message: String {
            let capMB = ComposerAttachments.capBytes / 1_048_576
            switch self {
            case .unreadable(let what): return "couldn't read that \(what)"
            case .tooLarge(let bytes, true, _):
                return "that photo is still \(bytes / 1_048_576) MB after compression — the cap is \(capMB) MB"
            case .tooLarge(_, false, let name): return "\(name ?? "that file") is over \(capMB) MB"
            case .unsupported(let name): return "\(name) isn't a supported file type"
            case .full: return "the message already has \(ComposerAttachments.capCount) attachments"
            case .video(let message): return message
            }
        }
    }
}
