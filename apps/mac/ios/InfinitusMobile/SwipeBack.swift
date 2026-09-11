import SwiftUI
import UIKit

/// Swipe back from anywhere on the screen, not only the left edge (user
/// 2026-09-05 from the phone: "I cant swipe left the chat to go back,
/// must swipe from edge"). A pan recognizer on the screen's view drives
/// the navigation controller's own pop transition — the same targets
/// the edge gesture fires — so the pop animates and cancels like the
/// system one. Begins only on a rightward, mostly horizontal drag with
/// something to pop, so the feed's vertical scroll keeps its gestures.
struct SwipeBackAnywhere: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Installer { Installer() }
    func updateUIViewController(_ controller: Installer, context: Context) {}

    final class Installer: UIViewController, UIGestureRecognizerDelegate {
        private var installed = false

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        private func install() {
            guard !installed,
                  let nav = navigationController,
                  let edge = nav.interactivePopGestureRecognizer,
                  let targets = edge.value(forKey: "targets") as? NSMutableArray,
                  let screen = parent?.view else { return }
            let pan = UIPanGestureRecognizer()
            pan.setValue(targets, forKey: "targets")
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            screen.addGestureRecognizer(pan)
            installed = true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer,
                  let nav = navigationController, nav.viewControllers.count > 1,
                  nav.transitionCoordinator == nil else { return false }
            let v = pan.velocity(in: pan.view)
            return v.x > 0 && abs(v.x) > abs(v.y) * 1.5
        }
    }
}
