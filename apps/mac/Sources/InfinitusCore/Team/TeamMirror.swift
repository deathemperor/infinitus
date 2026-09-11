import Foundation

/// The phone's view of the Mac's team (spec §9, step 8): a token-gated
/// route family on the mirror, deliberately OUTSIDE `TeamNearby.routePrefix`
/// (`/team/*` answers LAN peers without the pairing token). The Mac side
/// answers from `TeamModel`; the phone side is `NetworkFleetMirror`.
public enum TeamMirror {
    public static let prefix = "/mirror/team"
    public static let aggregatesPath = prefix + "/aggregates"
    public static let memberPath = prefix + "/member"
    public static let transcriptPath = prefix + "/transcript"
    public static let approvePath = prefix + "/approve"
    public static let declinePath = prefix + "/decline"
    public static let joinPath = prefix + "/join"
    public static let codePath = prefix + "/code"
    // Nearby (spec §6.4 last bullet): the Mac's LAN lists on the phone.
    public static let nearbyPath = prefix + "/nearby"
    public static let nearbyScanPath = prefix + "/nearby/scan"
    public static let nearbyRequestPath = prefix + "/nearby/request"
    public static let nearbyInvitePath = prefix + "/nearby/invite"
    public static let nearbyPullPath = prefix + "/nearby/pull"
    public static let nearbyAcceptPath = prefix + "/nearby/accept"
    public static let nearbyIgnorePath = prefix + "/nearby/ignore"

    public struct KidRequest: Codable, Equatable, Sendable {
        public var kid: String
        public init(kid: String) { self.kid = kid }
    }
    public struct JoinRequest: Codable, Equatable, Sendable {
        public var code: String
        public var name: String
        public init(code: String, name: String) { self.code = code; self.name = name }
    }
    public struct CodeRequest: Codable, Equatable, Sendable {
        public var days: Int
        /// true → an invite link (one-time nonce, auto-approved by the leader's Mac); false → a team code.
        public var invite: Bool
        public init(days: Int, invite: Bool) { self.days = days; self.invite = invite }
    }
    public struct ActionReply: Codable, Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var code: String?
        public init(ok: Bool, error: String? = nil, code: String? = nil) { self.ok = ok; self.error = error; self.code = code }
    }
    public struct MemberReply: Codable, Equatable, Sendable {
        public var kid: String
        public var name: String
        public var summary: Stats.Summary?
        public var sessions: [TeamDocs.SessionRow]
        /// Session ids with a readable transcript.
        public var transcripts: [String]
        public init(kid: String, name: String, summary: Stats.Summary?, sessions: [TeamDocs.SessionRow], transcripts: [String]) {
            self.kid = kid; self.name = name; self.summary = summary; self.sessions = sessions; self.transcripts = transcripts
        }
    }

    /// A POST with nothing to say (`nearby/scan`): the transport always
    /// sends a body, so it sends this one.
    public struct Empty: Codable, Equatable, Sendable {
        public init() {}
    }

    /// A LAN join request the Mac holds but has not filed yet.
    public struct PendingRequest: Codable, Equatable, Sendable, Identifiable {
        public var kid: String
        public var name: String
        public var platform: String
        public var at: Int
        public var id: String { kid }
        public init(kid: String, name: String, platform: String, at: Int) {
            self.kid = kid; self.name = name; self.platform = platform; self.at = at
        }
    }

    /// An invitation as the phone may see it (spec §10): who and which
    /// team, never the sealed envelope the link lives in.
    public struct InviteSummary: Codable, Equatable, Sendable, Identifiable {
        public var fromKid: String
        public var fromName: String
        public var teamName: String
        public var id: String { fromKid }
        public init(fromKid: String, fromName: String, teamName: String) {
            self.fromKid = fromKid; self.fromName = fromName; self.teamName = teamName
        }
    }

    public struct NearbyReply: Codable, Equatable, Sendable {
        public var peers: [TeamNearby.Peer]
        public var pending: [PendingRequest]
        public var invites: [InviteSummary]
        /// This Mac's team id, so the phone can tell "in this team" from
        /// "not in this team" without a second call.
        public var team: String?
        public init(peers: [TeamNearby.Peer], pending: [PendingRequest], invites: [InviteSummary], team: String?) {
            self.peers = peers; self.pending = pending; self.invites = invites; self.team = team
        }
    }

    public struct NearbyJoinRequest: Codable, Equatable, Sendable {
        public var kid: String
        public var name: String
        public init(kid: String, name: String) { self.kid = kid; self.name = name }
    }

    public struct InviteAccept: Codable, Equatable, Sendable {
        public var fromKid: String
        public var name: String
        public init(fromKid: String, name: String) { self.fromKid = fromKid; self.name = name }
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

    public static func memberQuery(kid: String, period: Stats.Period) -> String {
        "kid=\(encode(kid))&period=\(period.rawValue)"
    }
    public static func transcriptQuery(kid: String, session: String) -> String {
        "kid=\(encode(kid))&session=\(encode(session))"
    }
}
