import ImageIO
import InfinitusCore
import Intents
import Social
import UIKit
import UniformTypeIdentifiers

/// Share → Infinitus from any app (#64, #82): images, files, a link or
/// text go into a session with the note typed here, over the mirror
/// client the app uses. The pairing arrives through the shared keychain
/// item (ShareBridge); the session list is asked of every paired Mac
/// live (#144), so a picked session exists — a session tapped in the
/// suggestions row is preselected by its working directory.
final class ShareViewController: SLComposeServiceViewController {
    struct Session: Equatable {
        let pid: Int
        let cwd: String
        let label: String
        /// nil = the primary Mac; pids repeat across Macs.
        let macId: String?
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
    private static let lastMacKey = "share_last_mac"
    private var sessions: [Session] = []
    /// One mirror per other Mac, built for the session list and reused
    /// for the post so the route that answered carries the message.
    private var mirrors: [String: NetworkFleetMirror] = [:]
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
        let others = ShareBridge.others()
        let several = !others.isEmpty
        // The primary first, so a suggestion-row cwd (donated for its
        // sessions) lands on it; then every other Mac as it answers — a
        // Mac that's away costs its own connect timeouts, never the rows
        // already on screen.
        let primary = await load(macId: nil, mac: nil, mirror: .shared, several: several)
        var answered = primary == nil
        if several {
            await withTaskGroup(of: Bool.self) { group in
                for pairing in others {
                    let mirror = NetworkFleetMirror(pairing: pairing)
                    mirrors[pairing.id] = mirror
                    group.addTask { await self.load(macId: pairing.id, mac: pairing.name, mirror: mirror, several: true) == nil }
                }
                for await ok in group where ok { answered = true }
            }
        }
        guard sessions.isEmpty else { return }
        sessionItem.value = answered ? "no live sessions" : several ? "no Mac answered" : primary ?? "the Mac didn't answer"
    }

    /// One Mac's live sessions appended to the list; the problem when it
    /// gave none for a reason other than having none.
    private func load(macId: String?, mac: String?, mirror: NetworkFleetMirror, several: Bool) async -> String? {
        do {
            guard let snapshot = try await mirror.latest() else { return "the Mac didn't answer" }
            let fresh = Self.sessions(in: snapshot, macId: macId, mac: several ? mac ?? snapshot.machineName : nil)
            sessions += fresh
            // The tapped suggestion wins whichever Mac answers with it;
            // otherwise the first rows in pick the last-used session.
            if let suggested, let hit = fresh.first(where: { $0.macId == suggested.macId && $0.cwd == suggested.cwd }) {
                selected = hit
            } else if selected == nil, !sessions.isEmpty {
                let lastPid = UserDefaults.standard.integer(forKey: Self.lastPidKey)
                let lastMac = UserDefaults.standard.string(forKey: Self.lastMacKey)
                selected = sessions.first { $0.pid == lastPid && $0.macId == lastMac } ?? sessions[0]
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The session a tapped suggestions-row entry names (#82), on its Mac.
    private var suggested: (macId: String?, cwd: String)? {
        (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier
            .map(ShareBridge.session(conversation:))
    }

    private func mirror(for macId: String?) -> NetworkFleetMirror {
        macId.flatMap { mirrors[$0] } ?? .shared
    }

    /// Waiting sessions first (they are the ones a share most likely
    /// answers), then newest first like the app's shake picker; labelled
    /// by the session's own name and its repo (#123), and by the Mac when
    /// more than one is paired.
    static func sessions(in snapshot: MirrorSnapshot, macId: String?, mac: String?) -> [Session] {
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
            var label = name == repo ? repo : "\(name) · \(repo)"
            if let mac { label += " · \(mac)" }
            return Session(pid: session.pid, cwd: session.cwd,
                           label: session.status == "waiting" ? "\(label) · waiting" : label, macId: macId)
        }
    }

    private func pickSession() {
        guard !sessions.isEmpty else { return }
        let picker = SessionPickerController(sessions: sessions, selected: selected) { [weak self] session in
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
            let reply = try await mirror(for: session.macId).sessionInput(pid: Int32(session.pid), request: request)
            // Only "delivered" means the session has it; "running" and
            // "captured" are the Mac saying nothing was typed (a turn in
            // progress, a menu on screen) — the same words the app uses.
            guard reply.outcome == "delivered" else {
                fail(reply.outcome == "rejected" && reply.detail == "session ended"
                     ? "that session has ended"
                     : Self.describe(reply.outcome, detail: reply.detail))
                return
            }
            UserDefaults.standard.set(session.pid, forKey: Self.lastPidKey)
            UserDefaults.standard.set(session.macId, forKey: Self.lastMacKey)
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
    private let selected: ShareViewController.Session?
    private let onPick: (ShareViewController.Session) -> Void

    init(sessions: [ShareViewController.Session], selected: ShareViewController.Session?,
         onPick: @escaping (ShareViewController.Session) -> Void) {
        self.sessions = sessions
        self.selected = selected
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
        cell.accessoryType = session == selected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onPick(sessions[indexPath.row])
    }
}
