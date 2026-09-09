import SwiftUI
import InfinitusCore

/// "🔐 banyan needs AWS login (papaya-login)" — or gcloud login (#367),
/// by the item's provider — with the state of any login in flight and a
/// button for this host's own browser flow. The phone renders the same
/// items with its Start / open URL / code field.
public struct AwsLoginLine<M: FleetModel>: View {
    @ObservedObject var model: M

    public init(model: M) {
        self.model = model
    }

    public var body: some View {
        ForEach(model.awsLogins) { item in
            HStack(spacing: 6) {
                (Text(Image(systemName: "lock.shield"))
                    .foregroundStyle(.orange)
                 + Text(" " + line(item)))
                    .font(PopupFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.state == nil || item.state?.phase == .failed {
                    Button("Log in here") {
                        model.startLogin(provider: item.providerOrAws, profile: item.profile, pid: item.pid, local: true)
                    }
                    .font(PopupFont.caption)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                    .help("Runs `\(item.providerOrAws.cliName) \(item.providerOrAws.arguments(profile: item.profile, flow: .local).joined(separator: " "))` "
                          + "on this Mac (opens your browser). Or start it from the phone and sign in there.")
                }
            }
            .fixedSize()
        }
    }

    private func line(_ item: AwsLogin.Item) -> String {
        let who = item.sessionLabel.map { "\($0) needs" } ?? "Needs"
        var text = "\(who) \(item.providerOrAws.loginLabel) (\(item.profile))"
        if let s = item.state {
            switch s.phase {
            case .starting: text += " · starting…"
            case .waitingForBrowser: text += s.flow == .local ? " · finish in the browser" : " · sign in on the phone"
            case .waitingForCode: text += " · paste the code on the phone"
            case .done: text += " · signed in ✓"
            case .failed: text += " · failed: \(s.message ?? "?")"
            }
        }
        return text
    }
}
