import SwiftUI

/// Renders a Claude reply's markdown in a chat bubble (user 2026-09-03:
/// "markdown messages on iOS are not properly rendered"). SwiftUI's
/// `Text` only understands inline markdown, so the block structure is
/// done here: fenced code, headings, bullet/numbered lists, quotes,
/// paragraphs — each paragraph's inline bold/italic/code/links through
/// `AttributedString(markdown:)`.
public struct MarkdownText: View {
    public let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case code(String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case paragraph(String)
    }

    @ViewBuilder private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(text)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").monospacedDigit()
                inline(text)
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary).frame(width: 2)
                inline(text).foregroundStyle(.secondary)
            }
        case .paragraph(let text):
            inline(text)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    /// Line-based block split. Consecutive plain lines join into one
    /// paragraph (soft wraps); a blank line ends it.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let open = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    out.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    code = open + [line]
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !rest.isEmpty { flush(); out.append(.heading(level: level, text: rest)); continue }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush(); out.append(.bullet(String(trimmed.dropFirst(2)))); continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed.distance(from: trimmed.startIndex, to: dot) <= 3,
               trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(.numbered(String(trimmed[..<dot]),
                                     String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("> ") { flush(); out.append(.quote(String(trimmed.dropFirst(2)))); continue }
            paragraph.append(trimmed)
        }
        if let open = code { out.append(.code(open.joined(separator: "\n"))) }
        flush()
        return out
    }
}
