import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// LocalAuthentication, thinly (spec §2.2). `.deviceOwnerAuthentication`,
/// not `…WithBiometrics`: Touch ID, an Apple Watch, or — when biometrics
/// are missing, unenrolled or fail — the account password all count, the
/// way the OS itself falls back. Nothing here is a security boundary; it
/// is the gesture the lock asks for.
enum BiometricLock {
    enum Outcome: Equatable {
        case ok
        /// The user backed out; the surfaces stay locked, nothing to show.
        case cancelled
        case failed(String)
    }

    /// "Touch ID" / "Face ID" / "password" — for toggle and button copy.
    static var methodName: String {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return "password" }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "password"
        }
        #else
        return "password"
        #endif
    }

    /// The SF Symbol for the locked state.
    static var symbol: String {
        switch methodName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        default: return "lock.fill"
        }
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
