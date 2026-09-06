import Foundation

/// Layer 2 of #17: the phone sends a reply or a decision into a Claude
/// Code session on the Mac. The wire types compile everywhere (the phone
/// encodes/decodes them); delivery is macOS-only, same split as
/// `SessionFeed`/`SessionFeedReader`.
public enum SessionInput {
    /// Wire body of `POST /sessions/<pid>/input`.
    public struct Request: Codable, Sendable, Equatable {
        /// `resume` (user 2026-09-04 from the phone: "a button that
        /// continues the session that maybe stopped by various reasons"):
        /// the Mac composes the continue message itself; `text` is
        /// ignored. Whatever stopped the session — a limit, a crash, a
        /// closed terminal, a lost network — the ask is the same.
        /// `approve` (#79): "allow for this session" from the phone —
        /// `text` is `ToolApproval.encode(tool:input:)`; the Mac records
        /// the rule and answers the prompt with Yes.
        /// `mode` (#163 phase 2): `text` is one of `SessionStart.hookModes`;
        /// the Mac moves the session's permission mode for the plugin's
        /// PreToolUse hook — nothing is typed into the session.
        public enum Kind: String, Codable, Sendable { case message, key, resume, approve, mode }
        public let kind: Kind
        /// `message`: free text. `key`: one of `SessionInput.allowedKeys`.
        public let text: String
        /// Images/files riding along with a `message` (2026-09-03 "add
        /// features to allow attachments"). Optional so an old client's
        /// JSON — no `attachments` key at all — still decodes.
        public let attachments: [Attachment]?

        public init(kind: Kind, text: String, attachments: [Attachment]? = nil) {
            self.kind = kind
            self.text = text
            self.attachments = attachments
        }
    }

    /// One phone-picked file, base64 on the wire via `Data`'s default
    /// Codable encoding.
    public struct Attachment: Codable, Sendable, Equatable {
        public let name: String
        public let mime: String
        public let data: Data

        public init(name: String, mime: String, data: Data) {
            self.name = name
            self.mime = mime
            self.data = data
        }
    }

    /// What a `resume` request delivers. Claude Code drops a message
    /// identical to the previous one from the same sender, so a second
    /// tap carries the time.
    public static func continueText(now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "[Infinitus] Continue where you left off — this session stopped, and you were asked from the phone to pick the task back up from your last step. (\(f.string(from: now)))"
    }

    /// At most this many attachments per message.
    public static let maxAttachments = 4
    /// Per-attachment cap, after base64 decoding.
    public static let maxAttachmentBytes = 5 * 1024 * 1024
    public static let allowedAttachmentMimes: Set<String> = [
        "image/png", "image/jpeg", "image/heic", "image/gif", "image/webp",
        "text/plain", "application/pdf",
    ]

    public struct Reply: Codable, Sendable, Equatable {
        /// "delivered" | "running" | "captured" | "noSurface" | "noChannel" | "rejected"
        public let outcome: String
        /// "pty" | "socket" — set only when `outcome == "delivered"`.
        public let channel: String?
        public let detail: String?

        public init(outcome: String, channel: String? = nil, detail: String? = nil) {
            self.outcome = outcome
            self.channel = channel
            self.detail = detail
        }
    }

    /// Number keys select an option and Enter confirms it in Claude
    /// Code's menus; `y`/`n` cover the plain confirm prompts.
    public static let allowedKeys: Set<String> = [
        "y", "n", "1", "2", "3", "4", "5", "6", "7", "8", "9", "enter", "esc",
    ]
}

#if !os(iOS)
extension SessionInput {
    public static let maxMessageLength = 4000

    /// Non-empty, within the length cap, and free of control characters
    /// other than newline (a stray Tab/CR/ESC byte from a malformed
    /// client should never reach a real terminal).
    public static func isValidMessage(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxMessageLength else { return false }
        for scalar in text.unicodeScalars where scalar != "\n" {
            if scalar.properties.generalCategory == .control { return false }
        }
        return true
    }

    /// `~/Library/Application Support/Infinitus/attachments` on macOS,
    /// `$XDG_STATE_HOME/infinitus/attachments` (Linux tray parity) —
    /// same base as `MirrorExporter.url` / `TrayMirror.stateDir`.
    public static var defaultAttachmentsDir: URL {
        #if canImport(Glibc)
        return MirrorWriter.linuxStateDir(env: ProcessInfo.processInfo.environment,
                                          home: NSHomeDirectory())
            .appendingPathComponent("attachments")
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
            .appendingPathComponent("Infinitus/attachments")
        #endif
    }

    private static func mimeExtension(_ mime: String) -> String? {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/heic": return "heic"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "text/plain": return "txt"
        case "application/pdf": return "pdf"
        default: return nil
        }
    }

    private static let allowedNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    /// Strips everything outside `[A-Za-z0-9._-]` and, when the result has
    /// no extension, appends one derived from the mime type.
    static func sanitizedAttachmentName(_ raw: String, mime: String) -> String {
        var cleaned = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { allowedNameCharacters.contains($0) }))
        if cleaned.isEmpty { cleaned = "attachment" }
        if !cleaned.contains("."), let ext = mimeExtension(mime) {
            cleaned += ".\(ext)"
        }
        return cleaned
    }

    /// `nil` when every attachment is within the caps; a rejection detail
    /// otherwise. `nil` attachments/empty array is always fine.
    static func attachmentRejection(_ attachments: [Attachment]?) -> String? {
        guard let attachments, !attachments.isEmpty else { return nil }
        guard attachments.count <= maxAttachments else { return "too many attachments" }
        for attachment in attachments {
            guard attachment.data.count <= maxAttachmentBytes else {
                return "attachment too large"
            }
            guard allowedAttachmentMimes.contains(attachment.mime) else {
                return "unsupported attachment type"
            }
        }
        return nil
    }

    /// Delivers one phone-sent input: a message to the session's peer
    /// socket (its terminal when there is none), a key into its terminal
    /// — the send side of layer 1's read-only feed. `hosts`/`claudeDir` come from the same `PtyHosts.available()`
    /// / `ClaudeSessions.configHome()` call `ResumeService` makes.
    public static func deliver(
        request: Request,
        record: ClaudeSessionRecord,
        hosts: [any PtyHost],
        claudeDir: URL,
        attachmentsDir: URL = SessionInput.defaultAttachmentsDir,
        ttyOfPid: (Int32) -> String? = ProcessFacts.tty(of:),
        ancestorsOf: (Int32) -> [Int32] = ProcessFacts.ancestors(of:),
        socketSend: (ClaudeSessionRecord, String) -> Bool = { record, text in
            PeerSocket.send(socketPath: record.messagingSocketPath, text: text,
                            pid: record.pid, claudeDir: ClaudeSessions.configHome())
        },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Reply {
        let tty = ttyOfPid(record.pid)
        let ancestors = ancestorsOf(record.pid)

        switch request.kind {
        case .mode:
            // The app's own state (#163 phase 2); nothing to type.
            return Reply(outcome: "rejected", detail: "a mode change is handled by the app, not delivered")
        case .approve:
            // The rule itself is the app's to keep; here it is a Yes.
            return deliver(request: Request(kind: .key, text: "1"), record: record,
                           hosts: hosts, claudeDir: claudeDir, attachmentsDir: attachmentsDir,
                           ttyOfPid: ttyOfPid, ancestorsOf: ancestorsOf, socketSend: socketSend,
                           sleep: sleep)
        case .resume:
            // The message path, with the Mac's own text: socket first,
            // terminal fallback, the same outcomes.
            return deliver(request: Request(kind: .message, text: continueText()), record: record,
                           hosts: hosts, claudeDir: claudeDir, attachmentsDir: attachmentsDir,
                           ttyOfPid: ttyOfPid, ancestorsOf: ancestorsOf, socketSend: socketSend,
                           sleep: sleep)
        case .key:
            guard allowedKeys.contains(request.text) else {
                return Reply(outcome: "rejected", detail: "unsupported key")
            }
            for host in hosts {
                switch PtyNudge.press(host: host, pid: record.pid, key: request.text,
                                      tty: tty, ancestors: ancestors, name: record.name, sleep: sleep) {
                case .delivered, .typedUnverified:
                    return Reply(outcome: "delivered", channel: "pty")
                case .running:
                    return Reply(outcome: "running")
                case .capturedInput, .noSurface:
                    continue
                }
            }
            return Reply(outcome: "noSurface")

        case .message:
            if let rejection = attachmentRejection(request.attachments) {
                return Reply(outcome: "rejected", detail: rejection)
            }
            let attachments = request.attachments ?? []
            let hasAttachments = !attachments.isEmpty
            if !request.text.isEmpty, !isValidMessage(request.text) {
                return Reply(outcome: "rejected", detail: "invalid message")
            }
            guard hasAttachments || !request.text.isEmpty else {
                return Reply(outcome: "rejected", detail: "invalid message")
            }

            var deliveredText = request.text.isEmpty
                ? "Please look at the attached file(s):" : request.text
            if hasAttachments {
                guard (try? FileManager.default.createDirectory(
                    at: attachmentsDir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])) != nil else {
                    return Reply(outcome: "rejected", detail: "couldn't prepare attachments directory")
                }
                var paths: [String] = []
                for attachment in attachments {
                    let safeName = sanitizedAttachmentName(attachment.name, mime: attachment.mime)
                    let fileURL = attachmentsDir
                        .appendingPathComponent("\(UUID().uuidString)-\(safeName)")
                    guard (try? attachment.data.write(to: fileURL, options: .atomic)) != nil else {
                        return Reply(outcome: "rejected", detail: "couldn't save attachment")
                    }
                    paths.append(fileURL.path)
                }
                deliveredText += "\n\n[attached: \(paths.joined(separator: ", "))]"
            }
            // Claude Code's own inbox first — a message, line breaks kept,
            // rather than keystrokes (user 2026-09-03). The terminal is
            // the fallback for a record without a socket or a dead one.
            // The Mac's own texts (Continue) carry their "[Infinitus]"
            // marker already; a phone message gets the preface.
            let framed = deliveredText.hasPrefix("[Infinitus]")
                ? deliveredText : PeerSocket.phonePreface + deliveredText
            if !record.messagingSocketPath.isEmpty, socketSend(record, framed) {
                return Reply(outcome: "delivered", channel: "socket")
            }
            var sawRunning = false
            var sawCaptured = false
            // A terminal submits on every newline: one typed line.
            let typed = deliveredText.split(separator: "\n", omittingEmptySubsequences: true)
                .joined(separator: " ")
            for host in hosts {
                switch PtyNudge.nudge(host: host, pid: record.pid, text: typed,
                                      tty: tty, ancestors: ancestors, name: record.name, sleep: sleep) {
                case .delivered, .typedUnverified:
                    return Reply(outcome: "delivered", channel: "pty")
                case .running:
                    sawRunning = true
                case .capturedInput:
                    sawCaptured = true
                case .noSurface:
                    continue
                }
            }
            if sawRunning { return Reply(outcome: "running") }
            if sawCaptured { return Reply(outcome: "captured") }
            // No surface anywhere and no socket to try either — there is
            // simply no way into this session, distinct from "there's a
            // terminal but it wouldn't take input".
            if record.messagingSocketPath.isEmpty { return Reply(outcome: "noChannel") }
            return Reply(outcome: "noSurface")
        }
    }
}
#endif
