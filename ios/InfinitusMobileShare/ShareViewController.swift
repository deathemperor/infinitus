import ImageIO
import InfinitusCore
import Intents
import Social
import UIKit
import UniformTypeIdentifiers

/// Share → Infinitus from any app (#64, #82): images, files, a link or
/// text go into a session with the note typed here, over the mirror
/// client the app uses. The pairing arrives through the shared keychain
/// item (ShareBridge); the session list is asked of the Mac live, so a
/// picked session exists — a session tapped in the suggestions row is
/// preselected by its working directory.
final class ShareViewController: SLComposeServiceViewController {
    struct Session {
        let pid: Int
        let cwd: String
        let label: String
    }

    /// What the host app handed over, sorted into the message and its
    /// attachments.
    struct Shared {
        var text: [String] = []
        var attachments: [SessionInput.Attachment] = []
        var tooBig: [String] = []
        var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
    }

    private static let lastPidKey = "share_last_pid"
    private var sessions: [Session] = []
    private var selected: Session? {
        didSet {
            sessionItem.value = selected?.label
            validateContent()
        }
    }
    private var paired = false
    private lazy var sessionItem: SLComposeSheetConfigurationItem = {
        let item = SLComposeSheetConfigurationItem()!
        item.title = "Session"
        item.value = "looking for the Mac…"
        item.tapHandler = { [weak self] in self?.pickSession() }
        return item
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        placeholder = "What should the session do with this?"
        paired = ShareBridge.adopt()
        if !paired { sessionItem.value = "not paired" }
    }

    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        guard paired else {
            fail("Pair the Infinitus app with your Mac first — the share sheet uses the same pairing.")
            return
        }
        Task { await loadSessions() }
    }

    override func isContentValid() -> Bool { selected != nil }

    override func configurationItems() -> [Any]! { [sessionItem] }

    override func didSelectPost() {
        guard let selected else { return }
        let text = contentText ?? ""
        Task { await post(text, to: selected) }
    }

    // MARK: - Sessions

    private func loadSessions() async {
        do {
            guard let snapshot = try await NetworkFleetMirror.shared.latest() else {
                sessionItem.value = "the Mac didn't answer"
                return
            }
            sessions = Self.sessions(in: snapshot)
            guard !sessions.isEmpty else {
                sessionItem.value = "no live sessions"
                return
            }
            let lastPid = UserDefaults.standard.integer(forKey: Self.lastPidKey)
            let suggested = (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier
            selected = sessions.first { $0.cwd == suggested }
                ?? sessions.first { $0.pid == lastPid } ?? sessions[0]
        } catch {
            sessionItem.value = error.localizedDescription
        }
    }

    /// Waiting sessions first (they are the ones a share most likely
    /// answers), then newest first like the app's shake picker; labelled
    /// by the session's own name and its repo (#123).
    static func sessions(in snapshot: MirrorSnapshot) -> [Session] {
        var live = snapshot.fleets?.flatMap { $0.liveSessions?.sessions ?? [] } ?? []
        if live.isEmpty, let list = try? JSONDecoder().decode(AccountList.self, from: snapshot.listJSON) {
            live = list.liveSessions?.sessions ?? []
        }
        var seen = Set<Int>()
        return live.sorted {
            let (a, b) = ($0.status == "waiting", $1.status == "waiting")
            return a != b ? a : $0.startedAt > $1.startedAt
        }.compactMap { session in
            guard seen.insert(session.pid).inserted else { return nil }
            let repo = URL(fileURLWithPath: session.cwd).lastPathComponent
            let name = snapshot.progressByPid?[session.pid]?.name ?? repo
            let label = name == repo ? repo : "\(name) · \(repo)"
            return Session(pid: session.pid, cwd: session.cwd,
                           label: session.status == "waiting" ? "\(label) · waiting" : label)
        }
    }

    private func pickSession() {
        guard !sessions.isEmpty else { return }
        let picker = SessionPickerController(sessions: sessions, selectedPid: selected?.pid) { [weak self] session in
            self?.selected = session
            self?.popConfigurationViewController()
        }
        pushConfigurationViewController(picker)
    }

    // MARK: - Posting

    private func post(_ text: String, to session: Session) async {
        let shared = await loadShared()
        guard !shared.isEmpty else {
            fail(shared.tooBig.isEmpty ? "couldn't read what was shared"
                 : "\(shared.tooBig.joined(separator: ", ")) is over \(SessionInput.maxAttachmentBytes / 1_048_576) MB")
            return
        }
        let body = ([text] + shared.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let request = SessionInput.Request(kind: .message, text: body,
                                           attachments: shared.attachments.isEmpty ? nil : shared.attachments)
        do {
            let reply = try await NetworkFleetMirror.shared.sessionInput(pid: Int32(session.pid), request: request)
            // Only "delivered" means the session has it; "running" and
            // "captured" are the Mac saying nothing was typed (a turn in
            // progress, a menu on screen) — the same words the app uses.
            guard reply.outcome == "delivered" else {
                fail(Self.describe(reply.outcome, detail: reply.detail))
                return
            }
            UserDefaults.standard.set(session.pid, forKey: Self.lastPidKey)
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func describe(_ outcome: String, detail: String?) -> String {
        switch outcome {
        case "running": return "session is mid-turn — try again when it's waiting"
        case "noSurface": return "this session has nowhere to receive input right now"
        case "noChannel": return "this session can't receive messages right now"
        case "captured": return "a menu is on screen — try again"
        case "rejected": return "that wasn't a valid reply"
        default: return detail ?? outcome
        }
    }

    /// Everything the host app handed over: images (any shape — a file
    /// URL from Photos, a UIImage from the screenshot preview, raw
    /// bytes) become JPEG attachments, files the Mac accepts (PDF, text)
    /// go as they are, a link or text joins the message. Files and
    /// images decode downsampled: an extension has a fraction of an
    /// app's memory. Four attachments at most, five MB each.
    private func loadShared() async -> Shared {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        var shared = Shared()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard shared.attachments.count < SessionInput.maxAttachments else { continue }
                if let image = await Self.loadImage(provider), let jpeg = AttachmentImage.jpeg(image) {
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    shared.attachments.append(.init(name: "share-\(stamp)-\(shared.attachments.count + 1).jpg",
                                                    mime: "image/jpeg", data: jpeg))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                guard shared.attachments.count < SessionInput.maxAttachments,
                      let url = await Self.load(provider, UTType.fileURL.identifier) as? URL else { continue }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                guard SessionInput.allowedAttachmentMimes.contains(mime),
                      let data = try? Data(contentsOf: url) else { continue }
                guard data.count <= SessionInput.maxAttachmentBytes else {
                    shared.tooBig.append(url.lastPathComponent)
                    continue
                }
                shared.attachments.append(.init(name: url.lastPathComponent, mime: mime, data: data))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await Self.load(provider, UTType.url.identifier) as? URL {
                    shared.text.append(url.absoluteString)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await Self.load(provider, UTType.plainText.identifier) as? String,
                   !text.isEmpty { shared.text.append(text) }
            }
        }
        return shared
    }

    private static func load(_ provider: NSItemProvider, _ type: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    /// Returned at scale 1 so the JPEG step reads its size as pixels.
    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        let image: UIImage? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL:
                    continuation.resume(returning: CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(Self.downsampled))
                case let image as UIImage:
                    continuation.resume(returning: image)
                case let data as Data:
                    continuation.resume(returning: CGImageSourceCreateWithData(data as CFData, nil).flatMap(Self.downsampled))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let image else { return nil }
        guard image.scale != 1, let cg = image.cgImage else { return image }
        return UIImage(cgImage: cg, scale: 1, orientation: image.imageOrientation)
    }

    /// At most 2048 px on the long side, orientation applied, decoded
    /// straight to that size (ImageIO never holds the full bitmap).
    private static func downsampled(_ source: CGImageSource) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .map { UIImage(cgImage: $0, scale: 1, orientation: .up) }
    }

    /// One alert, then the sheet closes — a POST is not retried in place.
    private func fail(_ message: String) {
        let alert = UIAlertController(title: "Couldn't send", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        present(alert, animated: true)
    }
}

/// The "Session" row's picker: one row per live session, newest first.
final class SessionPickerController: UITableViewController {
    private let sessions: [ShareViewController.Session]
    private let selectedPid: Int?
    private let onPick: (ShareViewController.Session) -> Void

    init(sessions: [ShareViewController.Session], selectedPid: Int?,
         onPick: @escaping (ShareViewController.Session) -> Void) {
        self.sessions = sessions
        self.selectedPid = selectedPid
        self.onPick = onPick
        super.init(style: .insetGrouped)
        title = "Session"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sessions.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let session = sessions[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "session")
            ?? UITableViewCell(style: .default, reuseIdentifier: "session")
        cell.textLabel?.text = session.label
        cell.accessoryType = session.pid == selectedPid ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onPick(sessions[indexPath.row])
    }
}
