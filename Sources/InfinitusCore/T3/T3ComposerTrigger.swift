import Foundation

/// `detectComposerTrigger` (`packages/shared/src/composerTrigger.ts:50-116`):
/// what the composer's menu is showing, read off the prompt and the caret.
///
/// Two kinds are ported. `/` is **line**-anchored (`:56-60`: the line prefix
/// must start with the slash and hold no whitespace), so a slash mid-sentence
/// stays literal text; `@` is **token**-anchored (`:90-115`: the run back to
/// the nearest whitespace), so `email@x` is not a mention. Upstream's other two
/// — `$` skills (`:98-105`) and `/model` (`:63-87`) — have no producer here:
/// this port offers no skill catalogue and no model picker (Task 13's model
/// control is a label), so both stay literal text.
///
/// Offsets are **UTF-16 code units**, like the JS string indices upstream
/// walks and like `NSTextView.selectedRange().location`, which is what feeds
/// `caret`.
public enum T3ComposerTrigger: Sendable {
    public enum Kind: String, Sendable, Equatable {
        /// `"slash-command"` upstream.
        case command
        /// `"path"` upstream.
        case mention
    }

    public struct Detected: Sendable, Equatable {
        public let kind: Kind
        /// The run after the trigger character, as typed (case preserved).
        public let query: String
        /// UTF-16 offsets of the trigger character and the caret
        /// (`rangeStart` / `rangeEnd`, `:66-68`).
        public let start: Int
        public let end: Int
        /// The same span as string indices, for a caller that slices the text.
        public let range: Range<String.Index>
        /// `composerMenuSearchKey` (`ChatComposer.tsx:2153-2155`) — the
        /// identity the highlight is kept across.
        public var searchKey: String {
            "\(kind.rawValue):\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
    }

    /// `isWhitespace` (`:39-41`): the four characters upstream's token scan
    /// treats as a boundary, not the stdlib's whole Unicode class.
    private static func isTokenBoundary(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }

    /// `\S` in `^\/(\S*)$` (`:60`) — JavaScript's `\s`, which is wider than the
    /// token scan's four: the vertical tab and form feed, plus every Unicode
    /// space separator and the BOM. A pasted ideographic space (U+3000, what a
    /// CJK keyboard's space bar sends) closes the command menu just as a plain
    /// one does.
    private static func isRegexWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0B, 0x0C, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        case 0x2000...0x200A: return true
        default: return isTokenBoundary(unit)
        }
    }

    private static let slash: UInt16 = 0x2F
    private static let at: UInt16 = 0x40
    private static let newline: UInt16 = 0x0A

    public static func detect(text: String, caret: Int) -> Detected? {
        let units = Array(text.utf16)
        // `clampCursor` (`:34-37`).
        let cursor = max(0, min(units.count, caret))

        // `lineStart` (`:56`): `lastIndexOf("\n", cursor - 1) + 1`.
        var lineStart = 0
        if cursor > 0 {
            var i = cursor - 1
            while i >= 0 {
                if units[i] == newline { lineStart = i + 1; break }
                i -= 1
            }
        }

        // `linePrefix.startsWith("/")` + `^\/(\S*)$` (`:59-60`).
        if lineStart < cursor, units[lineStart] == slash {
            let rest = units[(lineStart + 1)..<cursor]
            if !rest.contains(where: isRegexWhitespace) {
                return detected(.command, query: rest, start: lineStart, end: cursor, in: text)
            }
        }

        // The token back to the nearest boundary (`:91-97`).
        var index = cursor - 1
        while index >= 0, !isTokenBoundary(units[index]) { index -= 1 }
        let tokenStart = index + 1
        guard tokenStart < cursor else { return nil }
        // Anything but `@` is literal text — including `$`, upstream's skill
        // trigger (`:98-105`), which this port does not offer.
        guard units[tokenStart] == at else { return nil }
        return detected(.mention, query: units[(tokenStart + 1)..<cursor],
                        start: tokenStart, end: cursor, in: text)
    }

    private static func detected(_ kind: Kind, query: ArraySlice<UInt16>,
                                 start: Int, end: Int, in text: String) -> Detected {
        Detected(kind: kind,
                 query: String(decoding: Array(query), as: UTF16.self),
                 start: start, end: end,
                 range: String.Index(utf16Offset: start, in: text)..<String.Index(utf16Offset: end, in: text))
    }

    /// `replaceTextRange` (`:118-128`): the trigger span swapped for what the
    /// picked row inserts, with the caret after it.
    public static func replacing(_ text: String, start: Int, end: Int,
                                 with replacement: String) -> (text: String, caret: Int) {
        let units = Array(text.utf16)
        let safeStart = max(0, min(units.count, start))
        let safeEnd = max(safeStart, min(units.count, end))
        let inserted = Array(replacement.utf16)
        let next = Array(units[0..<safeStart]) + inserted + Array(units[safeEnd...])
        return (String(decoding: next, as: UTF16.self), safeStart + inserted.count)
    }
}

/// The menu's highlight: which row ⏎ would pick.
///
/// `resolveComposerMenuActiveItemId` (`composerMenuHighlight.ts:1-20`) keeps
/// the highlight while the query behind the list is unchanged and the row is
/// still there, and falls back to the first row otherwise;
/// `nudgeComposerMenuHighlight` (`ChatComposer.tsx:2967-2981`) moves it with
/// ↑/↓, wrapping, from the last row for ↑ and the first for ↓ when nothing is
/// highlighted yet.
public enum T3ComposerMenuHighlight: Sendable {
    public static func resolve(itemIDs: [String], highlighted: String?,
                               currentKey: String?, highlightedKey: String?) -> String? {
        guard !itemIDs.isEmpty else { return nil }
        if currentKey == highlightedKey, let highlighted, itemIDs.contains(highlighted) {
            return highlighted
        }
        return itemIDs.first
    }

    /// `direction` is +1 for ↓ and −1 for ↑.
    public static func nudge(itemIDs: [String], highlighted: String?, direction: Int) -> String? {
        guard !itemIDs.isEmpty else { return nil }
        let index = highlighted.flatMap { itemIDs.firstIndex(of: $0) }
        // `normalizedIndex` (`:2816`): no highlight starts ↓ before the first
        // row and ↑ at the first, so ↑ wraps onto the last.
        let normalized = index ?? (direction > 0 ? -1 : 0)
        let count = itemIDs.count
        return itemIDs[((normalized + direction) % count + count) % count]
    }
}
