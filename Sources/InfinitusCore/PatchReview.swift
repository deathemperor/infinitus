import Foundation

/// Reviewing a checkpoint's diff from the phone (#166): the patch split
/// into files and hunks so each hunk can take a comment, and the comments
/// composed into the one message the session receives.
public enum PatchReview {
    public struct Hunk: Equatable, Sendable {
        /// The `@@ … @@` line, context suffix included.
        public let header: String
        /// The body lines as git prints them (`+`, `-`, ` ` prefixes kept).
        public let lines: [String]
        public init(header: String, lines: [String]) { self.header = header; self.lines = lines }
    }

    public struct File: Equatable, Sendable {
        public let path: String
        /// "new file", "deleted", "renamed from x", "binary" — nil for a plain edit.
        public let note: String?
        public let hunks: [Hunk]
        public init(path: String, note: String? = nil, hunks: [Hunk]) {
            self.path = path; self.note = note; self.hunks = hunks
        }
    }

    /// `git diff <tree> <tree>` output → files → hunks. A patch cut short
    /// (`Diff.truncated`) parses as far as it goes; the last hunk simply
    /// ends where the text does.
    public static func parse(_ patch: String) -> [File] {
        var files: [File] = []
        var path = "", note: String? = nil, hunks: [Hunk] = []
        var header: String? = nil, lines: [String] = []
        func closeHunk() {
            if let h = header { hunks.append(Hunk(header: h, lines: lines)) }
            header = nil; lines = []
        }
        func closeFile() {
            closeHunk()
            if !path.isEmpty { files.append(File(path: path, note: note, hunks: hunks)) }
            path = ""; note = nil; hunks = []
        }
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                path = gitPath(line)
            } else if line.hasPrefix("@@") {
                closeHunk()
                header = line
            } else if header != nil {
                lines.append(line)
            } else if line.hasPrefix("new file mode") {
                note = "new file"
            } else if line.hasPrefix("deleted file mode") {
                note = "deleted"
            } else if line.hasPrefix("rename from ") {
                note = "renamed from " + line.dropFirst("rename from ".count)
            } else if line.hasPrefix("Binary files ") {
                note = note.map { $0 + ", binary" } ?? "binary"
            } else if line.hasPrefix("+++ b/") {
                // The post-image name is the one the reader knows.
                path = String(line.dropFirst("+++ b/".count))
            }
        }
        closeFile()
        return files
    }

    /// `diff --git a/x b/y` → `y` (paths with spaces are quoted by git;
    /// a quoted name is kept as printed).
    static func gitPath(_ line: String) -> String {
        let rest = line.dropFirst("diff --git ".count)
        if let range = rest.range(of: " b/") { return String(rest[range.upperBound...]) }
        return String(rest)
    }

    public struct Comment: Equatable, Sendable {
        public let path: String
        public let hunk: Hunk
        public let text: String
        public init(path: String, hunk: Hunk, text: String) { self.path = path; self.hunk = hunk; self.text = text }
    }

    public enum Verdict: String, Sendable { case approve, requestChanges }

    /// Lines of a hunk quoted under a comment, at most.
    public static let excerptLines = 12
    /// The message must pass `SessionInput.isValidMessage`: under its cap
    /// (`SessionInput.maxMessageLength`, Mac-only code — the test pins the
    /// two together), no control characters but newlines (a tab is one —
    /// code excerpts have them).
    public static let maxLength = 4000

    /// The one message the session gets: an approval, or the comments
    /// with their hunks quoted. Excerpts shrink, then go, before the
    /// text is ever cut, so every comment survives a long review.
    public static func compose(checkpoint n: Int, subject: String, verdict: Verdict, comments: [Comment]) -> String {
        let since = "the changes since checkpoint #\(n) (\(sanitize(subject)))"
        if comments.isEmpty {
            return verdict == .approve
                ? "Reviewed \(since) from the phone: approved, they look good. Carry on."
                : "Reviewed \(since) from the phone: changes requested (see the next message)."
        }
        for excerpt in [excerptLines, 4, 0] {
            let text = render(since: since, verdict: verdict, comments: comments, excerpt: excerpt)
            if text.count <= maxLength { return text }
        }
        let cut = render(since: since, verdict: verdict, comments: comments, excerpt: 0)
        return String(cut.prefix(maxLength - 1)) + "…"
    }

    static func render(since: String, verdict: Verdict, comments: [Comment], excerpt: Int) -> String {
        var out = verdict == .approve
            ? "Reviewed \(since) from the phone: approved, with notes.\n"
            : "Reviewed \(since) from the phone: changes requested.\n"
        for (i, c) in comments.enumerated() {
            out += "\n\(i + 1). \(sanitize(c.path)) \(sanitize(c.hunk.header))\n"
            if excerpt > 0 {
                for line in c.hunk.lines.prefix(excerpt) { out += "   > " + sanitize(line) + "\n" }
                if c.hunk.lines.count > excerpt { out += "   > …\n" }
            }
            out += "   " + sanitize(c.text).split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n   ") + "\n"
        }
        return out.trimmingCharacters(in: .newlines)
    }

    /// Tabs become spaces, other control characters vanish; newlines stay.
    static func sanitize(_ text: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar == "\t" { out += "    " }
            else if scalar == "\n" || scalar.properties.generalCategory != .control { out.unicodeScalars.append(scalar) }
        }
        return out
    }
}
