import SwiftUI
import InfinitusCore

/// What the app pushes to the phone (#9): session and account
/// triggers — and, since the engine's own channels went with cswap
/// (#756), the Slack webhook and Telegram bot the Mac posts them to.
struct NotifyPane: View {
    @ObservedObject var app: AppModel
    @State private var slackField = ""
    @State private var telegramToken = ""
    @State private var telegramChat = ""
    @State private var slackLabel: String?
    @State private var telegramLabel: String?
    @State private var awayError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Slack") {
                    HStack {
                        SecureField(slackLabel.map { "stored \($0)" } ?? "incoming webhook URL", text: $slackField)
                            .textFieldStyle(.roundedBorder).frame(minWidth: 220)
                        Button(slackField.isEmpty ? "Forget" : "Save") {
                            awayError = app.awayPush.setSlack(slackField)
                            slackField = ""; reloadAway()
                        }.disabled(slackField.isEmpty && slackLabel == nil)
                    }
                }
                LabeledContent("Telegram") {
                    HStack {
                        SecureField(telegramLabel.map { "stored \($0)" } ?? "bot token", text: $telegramToken)
                            .textFieldStyle(.roundedBorder).frame(minWidth: 140)
                        TextField("chat id", text: $telegramChat)
                            .textFieldStyle(.roundedBorder).frame(width: 110)
                        Button(telegramToken.isEmpty ? "Forget" : "Save") {
                            awayError = app.awayPush.setTelegram(token: telegramToken, chat: telegramChat)
                            telegramToken = ""; reloadAway()
                        }.disabled(telegramToken.isEmpty && telegramLabel == nil)
                    }
                }
                if let awayError {
                    Text(awayError).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Also post to")
            } footer: {
                Text("Every push below also goes to these when set. Secrets stay in the keychain "
                     + "and show masked; `infinitusctl push-slack` / `push-telegram --chat` take them on stdin.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .onAppear(perform: reloadAway)
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
        }
        .formStyle(.grouped)
    }

    private func reloadAway() {
        slackLabel = app.awayPush.slackLabel
        telegramLabel = app.awayPush.telegramLabel
        if telegramChat.isEmpty { telegramChat = app.awayPush.telegramChat }
    }
}
