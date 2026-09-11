import Foundation
import Crypto

/// The nonces this leader put into invite links (spec §6.2): a request
/// carrying one of them is approved without a tap, once, until the
/// invite's expiry. Team codes (§6.3) carry no nonce and always need
/// Approve. Local to the leader's machine (`<team dir>/invites.json`).
public struct TeamInvites: Codable, Equatable, Sendable {
    /// nonce → expiry (unix seconds)
    public var nonces: [String: Int] = [:]

    public init() {}

    public static func newNonce() -> String {
        Base32.encode(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
    }

    /// Mints an invite link (spec §6.2) and remembers its one-time nonce
    /// so this leader's auto-approve recognises the request it comes back
    /// as. The one path from nonce to link: the Mac pane, the CLI and a
    /// LAN invite (spec §6.4) all come through here, so the book and the
    /// link can never disagree about the expiry. `client.code` is asked
    /// for FIRST — it throws `.notALeader`/`.requestsOff` before touching
    /// anything — so a leader who can't mint right now doesn't leave a
    /// nonce nobody will ever redeem. Expired nonces are pruned on the
    /// way past — the book is a leader's local file, and this is the only
    /// thing that writes it.
    public static func mint(client: TeamClient, teamDir: URL, days: Int,
                            now: Int = Int(Date().timeIntervalSince1970)) throws -> (link: String, nonce: String) {
        let nonce = newNonce()
        let link = try client.code(expiresIn: days * 86_400, nonce: nonce, now: now)
        var book = load(teamDir: teamDir)
        book.prune(now: now)
        book.add(nonce: nonce, expires: now + days * 86_400)
        try book.save(teamDir: teamDir)
        return (link, nonce)
    }

    /// Thin wrapper for callers that only want the link (`TeamModel.mintInvite`):
    /// a caller that needs to roll the nonce back on failure should use the
    /// tuple-returning overload above instead of re-deriving it from the link.
    public static func mint(client: TeamClient, teamDir: URL, days: Int,
                            now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        try mint(client: client, teamDir: teamDir, days: days, now: now).link
    }

    /// Undoes a `mint` whose link never made it to the peer (a LAN invite
    /// refused or unreachable after the nonce was already committed).
    /// Best-effort: the caller is already propagating the failure that
    /// prompted this, so an I/O error here is swallowed rather than
    /// masking it.
    public static func drop(nonce: String, teamDir: URL) {
        var book = load(teamDir: teamDir)
        book.consume(nonce)
        try? book.save(teamDir: teamDir)
    }

    public mutating func add(nonce: String, expires: Int) { nonces[nonce] = expires }
    public mutating func consume(_ nonce: String) { nonces[nonce] = nil }
    public mutating func prune(now: Int) { nonces = nonces.filter { $0.value > now } }

    /// The stored nonce this request proves it was invited with (unexpired), or nil.
    public func matches(_ request: TeamRequest, now: Int) -> String? {
        guard let proof = request.proof else { return nil }
        return nonces.first { nonce, expires in
            expires > now && TeamRequest.proof(nonce: nonce, kid: request.keys.kid) == proof
        }?.key
    }

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("invites.json") }

    public static func load(teamDir: URL) -> TeamInvites {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamInvites.self, from: $0) } ?? TeamInvites()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir))
    }
}
