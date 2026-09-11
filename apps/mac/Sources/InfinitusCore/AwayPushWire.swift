import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The away channels the Mac posts its pushes to itself (#756: the
/// engine's `notify push` left with cswap): a Slack incoming webhook and
/// a Telegram bot. Pure request builders, so the wire is testable; the
/// app keeps the secrets in the keychain and sends.
public enum AwayPushWire {
    /// `https://hooks.slack.com/services/…` (any https URL is accepted —
    /// self-hosted relays exist); nil when the text is not one.
    public static func slackWebhook(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    public static func slackRequest(webhook: URL, text: String) -> URLRequest {
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        request.timeoutInterval = 15
        return request
    }

    /// `sendMessage` on the bot API; nil when the token or chat id is
    /// not the shape Telegram hands out (`123456:ABC-…`, a signed integer
    /// or an `@channel`).
    public static func telegramRequest(token: String, chat: String, text: String) -> URLRequest? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenLooksRight(token), chatLooksRight(chat),
              let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chat, "text": text])
        request.timeoutInterval = 15
        return request
    }

    public static func tokenLooksRight(_ token: String) -> Bool {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty, Int(parts[0]) != nil else { return false }
        return parts[1].unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0) }
    }

    public static func chatLooksRight(_ chat: String) -> Bool {
        if chat.hasPrefix("@") { return chat.count > 1 }
        return Int(chat) != nil
    }

    /// What settings and logs show for a stored secret: never the value.
    public static func masked(_ secret: String) -> String {
        let tail = secret.count > 8 ? String(secret.suffix(4)) : ""
        return "••••" + tail
    }
}
