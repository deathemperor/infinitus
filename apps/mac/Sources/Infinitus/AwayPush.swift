import Foundation
import InfinitusCore

/// The Mac's own away channels (#756): every push the app raises for the
/// phone also goes to a Slack webhook and/or a Telegram bot when one is
/// stored. Secrets live in the keychain under one service, never in
/// defaults; the chat id is not a secret and sits in defaults.
@MainActor
final class AwayPush {
    /// One keychain per Mac: a dev or e2e instance (its own defaults
    /// suite, #690) gets its own slot, so a fixture's simulated pushes never
    /// reach the user's real channels and its forget never deletes them.
    static let service: String = {
        let base = "run.infinitus.away-push"
        if let suite = ProcessInfo.processInfo.environment["INFINITUS_DEFAULTS_SUITE"], !suite.isEmpty {
            return base + "." + suite
        }
        return base
    }()
    static let slackAccount = "slack-webhook"
    static let telegramAccount = "telegram-bot"
    static let chatKey = "away_telegram_chat"

    /// Set by AppModel so a refused post lands in the Activity log.
    var log: ((String, String) -> Void)?
    private let defaults: UserDefaults
    private var failed: Set<String> = []

    init(defaults: UserDefaults) { self.defaults = defaults }

    var slackConfigured: Bool { Keychain.exists(account: Self.slackAccount, service: Self.service) }
    var telegramConfigured: Bool { Keychain.exists(account: Self.telegramAccount, service: Self.service) }
    var telegramChat: String { defaults.string(forKey: Self.chatKey) ?? "" }

    /// The masked tail for Settings; nil when nothing is stored.
    var slackLabel: String? { Keychain.read(account: Self.slackAccount, service: Self.service).map(AwayPushWire.masked) }
    var telegramLabel: String? { Keychain.read(account: Self.telegramAccount, service: Self.service).map(AwayPushWire.masked) }

    /// Empty forgets. Returns the refusal, nil when stored.
    @discardableResult
    func setSlack(_ webhook: String) -> String? {
        let trimmed = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: Self.slackAccount, service: Self.service); return nil }
        guard let url = AwayPushWire.slackWebhook(trimmed) else { return "the Slack webhook must be an https URL" }
        guard Keychain.write(account: Self.slackAccount, value: url.absoluteString, service: Self.service) else {
            return "the keychain refused the webhook"
        }
        failed.remove("slack")
        return nil
    }

    @discardableResult
    func setTelegram(token: String, chat: String) -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            Keychain.delete(account: Self.telegramAccount, service: Self.service)
            defaults.removeObject(forKey: Self.chatKey)
            return nil
        }
        guard AwayPushWire.tokenLooksRight(token) else { return "that is not a Telegram bot token (123456:ABC…)" }
        guard AwayPushWire.chatLooksRight(chat) else { return "the Telegram chat is a number or an @channel" }
        guard Keychain.write(account: Self.telegramAccount, value: token, service: Self.service) else {
            return "the keychain refused the token"
        }
        defaults.set(chat, forKey: Self.chatKey)
        failed.remove("telegram")
        return nil
    }

    /// Fire and forget; a channel's first failure is logged once until it
    /// is set again, so a dead webhook never floods the log.
    /// `slack: false` leaves the Slack webhook out of this one send
    /// (#574); Telegram is untouched.
    func send(_ text: String, slack: Bool = true) {
        var requests: [(String, URLRequest)] = []
        if slack, let hook = Keychain.read(account: Self.slackAccount, service: Self.service),
           let url = AwayPushWire.slackWebhook(hook) {
            requests.append(("slack", AwayPushWire.slackRequest(webhook: url, text: text)))
        }
        if let token = Keychain.read(account: Self.telegramAccount, service: Self.service),
           let request = AwayPushWire.telegramRequest(token: token, chat: telegramChat, text: text) {
            requests.append(("telegram", request))
        }
        for (channel, request) in requests {
            Task { [weak self] in
                let outcome: String?
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    outcome = (200..<300).contains(code) ? nil : "HTTP \(code)"
                } catch {
                    outcome = error.localizedDescription
                }
                guard let outcome else { return }
                await MainActor.run { self?.failed(channel, outcome) }
            }
        }
    }

    private func failed(_ channel: String, _ why: String) {
        guard failed.insert(channel).inserted else { return }
        log?("⚠️", "\(channel) push refused: \(why)")
    }
}
