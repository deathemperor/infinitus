import Foundation

/// Which endpoint Claude Code is pointed at, read from its own settings
/// (allowed per the project rules — `~/.claude/settings.json`, never an
/// engine internal). When `env.ANTHROPIC_BASE_URL` names the 9Router
/// base URL, Claude Code's requests ride 9Router and the 9Router fleet
/// is the one the app should treat as primary (user 2026-09-04; the
/// follow-up noted in docs/research/9router-backend.md).
public enum ClaudeCodeRouting {
    /// `env.ANTHROPIC_BASE_URL` from `~/.claude/settings.json`
    /// (`CLAUDE_CONFIG_DIR` honored). nil when the file, the `env`
    /// block or the key is missing — "unset" and "unparseable" are the
    /// same answer: Claude Code is on its own login.
    public static func anthropicBaseURL(configHome: URL? = nil) -> URL? {
        let home = configHome ?? ClaudeSessions.configHome()
        let url = home.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let env = settings["env"] as? [String: Any],
              let base = env["ANTHROPIC_BASE_URL"] as? String,
              let parsed = URL(string: base.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return parsed
    }

    /// Whether the settings' base URL names the router. Two ways in:
    /// an exact-ish match against the configured base URL (scheme, port
    /// and path equal; `localhost` and `127.0.0.1` are the same
    /// loopback endpoint), or any http URL on 9Router's well-known port
    /// 20128 — the signature that survives a moved or unset
    /// `9router_base_url`, and holds across the LAN too (this Mac's own
    /// settings point at 192.168.2.12:20128/v1; user 2026-09-04).
    /// https on that port is something else — a proxy fronting another
    /// service.
    public static func isRouted(_ settings: URL?, to router: URL?) -> Bool {
        guard let settings else { return false }
        if let router,
           settings.scheme?.lowercased() == router.scheme?.lowercased(),
           settings.port == router.port,
           pathless(settings) == pathless(router),
           host(settings) == host(router) {
            return true
        }
        return settings.scheme?.lowercased() == "http"
            && settings.port == NineRouterEngine.defaultPort
    }

    private static func pathless(_ url: URL) -> String {
        url.path.isEmpty || url.path == "/" ? "" : url.path
    }

    /// The `scheme://host:port` of a settings base URL — where a
    /// 9Router engine would run (any gateway path dropped). nil without
    /// an explicit port: an origin-less URL names no endpoint this app
    /// should adopt.
    public static func origin(of url: URL?) -> URL? {
        guard let url, let port = url.port else { return nil }
        var comps = URLComponents()
        comps.scheme = url.scheme?.lowercased()
        comps.host = url.host?.lowercased()
        comps.port = port
        return comps.url
    }

    /// Loopback names collapse to one host; everything else compares
    /// case-insensitively.
    private static func host(_ url: URL) -> String {
        let name = url.host?.lowercased() ?? ""
        return (name == "localhost" || name == "127.0.0.1") ? "loopback" : name
    }
}
