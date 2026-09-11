import SwiftUI
import UIKit

/// Keeps the edge-swipe back gesture on a screen that hides the
/// navigation bar for a header of its own: UIKit drops the gesture with
/// the bar, and clearing the recognizer's delegate restores it. The
/// original delegate comes back when the screen leaves, so the root
/// screen never gets a pop gesture with nothing to pop.
struct InteractivePopGesture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var saved: UIGestureRecognizerDelegate?
        private var swapped = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !swapped, let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            saved = recognizer.delegate
            recognizer.delegate = nil
            recognizer.isEnabled = true
            swapped = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard swapped, let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            recognizer.delegate = saved
            swapped = false
        }
    }
}
