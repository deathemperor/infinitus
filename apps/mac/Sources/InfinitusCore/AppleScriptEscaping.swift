import Foundation

/// AppleScript string-literal escaping for text of external origin
/// (cswap's event stream: account aliases, error strings). Backslashes
/// FIRST, then quotes — an unescaped `\` before a `"` would reopen the
/// literal and run the remainder as AppleScript. Newlines flatten to
/// spaces: an `-e` literal cannot span lines.
public enum AppleScriptEscaping {
    public static func literal(_ s: String) -> String {
        String(s.map { $0.isNewline ? " " : $0 })
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
