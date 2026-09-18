import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// LocalAuthentication, thinly (spec §2.2). `.deviceOwnerAuthentication`,
/// not `…WithBiometrics`: Touch ID, an Apple Watch, or — when biometrics
/// are missing, unenrolled or fail — the account password all count, the
/// way the OS itself falls back. Nothing here is a security boundary; it
/// is the gesture asked for before the team recovery key is shown.
enum BiometricLock {
    enum Outcome: Equatable {
        case ok
        /// The user backed out; nothing to show.
        case cancelled
        case failed(String)
    }

    /// One prompt. `reason` completes "Infinitus wants to …" in the
    /// system dialog. A fresh context per call: a reused one can answer
    /// from its own cache and skip the gesture.
    static func authenticate(reason: String) async -> Outcome {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return .failed(err?.localizedDescription ?? "authentication is unavailable on this Mac")
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .ok : .failed("not recognised")
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
        #else
        return .failed("no authentication framework on this platform")
        #endif
    }
}
