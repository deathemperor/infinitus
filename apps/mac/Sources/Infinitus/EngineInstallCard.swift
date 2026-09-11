import InfinitusCore
import InfinitusUI
import SwiftUI

/// The first-run card's "Install engine" block (#871).
///
/// A fresh Mac has the app and no engine; before this the card printed two
/// commands and left the user in a terminal. The button runs the same two
/// commands — Rust when it is missing, then the engine — and ends in a
/// relaunch, because the binary is resolved once at launch.
struct EngineInstallSection: View {
    @ObservedObject var model: AppModel
    @StateObject private var runner = EngineInstallRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch runner.state {
            case .idle:
                Button("Install engine") { runner.start() }
                    .font(PopupFont.caption)
                caption("Infinitus installs Rust if it is missing, then builds swapd. "
                        + "That takes 5–10 minutes; you can keep working.")
                manualLine
            case .blocked(let blocker):
                caption(blocker.message)
                manualLine
            case .running(let step, let line):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(step.title) — \(step.estimate)")
                        .font(.caption)
                }
                Text(line ?? "Starting…")
                    .font(.caption).monospaced()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: onboardingTextWidth, alignment: .leading)
                Button("Stop") { runner.cancel() }
                    .font(PopupFont.caption)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: onboardingTextWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Try again") { runner.start() }
                    .font(PopupFont.caption)
                manualLine
            case .installed(let path):
                caption("Engine installed at \(path). Relaunch Infinitus to pick it up, "
                        + "then add your first account.")
                Button("Relaunch Infinitus") { model.relaunchApp() }
                    .font(PopupFont.caption)
            }
        }
    }

    /// The commands themselves stay on screen: a user who would rather type
    /// them, or who has to debug a failure, should not have to find them.
    private var manualLine: some View {
        Text("Or install it yourself:  \(OnboardingBrief.swapdInstallCommand)")
            .font(.caption).monospaced()
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(width: onboardingTextWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: onboardingTextWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
