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
        /// `status`'s result: what this frontend is and how much it sees.
        public var status: @Sendable () -> JSONValue

        public init(status: @Sendable @escaping () -> JSONValue) {
            self.status = status
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
