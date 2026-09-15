import Foundation

/// Spec §7.1: what leaves the machine is redacted BEFORE it is sealed.
/// One regex pass per JSONL line; every replacement is plain ASCII
/// without quotes or backslashes, so a JSON line stays JSON. The
/// member's "What my team sees" view renders this same output.
/// These rules fail safe, not exact: prose containing a literal
/// `Authorization:` or a path under `/Users/x` can over-redact. That's
/// intentional — leaking a secret is worse than mangling a sentence.
public enum TeamRedaction {
    public struct Options {
        /// The member's home directory, normalised to `~`.
        public var home: String
        /// Pasted images ride as base64 blocks; dropped unless asked for.
        public var includeImages: Bool
        public init(home: String, includeImages: Bool = false) {
            self.home = home; self.includeImages = includeImages
        }
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Order matters: the `Authorization:` header rule eats "Bearer …"
    /// before the bare bearer rule sees it.
    ///
    /// A transcript line is JSON, so a multi-line tool result is one
    /// physical line where real newlines/tabs are the two-character JSON
    /// escapes `\n`/`\t`/`\r` — a secret can sit right after one of those
    /// instead of after a real word-boundary character. `B` is a leading
    /// boundary that accepts either, consumed into `$1` and replayed at
    /// the front of every affected replacement so the escape survives.
    private static let B = #"(^|[^A-Za-z0-9_]|\\[nrt])"#

    /// A rule runs its regex only on a line that carries one of its
    /// needles (ASCII, matched case-folded): every pattern above needs a
    /// literal — `authorization:`, `sk-`, `/Users/` — that a plain byte
    /// scan finds in a fraction of the time ICU spends deciding the line
    /// has nothing (#346: the publish spent ~7 s per pass in
    /// `RegexMatcher` over lines that matched no rule). The needles are
    /// looser than the regexes (`asia` also admits prose), never tighter.
    private struct Rule {
        let re: NSRegularExpression
        let template: String
        let needles: [[UInt8]]
        init(_ re: NSRegularExpression, _ template: String, _ needles: [String]) {
            self.re = re; self.template = template; self.needles = needles.map { Array($0.utf8) }
        }
    }

    private static let rules: [Rule] = [
        Rule(re(#"(?i)authorization:\s*[^\s"'\\]+(?:\s+[^\s"'\\]+)?"#), "Authorization: [redacted]", ["authorization:"]),
        Rule(re(#"(?i)"# + B + #"bearer\s+[A-Za-z0-9._~+/=-]{16,}"#), "$1Bearer [redacted]", ["bearer"]),
        Rule(re(B + #"sk-[A-Za-z0-9_-]{16,}"#), "$1[redacted-key]", ["sk-"]),
        Rule(re(B + #"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#), "$1[redacted-key]",
             ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]),
        Rule(re(B + #"(?:AKIA|ASIA)[A-Z0-9]{16}\b"#), "$1[redacted-aws-key]", ["akia", "asia"]),
        Rule(re(#"(?i)(aws_secret_access_key|aws_session_token|secretaccesskey|sessiontoken)(\\?"?\s*[=:]\s*\\?"?)[A-Za-z0-9+/=]{16,}"#),
             "$1$2[redacted]", ["aws_secret_access_key", "aws_session_token", "secretaccesskey", "sessiontoken"]),
        Rule(re(#"https://(?:hooks\.slack\.com|discord(?:app)?\.com/api/webhooks|outlook\.office\.com/webhook)/[^\s"'\\]+"#),
             "[redacted-webhook]", ["hooks.slack.com/", "discord.com/api/webhooks/", "discordapp.com/api/webhooks/", "outlook.office.com/webhook/"]),
        Rule(re(B + #"([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD))=([^\s"'\\]+)"#), "$1$2=[redacted]",
             ["key=", "secret=", "token=", "password=", "passwd="]),
        // Any user's home, this machine's included: /Users/<x>, /home/<x>, /root.
        // Zero-width lookbehind (not a capture) — no chars to replay.
        Rule(re(#"(?<=^|[^A-Za-z0-9~]|\\[nrt])(?:/(?:Users|home)/[^/\s"'\\]+|/root(?=/|["'\s\\]|$))"#), "~",
             ["/users/", "/home/", "/root"]),
    ]

    private static let image = re(#""data"\s*:\s*"[A-Za-z0-9+/=]{256,}""#)
    private static let imageNeedle = Array(#""data""#.utf8)

    private struct Home {
        let re: NSRegularExpression
        let needle: [UInt8]
    }

    private static func homeRule(_ options: Options) -> Home? {
        guard options.home.count > 1 else { return nil }
        return Home(re: re(NSRegularExpression.escapedPattern(for: options.home) + #"(?=/|["'\s\\]|$)"#),
                    needle: ASCIIScan.lowered(options.home))
    }

    public static func redact(_ line: String, options: Options) -> String {
        redact(line, options: options, home: homeRule(options))
    }

    /// The per-line redactor with the home regex compiled once — what a
    /// publisher hands `TeamChunker`, which calls it for every line.
    public static func redactor(options: Options) -> (String) -> String {
        let home = homeRule(options)
        return { redact($0, options: options, home: home) }
    }

    private static func redact(_ line: String, options: Options, home: Home?) -> String {
        var out = line
        // Folded once per line; again only after a rule rewrote the line,
        // so a later rule's scan always sees what its regex would.
        var lower = ASCIIScan.lowered(out)
        func apply(_ re: NSRegularExpression, _ template: String) {
            let next = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
            if next != out { out = next; lower = ASCIIScan.lowered(out) }
        }
        if let home, ASCIIScan.contains(lower, home.needle) {
            apply(home.re, "~")
        }
        for rule in rules where rule.needles.contains(where: { ASCIIScan.contains(lower, $0) }) {
            apply(rule.re, rule.template)
        }
        if !options.includeImages, ASCIIScan.contains(lower, imageNeedle) {
            apply(image, "\"data\":\"\"")
        }
        return out
    }

    /// Line by line; the trailing newline structure is kept exactly.
    /// The home regex is compiled once here rather than per line — a
    /// transcript can run to tens of thousands of lines.
    public static func redact(jsonl: Data, options: Options) -> Data {
        let text = String(decoding: jsonl, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let redact = redactor(options: options)
        return Data(lines.map { redact(String($0)) }.joined(separator: "\n").utf8)
    }
}
