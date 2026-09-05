import Foundation

/// Local authentication helper for 9Router (decolua/9router).
/// On the local machine, 9Router generates a machine ID and a CLI secret under its data directory:
///   Windows: %APPDATA%\9router\ (machine-id, auth\cli-secret)
///   macOS/Linux: ~/.9router/ (machine-id, auth\cli-secret)
/// The loopback CLI token is: SHA256(machineId + "9r-cli-auth" + cliSecret).prefix(16).
/// Sending header `x-9r-cli-token: <token>` bypasses dashboard login prompts for local requests.
public enum NineRouterLocalAuth {
    public static func dataDir() -> URL {
        #if os(Windows)
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming).appendingPathComponent("9router")
        #else
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".9router")
        #endif
    }

    public static func cliToken(dataDirectory: URL? = nil) -> String? {
        let dir = dataDirectory ?? dataDir()
        let machineIdFile = dir.appendingPathComponent("machine-id")
        let secretFile = dir.appendingPathComponent("auth").appendingPathComponent("cli-secret")
        guard let raw = try? String(contentsOf: machineIdFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let extra = try? String(contentsOf: secretFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !extra.isEmpty else {
            return nil
        }
        let input = raw + "9r-cli-auth" + extra
        let digest = SHA256.hex(Array(input.utf8))
        return String(digest.prefix(16))
    }
}
