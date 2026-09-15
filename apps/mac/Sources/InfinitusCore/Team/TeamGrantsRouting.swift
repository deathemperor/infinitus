import Foundation

/// `infinitusctl team grant | grants | revoke | drive | acks | pending |
/// allow | deny` as the running app's own verbs (spec §8): the app owns
/// this Mac's identity, writes the file, and its now.json hints see the
/// change at once. The file path stays for a CLI with no app (Linux, or
/// its own team dir / --team).
public enum TeamGrantsRouting {
    public static let verbs = ["team-grants", "team-grant", "team-revoke", "team-drive", "team-acks",
                               "team-pending", "team-allow", "team-deny"]

    /// The request for one subcommand, or nil when it is not routable
    /// (another subcommand, `--team`, a grant with no capability flag, a
    /// revoke with no id, a drive with too few words).
    public static func request(sub: String, positional: [String], options: [String: String],
                               flags: Set<String>) -> ControlRequest? {
        guard options["team"] == nil else { return nil }
        switch sub {
        case "grants":
            return ControlRequest(command: "team-grants")
        case "acks":
            return ControlRequest(command: "team-acks")
        case "pending":
            return ControlRequest(command: "team-pending")
        case "revoke", "allow", "deny":
            guard let id = positional.first else { return nil }
            return ControlRequest(command: "team-\(sub)", args: [id])
        case "grant":
            guard let audience = positional.first else { return nil }
            let cap = flags.intersection(TeamGrants.capabilities).sorted().joined(separator: ",")
            guard !cap.isEmpty else { return nil }
            var requestOptions = ["cap": cap]
            for key in ["threads", "pre", "expires"] {
                if let value = options[key] { requestOptions[key] = value }
            }
            return ControlRequest(command: "team-grant", args: [audience], options: requestOptions)
        case "drive":
            guard positional.count >= 3 else { return nil }
            return ControlRequest(command: "team-drive", args: positional,
                                  options: options.filter { $0.key == "project" })
        default:
            return nil
        }
    }

    /// The manifest lists every verb (an older app gets the file path).
    public static func appAnswers(manifest: JSONValue?) -> Bool {
        guard let names = manifest?.objectValue?["commands"]?.arrayValue?
            .compactMap({ $0.objectValue?["name"]?.stringValue }) else { return false }
        return Set(verbs).isSubset(of: Set(names))
    }
}
