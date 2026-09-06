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
        } catch { errorText = "\(error)" }
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
            errorText = "Telegram needs both a bot token and a chat id"
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
            } catch { errorText = "\(error)" }
        }
    }
}

struct NotifyPane: View {
    @ObservedObject var model: NotifyModel
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section("Away push — tells your phone which account is live") {
                Text("After every switch, cswap pushes the new account's "
                     + "alias to each channel below. Secrets are stored in "
                     + "notify.json (owner-only) and shown masked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Also push when") {
                Toggle("All sessions finish working", isOn: $app.pushSessionsDone)
                    .help("Fires once when every live Claude Code session "
                          + "has been idle for two refresh passes — turn "
                          + "gaps don't count.")
                Toggle("All accounts are exhausted", isOn: $app.pushAllDead)
                Toggle("The last alive account nears its limit",
                       isOn: $app.pushLastAlive)
                    .help("Warns once when only one account still has "
                          + "quota and it crosses \(Int(PushTriggers.warnPct))%.")
                Toggle("A session waits on you", isOn: $app.pushWaiting)
                    .help("Fires once per session when it stops at a "
                          + "permission prompt or a question — answer it "
                          + "from the phone's session feed.")
                Toggle("A session needs an AWS login", isOn: $app.pushAwsLogin)
                Toggle("An account comes back", isOn: $app.pushRevived)
                    .help("A limited account's windows reset — named, and flagged "
                          + "when Anthropic reset it before the advertised time.")
                    .help("Fires once per session and profile when an aws "
                          + "command fails on an expired sign-in — sign in "
                          + "from the phone's sessions list.")
                Stepper(value: $app.reviveLeadMinutes, in: 1...120) {
                    Text("Revive countdown lead: \(app.reviveLeadMinutes) min")
                }
                    .help("How far ahead of an exhausted account's reset its row "
                          + "starts a live countdown and the phone's reset alarm fires.")
            }
            Section("Slack") {
                LabeledContent("Configured", value: model.slackStatus ?? "no")
                SecureField("Incoming webhook URL (https://hooks.slack.com/…)",
                            text: $model.webhookDraft)
                    .onSubmit { model.saveSlack() }
                HStack {
                    Button("Save webhook") { model.saveSlack() }
                        .disabled(model.webhookDraft.isEmpty)
                    if model.slackStatus != nil {
                        Button("Remove", role: .destructive) { model.remove("slack") }
                    }
                }
            }
            Section("Telegram") {
                LabeledContent("Configured") {
                    Text(model.telegramStatus.map {
                        "\($0)  chat \(model.telegramChat ?? "?")"
                    } ?? "no")
                }
                SecureField("Bot token", text: $model.tokenDraft)
                TextField("Chat id", text: $model.chatIdDraft)
                HStack {
                    Button("Save bot") { model.saveTelegram() }
                        .disabled(model.tokenDraft.isEmpty || model.chatIdDraft.isEmpty)
                    if model.telegramStatus != nil {
                        Button("Remove", role: .destructive) { model.remove("telegram") }
                    }
                }
            }
            Section {
                Button("Send test push") { model.test() }
                    .disabled(model.slackStatus == nil && model.telegramStatus == nil
                              && model.webhookDraft.isEmpty)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let err = model.errorText {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}
