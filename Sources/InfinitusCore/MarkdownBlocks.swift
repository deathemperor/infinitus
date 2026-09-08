import Foundation

/// The line-based markdown block split `MarkdownText` (InfinitusUI) and
/// `T3ChatMarkdown` both render — moved here so `InfinitusCoreTests` can
/// exercise the parser without linking SwiftUI (T3 clone B-10).
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case code(language: String?, String)
    /// `indent` is 0-based: two spaces or a tab per nesting level.
    case bullet(indent: Int, String)
    case task(done: Bool, String)
    case numbered(indent: Int, String, String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])
    case paragraph(String)
}

public enum MarkdownBlocks {
    static func tableCells(_ line: String) -> [String] {
        var inner = Substring(line)
        inner = inner.dropFirst()
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { c in
            c.count >= 3 && c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-")
        }
    }

    /// Leading-whitespace nesting depth: every tab, or every two spaces, is one level.
    static func indentLevel(_ line: String) -> Int {
        var level = 0
        var spaces = 0
        for ch in line {
            if ch == "\t" { level += 1; spaces = 0 }
            else if ch == " " { spaces += 1; if spaces == 2 { level += 1; spaces = 0 } }
            else { break }
        }
        return level
    }

    /// Line-based block split. Consecutive plain lines join into one
    /// paragraph (soft wraps); a blank line ends it.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: (language: String?, lines: [String])?
        var tableOpen = false
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let open = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    out.append(.code(language: open.language, open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = (open.language, open.lines + [line])
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = indentLevel(line)
            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty { flush(); tableOpen = false; continue }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) || trimmed.allSatisfy({ $0 == "*" }) || trimmed.allSatisfy({ $0 == "_" }) {
                flush(); out.append(.rule); continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !rest.isEmpty { flush(); out.append(.heading(level: level, text: rest)); continue }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                let item = String(trimmed.dropFirst(2))
                flush()
                if item.hasPrefix("[ ] ") { out.append(.task(done: false, String(item.dropFirst(4)))) }
                else if item.lowercased().hasPrefix("[x] ") { out.append(.task(done: true, String(item.dropFirst(4)))) }
                else { out.append(.bullet(indent: indent, item)) }
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed.distance(from: trimmed.startIndex, to: dot) <= 3,
               trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(.numbered(indent: indent, String(trimmed[..<dot]),
                                     String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("> ") { flush(); out.append(.quote(String(trimmed.dropFirst(2)))); continue }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                let cells = tableCells(trimmed)
                if case .table(let header, var rows)? = out.last, tableOpen, cells.count >= 1 {
                    if isSeparatorRow(cells), rows.isEmpty { continue }   // the |---|---| line under the header
                    rows.append(cells); out[out.count - 1] = .table(header: header, rows: rows); continue
                }
                flush(); out.append(.table(header: cells, rows: [])); tableOpen = true; continue
            }
            tableOpen = false
            paragraph.append(trimmed)
        }
        if let open = code { out.append(.code(language: open.language, open.lines.joined(separator: "\n"))) }
        flush()
        return out
    }
}
