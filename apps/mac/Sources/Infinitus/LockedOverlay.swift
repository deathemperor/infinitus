import SwiftUI

/// Wraps a surface (the pop-out body, the Settings shell): the content
/// while unlocked, the locked state otherwise (spec §2.2). The swap is a
/// wholesale content-shape change; LockModel mutates inside withAnimation
/// so the panels glide to the new size.
struct LockGate<Content: View>: View {
    @ObservedObject var lock: LockModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        if lock.policy.needsUnlock {
            LockedView(lock: lock)
        } else {
            content()
        }
    }
}

/// Static on purpose — no spinner, no motion: a locked pop-out left open
/// must idle at 0% like an unlocked one. Busy = the button is disabled.
struct LockedView: View {
    @ObservedObject var lock: LockModel
    @State private var busy = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: BiometricLock.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Infinitus is locked")
                .font(.headline)
            Button {
                busy = true
                Task {
                    await lock.unlock()
                    busy = false
                }
            } label: {
                Text("Unlock with \(BiometricLock.methodName)")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(busy)
            if let err = lock.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(28)
        .frame(minWidth: 260)
        // Centered in a big Settings window; under the pop-out's
        // fixedSize this collapses to the ideal size.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
