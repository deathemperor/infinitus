import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import InfinitusCore

/// A video picked from Photos (#381): loaded as the movie file it is,
/// not the still frame `Data.self` hands back, so the Mac gets the
/// `.mov`/`.mp4` on disk and the session its path.
enum PickedVideo {
    struct Loaded {
        let name: String
        let mime: String
        let data: Data
        /// The first frame, for the composer chip.
        let thumbnail: UIImage?
    }

    /// A Live Photo advertises its paired movie too; it stays a photo.
    static func isVideo(_ item: PhotosPickerItem) -> Bool {
        let types = item.supportedContentTypes
        return types.contains { $0.conforms(to: .movie) } && !types.contains { $0.conforms(to: .image) }
    }

    struct Failure: Error { let message: String }

    /// `.failure` carries the sentence the composer shows: unreadable,
    /// a format or a size the wire won't take.
    static func load(_ item: PhotosPickerItem) async -> Result<Loaded, Failure> {
        guard let movie = try? await item.loadTransferable(type: Movie.self) else { return .failure(Failure(message: "couldn't read that video")) }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let mime = UTType(filenameExtension: movie.url.pathExtension)?.preferredMIMEType ?? "video/quicktime"
        guard SessionInput.allowedAttachmentMimes.contains(mime) else {
            return .failure(Failure(message: "that video is \(movie.url.pathExtension.uppercased()), not .mov or .mp4"))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? NSNumber)?.intValue ?? 0
        let cap = SessionInput.maxAttachmentBytes(mime: mime)
        guard size <= cap else {
            return .failure(Failure(message: "that video is \(size / 1_048_576) MB — the cap is \(cap / 1_048_576) MB"))
        }
        guard let data = try? Data(contentsOf: movie.url) else { return .failure(Failure(message: "couldn't read that video")) }
        let name = "video-\(UUID().uuidString.prefix(8)).\(movie.url.pathExtension.lowercased())"
        return .success(Loaded(name: name, mime: mime, data: data, thumbnail: await firstFrame(movie.url)))
    }

    private static func firstFrame(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The picker's movie, copied into a temp file we own: PhotosPicker
    /// deletes its own copy when the import closure returns.
    struct Movie: Transferable {
        let url: URL
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("picked-\(UUID().uuidString).\(received.file.pathExtension)")
                try FileManager.default.copyItem(at: received.file, to: dest)
                return Movie(url: dest)
            }
        }
    }
}
