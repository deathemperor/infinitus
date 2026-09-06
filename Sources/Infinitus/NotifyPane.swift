import SwiftUI
import InfinitusCore

/// Away-push channel settings (backlog item 7): the GUI face of
/// `cswap notify`. Secrets go to the CLI over STDIN (`notify slack -`) —
/// never argv — and only ever come back masked (`notify --json`), so the
/// raw webhook/token exists in this process exactly as long as the draft
/// fields hold it.
@MainActor
final class NotifyModel: ObservableObject {
    @Published var slackStatus: String?      // masked, nil = unset
    @Published var telegramStatus: String?   // masked token
    @Published var telegramChat: String?
    @Published var webhookDraft = ""
    @Published var tokenDraft = ""
    @Published var chatIdDraft = ""
    @Published var message: String?
    @Published var errorText: String?

    let cli: CswapCLI?
    init(cli: CswapCLI?) { self.cli = cli }

    func load() async {
        guard let cli else { return }
        do {
            let status = try await cli.notifyStatus()
            slackStatus = status.slackWebhookUrl
            telegramStatus = status.telegramBotToken
            telegramChat = status.telegramChatId
            errorText = nil
        } catch { errorText = EngineFailure.sentence(error) }
    }

    func saveSlack() {
        let url = webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("https://") else {
            errorText = "Webhook URL must start with https://"
            return
        }
        run(["notify", "slack", "-"], stdin: url, done: "Slack webhook saved") {
            self.webhookDraft = ""
        }
    }

    func saveTelegram() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = chatIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !chat.isEmpty else {
            errorText = "Telegram needs both a bot token and a chat ID."
            return
        }
        run(["notify", "telegram", "-", chat], stdin: token, done: "Telegram bot saved") {
            self.tokenDraft = ""
            self.chatIdDraft = ""
        }
    }

    func remove(_ channel: String) {
        run(["notify", "off", channel], stdin: nil, done: "Removed \(channel)") {}
    }

    func test() {
        guard let cli else { return }
        message = "Testing…"
        errorText = nil
        Task {
            do {
                let out = try await cli.run(["notify", "test"])
                message = String(decoding: out, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                message = nil
                errorText = "Test push failed — check the channel config"
            }
        }
    }

    private func run(
        _ args: [String], stdin: String?, done: String,
        cleared: @escaping () -> Void
    ) {
        guard let cli else { return }
        errorText = nil
        Task {
            do {
                _ = try await cli.run(args, stdin: stdin)
                cleared()
                message = done
                await load()
            } catch { errorText = EngineFailure.sentence(error) }
        }
    }
}

struct NotifyPane: View {
    @ObservedObject var model: NotifyModel
    @ObservedObject var app: AppModel

    /// "slack" or "telegram" while its Remove is being confirmed.
    @State private var confirmRemove: String?

    var body: some View {
        Form {
            Section {
                Toggle("All sessions finish working", isOn: $app.pushSessionsDone)
                Toggle("A session waits on you", isOn: $app.pushWaiting)
                Toggle("A session needs an AWS sign-in", isOn: $app.pushAwsLogin)
            } header: {
                Text("Push about sessions")
            } footer: {
                Text("Finish: one push when every live session has been idle for two "
                     + "refresh passes after at least \(Int(PushTriggers.sessionsDoneMinBusy / 60)) minutes "
                     + "of work \u{2014} turn gaps and short bursts don't count. Waits on you: one "
                     + "push per session when it stops at a permission prompt or a "
                     + "question. AWS: one push per session and profile when a command "
                     + "fails on an expired sign-in \u{2014} sign in from the phone's "
                     + "sessions list.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Toggle("All accounts are exhausted", isOn: $app.pushAllDead)
                Toggle("The last alive account nears its limit", isOn: $app.pushLastAlive)
                Toggle("An account comes back", isOn: $app.pushRevived)
                Stepper(value: $app.reviveLeadMinutes, in: 1...120) {
                    Text("Revive countdown lead: \(app.reviveLeadMinutes) min")
                }
            } header: {
                Text("Push about accounts")
            } footer: {
                Text("Every switch is pushed already. Last alive: one push when only one "
                     + "account still has quota and it crosses \(Int(PushTriggers.warnPct))%. "
                     + "Comes back: when an exhausted account's windows reset, named, and "
                     + "flagged when Anthropic reset it before the advertised time. The "
                     + "countdown lead is how far ahead of an exhausted account's reset its "
                     + "row starts counting down live and the phone's reset alarm fires.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") {
                    StatusDot(on: model.slackStatus != nil,
                              text: model.slackStatus ?? "Not Set Up")
                }
                LabeledContent("Webhook URL") {
                    SecureField("https://hooks.slack.com/\u{2026}", text: $model.webhookDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveSlack() }
                }
                HStack {
                    Button("Save Webhook") { model.saveSlack() }
                        .disabled(model.webhookDraft.isEmpty)
                    if model.slackStatus != nil {
                        Button("Remove\u{2026}", role: .destructive) { confirmRemove = "slack" }
                    }
                }
            } header: {
                Text("Slack")
            } footer: {
                Text("Infinitus posts to the incoming webhook you paste here. The URL is "
                     + "stored on this Mac, readable only by you, and shown masked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") {
                    StatusDot(on: model.telegramStatus != nil,
                              text: model.telegramStatus.map {
                                  "\($0)  chat \(model.telegramChat ?? "?")"
                              } ?? "Not Set Up")
                }
                LabeledContent("Bot token") {
                    SecureField("the token BotFather gave you", text: $model.tokenDraft)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Chat ID") {
                    TextField("-1001234567890", text: $model.chatIdDraft)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Save Bot") { model.saveTelegram() }
                        .disabled(model.tokenDraft.isEmpty || model.chatIdDraft.isEmpty)
                    if model.telegramStatus != nil {
                        Button("Remove\u{2026}", role: .destructive) { confirmRemove = "telegram" }
                    }
                }
            } header: {
                Text("Telegram")
            } footer: {
                Text("The bot posts into the chat whose ID you give it. Both are stored on "
                     + "this Mac, readable only by you, and shown masked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Button("Send Test Push") { model.test() }
                    .disabled(model.slackStatus == nil && model.telegramStatus == nil
                              && model.webhookDraft.isEmpty)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let err = model.errorText {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Sends one push to every channel above, so you can check it arrives "
                     + "on the phone before it matters.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(confirmRemove == "slack" ? "Remove the Slack webhook?"
                                                     : "Remove the Telegram bot?",
                            isPresented: Binding(get: { confirmRemove != nil },
                                                 set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { channel in
            Button("Remove", role: .destructive) {
                model.remove(channel)
                confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: { channel in
            Text(channel == "slack"
                 ? "Away pushes stop going to Slack. The webhook itself keeps working "
                   + "\u{2014} you can paste it back any time."
                 : "Away pushes stop going to Telegram. The bot and the chat are "
                   + "untouched \u{2014} you can paste the token back any time.")
        }
        .task { await model.load() }
    }
}

/// Binary status the way Team and Devices already draw it: a coloured
/// dot and a word. Push showed a grey "no" (the critique's "pick one").
private struct StatusDot: View {
    let on: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
