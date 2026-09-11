import Foundation
import AppKit
import CryptoKit
#if canImport(AuthenticationServices)
import AuthenticationServices

/// Spec §2.1 passkey path: the identity secret is the PRF output of a
/// passkey for relying party `infinitus.run` under a fixed salt — nobody
/// verifies an assertion; the passkey is a synced secret-derivation
/// device, so the same passkey on the phone or a replacement Mac yields
/// the same identity. Runtime-optional: the associated-domains
/// entitlement rides a provisioning profile (make-app.sh), so
/// `isEntitled` is false in dev-signed builds and the local identity
/// stays the default. Nothing calls this yet — TeamModel wires it in
/// the next round (an "Use a passkey" choice when the identity is made,
/// and the once-per-launch unlock that fills the working-key cache).
@available(macOS 15, *)
@MainActor
final class PasskeyIdentity: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let relyingParty = "infinitus.run"
    static let salt = Data("infinitus-team-identity-v1".utf8)
    static let userName = "Infinitus identity"

    enum PasskeyError: Error { case notEntitled, unsupported, cancelled, noOutput }

    /// The signed bundle carries `com.apple.developer.associated-domains`.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.associated-domains" as CFString, nil) else { return false }
        return (value as? [String])?.contains("webcredentials:\(relyingParty)") ?? false
    }

    private var continuation: CheckedContinuation<Data, Error>?

    /// `register: true` creates the passkey (first time on this Apple
    /// account), `false` asserts the existing one; both return the
    /// 32-byte PRF output for `salt`.
    func deriveSecret(register: Bool) async throws -> Data {
        guard Self.isEntitled else { throw PasskeyError.notEntitled }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        var challenge = Data(count: 32)
        _ = challenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let request: ASAuthorizationRequest
        if register {
            let r = provider.createCredentialRegistrationRequest(challenge: challenge, name: Self.userName, userID: Data(Self.userName.utf8))
            r.prf = .inputValues(.saltInput1(Self.salt))
            request = r
        } else {
            let r = provider.createCredentialAssertionRequest(challenge: challenge)
            r.prf = .inputValues(.saltInput1(Self.salt), perCredentialInputValues: nil)
            request = r
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let key: SymmetricKey?
        if let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            key = registration.prf?.first
        } else if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            key = assertion.prf?.first
        } else {
            key = nil
        }
        guard let key else { continuation?.resume(throwing: PasskeyError.noOutput); continuation = nil; return }
        continuation?.resume(returning: key.withUnsafeBytes { Data($0) })
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let asError = error as? ASAuthorizationError
        continuation?.resume(throwing: asError?.code == .canceled ? PasskeyError.cancelled : error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
#endif
