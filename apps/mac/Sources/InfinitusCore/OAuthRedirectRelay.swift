import Foundation

/// A sign-in the engine finishes itself (`.addOAuth`: swapd's `add-oauth`,
/// the proxy's callback) ends on a loopback redirect — `http://localhost:
/// <port>/callback?code=…&state=…` — that only a browser on THIS Mac can
/// deliver. A caller on another machine (the desktop on a second Mac, a
/// browser over the tunnel) shows the sign-in page on its own machine, so
/// the browser there is sent to ITS localhost, where nothing listens, and
/// the engine here waits for a redirect that never comes.
///
/// The relay closes that gap without a second protocol: the caller copies
/// the address that browser ended on and hands it back over `signin-code`
/// (stdin, a secret), and the Mac replays it against the engine's listener
/// on 127.0.0.1 — one GET with the same path and query, which is all the
/// listener reads (swapd's `serve` takes the request line alone and checks
/// the state itself). The pure half: which port a sign-in URL's
/// `redirect_uri` names, and whether a pasted address is that listener's.
public enum OAuthRedirectRelay {
    /// Hostnames a browser may spell the engine's loopback listener as.
    /// Never a LAN address: an authorization code must not travel further
    /// than this machine.
    /// `[::1]` is how Foundation's `URLComponents.host` spells the bracketed
    /// literal (probed on the macOS 26 toolchain), so both spellings are here.
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// The loopback port the sign-in URL's `redirect_uri` names, when it
    /// names one: the engine is listening there. Nil for a sign-in whose
    /// redirect goes elsewhere (a hosted callback, a paste-code page), which
    /// has nothing to relay.
    public static func loopbackPort(of authURL: URL) -> Int? {
        guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let redirect = URLComponents(string: raw),
              redirect.scheme?.lowercased() == "http",
              let host = redirect.host?.lowercased(), loopbackHosts.contains(host),
              let port = redirect.port
        else { return nil }
        return port
    }

    /// Where a pasted address replays: the engine's listener on 127.0.0.1,
    /// the same path and query. Nil unless the address is a loopback URL on
    /// `port` — anything else is not this sign-in's redirect, and a GET to
    /// an arbitrary address is not something a pasted string gets to cause.
    public static func replayURL(pasted: String, port: Int) -> URL? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let given = URLComponents(string: trimmed),
              given.scheme?.lowercased() == "http",
              let host = given.host?.lowercased(), loopbackHosts.contains(host),
              given.port == port
        else { return nil }
        var replay = URLComponents()
        replay.scheme = "http"
        replay.host = "127.0.0.1"
        replay.port = port
        replay.percentEncodedPath = given.percentEncodedPath.isEmpty ? "/" : given.percentEncodedPath
        replay.percentEncodedQuery = given.percentEncodedQuery
        return replay.url
    }
}
