import Foundation

/// The pure half of a terminal SURFACE — what an emulator view has to decide
/// once it is holding Core's `T3Terminal` frames (#507). Two rules, both
/// upstream's, both testable without a pty, an emulator or a window:
///
/// - the tab's title, `getTerminalLabel` (`@t3tools/shared/terminalLabels`,
///   `packages/shared/src/terminalLabels.ts:4-11` at 6c583620f);
/// - the reset/append decision and the `since` byte offset a re-attach
///   resumes from — the bookkeeping that keeps a tab switch from either
///   wiping the screen or leaving a gap in it (#507 review ruling 1).
///
/// Deliberately NOT an extension on `T3Terminal.Frame`: the phone carries a
/// `resumeSequence` of its own (`ios/InfinitusMobile/T3/T3TerminalWire.swift`),
/// and a public member of the same name would make every `frame.resumeSequence`
/// there ambiguous the day both land.
public enum T3TerminalSurface: Sendable {

    /// `getTerminalLabel`: `term-2` / `terminal-2` (either case) is
    /// "Terminal 2"; anything else is its own id, verbatim.
    public static func label(terminalId: String) -> String {
        let parts = terminalId.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return terminalId }
        let head = parts[0].lowercased()
        guard head == "term" || head == "terminal" else { return terminalId }
        let digits = parts[1]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber)
        else { return terminalId }
        return "Terminal \(digits)"
    }

    /// What the view does with one frame's text.
    public enum Step: Sendable, Equatable {
        /// A (re)connect's first `snapshot`: reset the emulator, then write this.
        case reset(String)
        /// More of the same stream: append.
        case append(String)
        /// A frame with no text for the screen (`exited`, `closed`, `error`,
        /// and the 16 KB snapshot chunks after the first one — those append,
        /// so they never reach here; an empty payload does).
        case nothing
    }

    /// One attachment's state: whether the next `snapshot` replaces the
    /// screen, and the byte offset a reconnect asks the ring to replay from.
    ///
    /// A snapshot arrives in `historyChunkLength` pieces, each carrying the
    /// status again: only the FIRST resets, or a long scrollback would erase
    /// itself down to its last chunk. `attaching()` is what re-arms that,
    /// and it must be called before the attach goes out — the host hands the
    /// opening frames to the sink synchronously inside `attach`.
    public struct Attachment: Sendable, Equatable {
        /// The `since` a re-attach passes; `nil` before the first frame.
        public private(set) var sequence: Int?
        /// Set by `attaching()`, cleared by the snapshot it lets through.
        public private(set) var awaitingSnapshot = true

        public init() {}

        /// A fresh attach (or re-attach): the next snapshot resets the screen.
        /// The sequence is kept — that IS the resume point.
        public mutating func attaching() { awaitingSnapshot = true }

        public mutating func step(_ frame: T3Terminal.Frame) -> Step {
            switch frame {
            case .snapshot(let payload):
                if let sequence = payload.sequence { self.sequence = sequence }
                let reset = awaitingSnapshot
                awaitingSnapshot = false
                guard !payload.history.isEmpty else { return reset ? .reset("") : .nothing }
                return reset ? .reset(payload.history) : .append(payload.history)
            case .output(let payload):
                sequence = payload.sequence
                // Live output can only follow a snapshot; a stream that opens
                // with a ring replay (a `since` the ring still covers) has no
                // snapshot at all and must not wait for one.
                awaitingSnapshot = false
                guard !payload.data.isEmpty else { return .nothing }
                return .append(payload.data)
            case .exited, .closed, .error:
                return .nothing
            }
        }
    }

    /// `writeSystemMessage` (`ThreadTerminalDrawer.tsx:107-109`): the surface's
    /// own lines go into the emulator, bracketed like upstream's.
    public static func systemMessage(_ message: String) -> String {
        "\r\n[terminal] \(message)\r\n"
    }

    /// The one line an exit writes (`:439`, guarded by `shouldHandleTerminalExit`
    /// at `:299-306` — once per exit, and `closed` and `exited` never both).
    public static let exitedMessage = "Process exited"
    public static let closedMessage = "Terminal closed"
}
