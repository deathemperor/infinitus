import Foundation

// MARK: - Control dispatch (the Linux tray's side of the wire, #486 slice 3)
//
// The Mac answers the control socket from `ControlServer`, whose every
// command runs through AppModel on the main actor. The tray has no model
// and no run loop to speak of: what it answers is this pure function —
// request in, reply out, the handlers doing the only work there is. That
// keeps the tray's routing testable without a socket (the socket itself
// is `PosixControlSocket`, Linux-only plumbing) and keeps the wire
// exactly Core's `ControlRequest`/`ControlReply`, one JSON line each way.

public enum ControlDispatch {
    /// What the caller (the tray) can actually do for a command.
    public struct Handlers: Sendable {
        /// `UserPromptSubmit` with a cwd and a session id: record a
        /// workspace checkpoint. Called synchronously from here — the
        /// caller hands the git work to its own queue, the way
        /// `AppModel.recordCheckpoint` detaches it.
        public var checkpoint: @Sendable (_ cwd: String, _ sessionId: String, _ subject: String) -> Void
        /// `status`'s result: what this frontend is and how much it sees.
        public var status: @Sendable () -> JSONValue
        /// A hook's session id to the pid of the live session it names —
        /// the Mac's lookup (#486); nil when the caller has none.
        public var sessionPid: @Sendable (_ sessionId: String) -> Int?
        /// Every parsed hook, with its pid when known: the caller decides
        /// what to push (a Notification's `pushLine`) — after the
        /// checkpoint, before the reply.
        public var hook: @Sendable (_ event: HookEvent, _ pid: Int?) -> Void

        public init(checkpoint: @Sendable @escaping (String, String, String) -> Void,
                    status: @Sendable @escaping () -> JSONValue,
                    sessionPid: @Sendable @escaping (String) -> Int? = { _ in nil },
                    hook: @Sendable @escaping (HookEvent, Int?) -> Void = { _, _ in }) {
            self.checkpoint = checkpoint
            self.status = status
            self.sessionPid = sessionPid
            self.hook = hook
        }
    }

    /// Anything the tray does not answer this slice gets a considered
    /// "not yet" rather than a crash or a silent success.
    public static func unsupportedMessage(_ command: String) -> String {
        "\(command) is not available on Linux yet"
    }

    public static func reply(to request: ControlRequest, handlers: Handlers) -> ControlReply {
        switch request.command {
        case "status":
            return ControlReply(ok: true, result: handlers.status())

        case "event":
            // Same contract as the Mac's `case "event"`: the payload rides
            // in `secret` because the CLI reads it from stdin, never argv.
            guard let payload = request.secret, let event = HookEvent.parse(payload) else {
                return .failure("event: a Claude Code hook payload (JSON with hook_event_name) is expected on stdin")
            }
            let pid = event.sessionId.flatMap(handlers.sessionPid)
            if event.name == "UserPromptSubmit", let cwd = event.cwd, let sessionId = event.sessionId {
                handlers.checkpoint(cwd, sessionId, event.prompt ?? "")
            }
            // Every hook reaches the caller (a Notification is its push);
            // whatever it does, a hook never sees a failure it would retry.
            handlers.hook(event, pid)
            return ControlReply(ok: true, result: .object(["pid": pid.map { .number(Double($0)) } ?? .null]))

        default:
            return .failure(unsupportedMessage(request.command))
        }
    }

    /// One request line in, one reply line out — what the socket's read
    /// loop hands over. Undecodable bytes are a failed reply, not a
    /// dropped connection: the CLI must always get its line back.
    public static func replyLine(to line: Data, handlers: Handlers) -> Data {
        let reply: ControlReply
        if let request = try? ControlCodec.decode(ControlRequest.self, from: line) {
            reply = self.reply(to: request, handlers: handlers)
        } else {
            reply = .failure("control: expected one JSON ControlRequest line")
        }
        guard let encoded = try? ControlCodec.encode(reply) else {
            // ControlReply always encodes; a belt so the caller has bytes.
            return Data("{\"schemaVersion\":\(ControlProtocol.schemaVersion),\"ok\":false,\"error\":\"control: reply could not be encoded\"}\n".utf8)
        }
        return encoded
    }
}
