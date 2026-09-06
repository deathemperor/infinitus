import InfinitusCore
import InfinitusUI
import Intents
import UIKit

/// Sessions in the share sheet's suggestions row (#82, user 2026-09-05:
/// "each conversation is a session so that I can share anything to
/// agents"): one INSendMessageIntent donation per live session, named
/// after it, wearing the theme's glyph; the share extension declares
/// the intent and preselects the session a tapped suggestion names.
/// A session is identified by its Mac and working directory, which
/// survive a restart where the pid does not (ShareBridge.conversation).
@MainActor
enum ShareSuggestions {
    static let maxDonations = 8
    private static var donated: [String: String] = [:]   // conversation → name

    /// One paired Mac's live sessions (#144); `mac` suffixes the names
    /// once more than one Mac is paired.
    struct Source {
        let macId: String?
        let mac: String?
        let sessions: [SessionDetail]
        let name: (Int) -> String?
    }

    static func sync(_ sources: [Source], theme: RowTheme) {
        let all = sources.flatMap { source in source.sessions.map { (source, $0) } }
        var wanted: [String: String] = [:]
        for (source, session) in all.sorted(by: { $0.1.startedAt > $1.1.startedAt }).prefix(maxDonations) {
            let name = source.name(session.pid) ?? URL(fileURLWithPath: session.cwd).lastPathComponent
            wanted[ShareBridge.conversation(macId: source.macId, cwd: session.cwd)] = source.mac.map { "\(name) · \($0)" } ?? name
        }
        guard wanted != donated else { return }
        for key in donated.keys where wanted[key] == nil {
            INInteraction.delete(with: Self.group(key))
        }
        let image = glyphImage(theme)
        for (key, name) in wanted where donated[key] != name {
            let handle = INPersonHandle(value: key, type: .unknown)
            let person = INPerson(personHandle: handle, nameComponents: nil, displayName: name,
                                  image: image, contactIdentifier: nil, customIdentifier: key)
            let intent = INSendMessageIntent(recipients: [person], outgoingMessageType: .outgoingMessageText,
                                             content: nil, speakableGroupName: INSpeakableString(spokenPhrase: name),
                                             conversationIdentifier: key, serviceName: "Infinitus", sender: nil,
                                             attachments: nil)
            if let image { intent.setImage(image, forParameterNamed: \.speakableGroupName) }
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.groupIdentifier = Self.group(key)
            interaction.donate()
        }
        donated = wanted
    }

    private static func group(_ key: String) -> String { "session:" + key }

    /// The theme's glyph on its tint, 180 px — what the row shows.
    private static func glyphImage(_ theme: RowTheme) -> INImage? {
        let glyph = theme.plain ? "∞" : PopupGlyph.text(theme.activeIcon.isEmpty ? theme.sessionLabel : theme.activeIcon)
        let size = CGSize(width: 180, height: 180)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(ThemeColor.flash(theme)).withAlphaComponent(0.25).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 96)]
            let text = NSAttributedString(string: glyph, attributes: attributes)
            let bounds = text.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
        return image.pngData().map { INImage(imageData: $0) }
    }
}
