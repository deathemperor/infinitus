import Foundation
import InfinitusCore

/// The last 50 team-control audit lines (#220 §6), for Settings › Team.
/// Its own small observable so the pane does not re-render on every
/// AppModel change.
@MainActor
final class TeamControlFeed: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let at = Date()
        let driver: String
        let session: String
        let action: String
        let outcome: String
        let detail: String?
        var text: String {
            let why = detail.map { " — \($0)" } ?? ""
            return "\(driver) · \(action) · \(session) · \(outcome)\(why)"
        }
    }
    @Published private(set) var lines: [Line] = []

    func append(_ line: Line) {
        lines.append(line)
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
    }

    /// A verified command waiting for the grantor's tap (#220 Phase 2 §4).
    /// The pane must never receive `TeamControl.PendingCommand` — its
    /// `command.text` is prompt text — so this is the type boundary.
    struct Pending: Identifiable, Equatable {
        let id: String        // the command id, what team-allow/deny take
        let driver: String    // the roster name, else the kid's first 8 chars
        let project: String   // the session's cwd basename, "this Mac" for a machine-scoped action
        let action: String
        let expires: Date
    }
    @Published private(set) var pending: [Pending] = []
    var decide: ((_ id: String, _ allow: Bool) -> Void)?

    func setPending(_ rows: [Pending]) {
        pending = rows.sorted { $0.expires < $1.expires }
    }
}
