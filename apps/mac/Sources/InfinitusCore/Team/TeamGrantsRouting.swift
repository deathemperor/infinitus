import Foundation

/// `infinitusctl team grant | grants | revoke` as the running app's own
/// verbs (#220): the app writes the file, so its pane and the now.json
/// hints see the change at once. The file path stays for a CLI with no
/// app (or its own team dir / --team).
public enum TeamGrantsRouting {
    public static let verbs = ["team-grants", "team-grant", "team-revoke"]

    /// The request for one subcommand, or nil when it is not routable
    /// (another subcommand, `--team`, a grant with no capability flag, a
    /// revoke with no id).
    public static func request(sub: String, positional: [String], options: [String: String],
                               flags: Set<String>) -> ControlRequest? {
        guard options["team"] == nil else { return nil }
        switch sub {
        case "grants":
            return ControlRequest(command: "team-grants")
        case "revoke":
            guard let id = positional.first else { return nil }
            return ControlRequest(command: "team-revoke", args: [id])
        case "grant":
            guard let audience = positional.first else { return nil }
            let cap = flags.intersection(TeamGrants.capabilities).sorted().joined(separator: ",")
            guard !cap.isEmpty else { return nil }
            var requestOptions = ["cap": cap]
            for key in ["sessions", "pre", "expires"] {
                if let value = options[key] { requestOptions[key] = value }
            }
            return ControlRequest(command: "team-grant", args: [audience], options: requestOptions)
        default:
            return nil
        }
    }

    /// The manifest lists all three verbs (an older app gets the file path).
    public static func appAnswers(manifest: JSONValue?) -> Bool {
        guard let names = manifest?.objectValue?["commands"]?.arrayValue?
            .compactMap({ $0.objectValue?["name"]?.stringValue }) else { return false }
        return Set(verbs).isSubset(of: Set(names))
    }
}
