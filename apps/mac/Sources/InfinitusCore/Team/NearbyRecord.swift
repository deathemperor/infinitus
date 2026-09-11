import Foundation

/// The `_infinitus._tcp` TXT record (spec §6.4): what one machine tells
/// the LAN about its team standing. Nothing secret — `n` machine name,
/// `k` kid, `t` team id (empty when none), `r` leader|member|none, `d`
/// discoverable 0/1. Discoverable off ⇒ the record is `d=0` alone: no
/// name, no team fields. The Mac hands `txtData` to
/// `NWListener.Service(txtRecord:)`, the POSIX responder (MDNS.swift)
/// puts `txtStrings` in its TXT rdata — the same bytes either way,
/// which is why the packer lives here and not in either listener.
public struct NearbyRecord: Equatable, Sendable {
    public var name: String
    public var kid: String
    public var team: String?
    /// "leader" | "member" | "none"
    public var role: String
    public var discoverable: Bool

    public static let roles: Set<String> = ["leader", "member", "none"]

    public init(name: String, kid: String, team: String?, role: String, discoverable: Bool) {
        self.name = name; self.kid = kid; self.team = team; self.role = role; self.discoverable = discoverable
    }

    /// What an undiscoverable machine advertises.
    public static let hidden = NearbyRecord(name: "", kid: "", team: nil, role: "none", discoverable: false)

    /// The TXT strings in wire order (`n`, `k`, `t`, `r`, `d`).
    public var txtStrings: [String] {
        guard discoverable else { return ["d=0"] }
        return ["n=\(name)", "k=\(kid)", "t=\(team ?? "")", "r=\(role)", "d=1"]
    }

    /// TXT rdata: the strings, each length-prefixed.
    public var txtData: Data { TXTRecord.pack(txtStrings) }

    /// nil when the strings aren't an Infinitus record at all (no `d`);
    /// `d` other than `1` is `.hidden`, whatever else rides along.
    public init?(txtStrings strings: [String]) {
        var pairs: [String: String] = [:]
        for s in strings {
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[s.startIndex..<eq])
            // RFC 6763 §6.4: the first occurrence of a key wins.
            if pairs[key] == nil { pairs[key] = String(s[s.index(after: eq)...]) }
        }
        guard let d = pairs["d"] else { return nil }
        guard d == "1" else { self = .hidden; return }
        guard let kid = pairs["k"], !kid.isEmpty,
              let role = pairs["r"], Self.roles.contains(role) else { return nil }
        let team = pairs["t"] ?? ""
        self.init(name: pairs["n"] ?? "", kid: kid, team: team.isEmpty ? nil : team, role: role, discoverable: true)
    }

    public init?(txtData: Data) {
        self.init(txtStrings: TXTRecord.unpack(txtData))
    }
}

/// DNS TXT rdata (RFC 6763 §6): a sequence of length-prefixed strings,
/// each at most 255 bytes; an empty record is one zero-length string.
public enum TXTRecord {
    public static func pack(_ strings: [String]) -> Data {
        var out = Data()
        for s in strings {
            let bytes = Data(s.utf8).prefix(255)
            out.append(UInt8(bytes.count))
            out.append(bytes)
        }
        return out.isEmpty ? Data([0]) : out
    }

    public static func unpack(_ data: Data) -> [String] {
        var out: [String] = []
        var i = data.startIndex
        while i < data.endIndex {
            let len = Int(data[i])
            i += 1
            let end = min(i + len, data.endIndex)
            if len > 0 { out.append(String(decoding: data[i..<end], as: UTF8.self)) }
            i = end
        }
        return out
    }
}
