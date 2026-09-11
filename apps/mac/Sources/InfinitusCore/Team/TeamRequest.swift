import Foundation
import Crypto

/// `requests/<kid>.json` (spec §6.2/6.3): a joiner's keys and name,
/// stored as `Signed<TeamRequest>` by the joiner. `proof` binds the
/// invite's nonce to THIS requester (#161): the leader recomputes it per
/// stored nonce; a copied proof under another kid never matches, and the
/// nonce itself never leaves the invite link. nil for team-code requests.
public struct TeamRequest: Codable, Equatable, Sendable {
    public var keys: TeamKeys
    public var name: String
    public var devices: [String]
    public var platform: String
    public var at: Int
    public var proof: String?

    public init(keys: TeamKeys, name: String, devices: [String], platform: String, at: Int, proof: String? = nil) {
        self.keys = keys; self.name = name; self.devices = devices
        self.platform = platform; self.at = at; self.proof = proof
    }

    static let proofDomain = Data("infinitus-invite-v1".utf8)

    /// base64(SHA256(domain ‖ nonce ‖ 0x00 ‖ kid)) — the separator keeps
    /// (nonce, kid) pairs from colliding by concatenation.
    public static func proof(nonce: String, kid: String) -> String {
        var input = proofDomain
        input.append(contentsOf: Data(nonce.utf8))
        input.append(0)
        input.append(contentsOf: Data(kid.utf8))
        return Data(Crypto.SHA256.hash(data: input)).base64EncodedString()
    }
}
