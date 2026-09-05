import SwiftUI
import InfinitusCore

/// One image of a user prompt in the feed (2026-09-04): a screenshot
/// pasted in the terminal or a picture sent from here. Fetched through
/// the mirror so the pairing token rides along (AsyncImage can't), kept
/// per id so the feed's polls don't refetch it; tap for full size.
struct FeedThumbnail: View {
    let host: MirrorHost?
    let pid: Int32
    let id: String
    @State private var image: UIImage?
    @State private var failed = false
    @State private var showFull = false

    init(host: MirrorHost? = nil, pid: Int32, id: String) {
        self.host = host
        self.pid = pid
        self.id = id
    }

    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()
    private static let side: CGFloat = 120

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { showFull = true }
                    .accessibilityLabel("Image")
                    .accessibilityHint("Opens it full size")
                    .accessibilityAddTraits(.isButton)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: Self.side, height: Self.side)
                    .overlay {
                        if failed {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    .accessibilityLabel(failed ? "Image unavailable" : "Image loading")
            }
        }
        .task(id: id) { await load() }
        .sheet(isPresented: $showFull) {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func load() async {
        let hostPrefix = host?.id ?? "default"
        let key = "\(hostPrefix)/\(pid)/\(id)" as NSString
        if let hit = Self.cache.object(forKey: key) { image = hit; return }
        do {
            let data = try await NetworkFleetMirror.shared.sessionImage(host: host, pid: pid, id: id)
            guard let decoded = UIImage(data: data) else { failed = true; return }
            Self.cache.setObject(decoded, forKey: key)
            image = decoded
        } catch {
            failed = true
        }
    }
}
