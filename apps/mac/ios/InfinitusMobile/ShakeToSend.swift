import SwiftUI
import UIKit
import InfinitusCore

/// Shake the phone on any screen: the app captures what's showing and
/// asks which session it's about (user 2026-09-04: "the capture
/// button now actually only works in sessions, what if I want to
/// capture other screens?"). The capture then opens that session's
/// chat as a pending attachment, cursor in the composer, so the request
/// can be described before it goes (user 2026-09-05: "same for whole
/// app capture").
struct ShakeToSend: View {
    @ObservedObject var model: MirrorModel
    @State private var capture: UIImage?
    @State private var asking = false

    var body: some View {
        ShakeDetector {
            guard !asking, let image = ScreenshotWatch.captureApp() else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            capture = image
            asking = true
        }
        .confirmationDialog("Attach this screen to…", isPresented: $asking, titleVisibility: .visible) {
            ForEach(sessions, id: \.pid) { session in
                Button(title(session)) { stage(in: session) }
            }
            Button("Cancel", role: .cancel) { capture = nil }
        }
    }

    private var sessions: [SessionDetail] {
        (model.liveSessions?.sessions ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    private func title(_ session: SessionDetail) -> String {
        let name = model.sessionProgress.byPid[session.pid]?.name
            ?? URL(fileURLWithPath: session.cwd).lastPathComponent
        return "\(name) · \(SessionWords.status(session.status, theme: model.rowTheme))"
    }

    private func stage(in session: SessionDetail) {
        guard let image = capture else { return }
        capture = nil
        model.stagedCapture = StagedCapture(pid: session.pid, image: image)
        model.requestedTab = "sessions"
    }
}

/// A shake, as UIKit reports it: a responder that asks to be first when
/// it appears. A focused text field keeps first responder and its own
/// shake (undo) — the composer is not where this is for.
private struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.onShake = onShake
        return c
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onShake = onShake
    }

    final class Controller: UIViewController {
        var onShake: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake?() }
            super.motionEnded(motion, with: event)
        }
    }
}
