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
}
