import SwiftUI
import InfinitusCore

/// All-limited banner (todo 2026-09-01): names the first account
/// to recover with a live one-second countdown, and counts the
/// limit-stopped sessions waiting to be resumed. Rides the error
/// slot so every layout carries it without four insert sites — and
/// the #7 battle plan line rides along with it for the same reason.
public struct AllDeadBanner<M: FleetModel>: View {
    @ObservedObject var model: M

    public init(model: M) {
        self.model = model
    }

    @ViewBuilder public var body: some View {
        allDeadLine
        AwsLoginLine(model: model)
        UsageForecastLine(model: model)
        BattlePlanLine(model: model)
    }

    @ViewBuilder private var allDeadLine: some View {
        if model.nextCandidate == nil, let rec = model.nextRecovery,
           let date = WeeklyRoll.parse(rec.at) {
            let name = model.accounts.first { $0.number == rec.number }
                .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) }
                ?? "#\(rec.number)"
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                (Text(Image(systemName: "arrowtriangle.right"))
                    .foregroundStyle(.orange)
                 + Text(" All accounts limited — \(name) recovers in ")
                 + Text(RecoveryCountdown.label(until: date, now: ctx.date))
                    .bold().monospacedDigit().foregroundStyle(.orange)
                 + Text(waitingResumeSuffix))
                    .font(PopupFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var waitingResumeSuffix: String {
        guard let waiting = model.waitingResume else { return "" }
        return " · \(waiting) session\(waiting == 1 ? "" : "s") waiting to resume"
    }
}
