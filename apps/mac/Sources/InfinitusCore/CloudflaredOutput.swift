import Foundation

/// What `cloudflared` prints that the app has to read back.
public enum CloudflaredOutput {
    /// A quick tunnel announces its throwaway hostname on stderr, boxed
    /// in ASCII art: pull the first `https://….trycloudflare.com` out of
    /// a line, whatever decoration surrounds it.
    public static func quickTunnelURL(in line: String) -> String? {
        guard let start = line.range(of: "https://") else { return nil }
        let rest = line[start.lowerBound...]
        let stops = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "|\"'<>)]},"))
        let url = String(rest.unicodeScalars.prefix { !stops.contains($0) })
        return url.hasSuffix(".trycloudflare.com") ? url : nil
    }
}
