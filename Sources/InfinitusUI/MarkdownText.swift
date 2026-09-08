import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Renders a Claude reply's markdown in a chat bubble (user 2026-09-03:
/// "markdown messages on iOS are not properly rendered"). SwiftUI's
/// `Text` only understands inline markdown, so the block structure is
/// done here: fenced code, headings, bullet/numbered/task lists, quotes,
/// rules, paragraphs — each paragraph's inline bold/italic/code/links
/// through `AttributedString(markdown:)`.
///
/// With a `Style` in the environment (`.markdownStyle(_:)`) the blocks
/// take T3's run styles (`t3-markdown-text`, the `md*` tokens); without
/// one they keep the system look the Mac popup has always had.
public struct MarkdownText: View {
    public let text: String
    @Environment(\.markdownStyle) private var style

    public init(text: String) { self.text = text }

    /// T3's native markdown run styles (`NativeMarkdownSelectableText.ios.tsx`
    /// + `NativeMarkdownBlock.ios.tsx`), resolved for one surface.
    public struct Style {
        public var body: Color
        public var strong: Color
        public var link: Color
        public var inlineCode: Color
        public var codeText: Color
        public var codeBackground: Color
        public var divider: Color
        public var quoteBorder: Color
        public var muted: Color
        public var bodyFont: Font
        public var boldFont: Font
        /// h1…h6.
        public var headingFonts: [Font]
        public var inlineCodeFont: Font
        public var codeFont: Font
        public var languageFont: Font
        /// Between blocks (`document` gap), between list items, inside quotes.
        public var blockSpacing: CGFloat
        public var listSpacing: CGFloat

        /// The assistant row (`nativeTextStyle` for `assistant`) or the
        /// user bubble (`user`: everything in the bubble's foreground,
        /// fences on `mdUserFence*`), at T3's default 16 pt body.
        public static func t3(_ p: T3Theme.MobilePalette, user: Bool = false) -> Style {
            Style(body: user ? p.userBubbleForeground.color : p.mdBody.color,
                  strong: user ? p.userBubbleForeground.color : p.mdStrong.color,
                  link: user ? p.userBubbleForeground.color : p.mdLink.color,
                  inlineCode: user ? p.userBubbleForegroundMuted.color : p.foregroundSecondary.color,
                  codeText: user ? p.mdUserFenceText.color : p.mdCodeText.color,
                  codeBackground: user ? p.mdUserFenceBg.color : p.mdCodeBg.color,
                  divider: user ? p.userBubbleForeground.color : p.mdHr.color,
                  quoteBorder: user ? p.userBubbleForeground.color : p.mdBlockquoteBorder.color,
                  muted: user ? p.userBubbleForegroundMuted.color : p.mdBody.color,
                  bodyFont: T3Font.mobileLiteral(16),
                  boldFont: T3Font.mobileLiteral(16, .bold),
                  headingFonts: [21, 19, 17, 15, 15, 15].map { T3Font.mobileLiteral($0, .bold) },
                  inlineCodeFont: .system(size: 14, design: .monospaced),
                  codeFont: .system(size: 13, design: .monospaced),
                  languageFont: .system(size: 13, design: .monospaced),
                  blockSpacing: 8, listSpacing: 5)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style?.blockSpacing ?? 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case code(language: String?, String)
        case bullet(String)
        case task(done: Bool, String)
        case numbered(String, String)
        case quote(String)
        case rule
        case table(header: [String], rows: [[String]])
        case paragraph(String)
    }

    @ViewBuilder private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            if let style {
                inline(text, font: style.headingFonts[min(max(level, 1), 6) - 1], color: style.strong)
                    .padding(.top, 4)
            } else {
                inline(text)
                    .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                    .padding(.top, 2)
            }
        case .code(let language, let code):
            if let style {
                CodeFence(language: language, code: code, style: style)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        case .bullet(let text):
            listRow(marker: "•", markerWidth: 18, text: text)
        case .task(let done, let text):
            // U+FE0E keeps the boxes as text glyphs, not emoji (T3's "☑︎"/"☐︎").
            listRow(marker: done ? "☑\u{FE0E}" : "☐\u{FE0E}", markerWidth: 20, text: text)
        case .numbered(let number, let text):
            listRow(marker: "\(number).", markerWidth: 28, text: text, trailingMarker: true)
        case .quote(let text):
            HStack(spacing: style == nil ? 8 : 11) {
                RoundedRectangle(cornerRadius: 1).fill(style?.quoteBorder ?? Color.secondary).frame(width: 2)
                if let style {
                    inline(text, font: style.bodyFont, color: style.body).padding(.vertical, 2)
                } else {
                    inline(text).foregroundStyle(.secondary)
                }
            }
        case .rule:
            Rectangle().fill(style?.divider ?? Color.secondary.opacity(0.4)).frame(height: 1)
        case .table(let header, let rows):
            Table(header: header, rows: rows, style: style, inline: { text, font, color in
                if let style { return inline(text, font: font, color: color) }
                return inline(text).font(font).foregroundStyle(color)
            })
        case .paragraph(let text):
            if let style {
                inline(text, font: style.bodyFont, color: style.body)
            } else {
                inline(text)
            }
        }
    }

    /// T3's list row: a fixed-width marker (right-aligned for numbers,
    /// tabular) then the item, 6 pt apart; the system look keeps its
    /// tight baseline row.
    @ViewBuilder private func listRow(marker: String, markerWidth: CGFloat, text: String, trailingMarker: Bool = false) -> some View {
        if let style {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(style.bodyFont).monospacedDigit().foregroundStyle(style.body)
                    .frame(width: markerWidth, alignment: trailingMarker ? .trailing : .center)
                inline(text, font: style.bodyFont, color: style.body)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit()
                inline(text)
            }
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

    /// Inline runs in T3's colors: bold in the strong color and bold
    /// face, inline code in mono two points smaller (no background —
    /// `runStyle` only paints fences), links in the link color.
    private func inline(_ text: String, font: Font, color: Color) -> Text {
        guard let style, var attributed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(text).font(font).foregroundStyle(color)
        }
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            if run.link != nil {
                attributed[run.range].foregroundColor = style.link
                attributed[run.range].underlineStyle = .single
            } else if intent.contains(.code) {
                attributed[run.range].font = style.inlineCodeFont
                attributed[run.range].foregroundColor = style.inlineCode
            } else if intent.contains(.stronglyEmphasized) {
                attributed[run.range].font = style.boldFont
                attributed[run.range].foregroundColor = style.strong
            }
        }
        return Text(attributed).font(font).foregroundStyle(color)
    }

    /// T3's table (`NativeTable`): 160 pt cells in a 8 pt bordered box,
    /// the header row bold on the code background, hairlines between
    /// rows and columns, scrolling sideways when wide.
    private struct Table: View {
        let header: [String]
        let rows: [[String]]
        let style: Style?
        let inline: (String, Font, Color) -> Text
        var body: some View {
            let divider = style?.divider ?? Color.secondary.opacity(0.4)
            let bodyFont = style?.bodyFont ?? .body
            let bodyColor = style?.body ?? .primary
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    row(header, columns: columns, divider: divider, font: style?.boldFont ?? .body.bold(),
                        color: style?.strong ?? .primary)
                        .background(style?.codeBackground ?? Color.primary.opacity(0.06))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                        Rectangle().fill(divider).frame(height: 1)
                        row(cells, columns: columns, divider: divider, font: bodyFont, color: bodyColor)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(divider, lineWidth: 1))
            }
        }

        private func row(_ cells: [String], columns: Int, divider: Color, font: Font, color: Color) -> some View {
            HStack(spacing: 0) {
                ForEach(0..<columns, id: \.self) { i in
                    if i > 0 { Rectangle().fill(divider).frame(width: 1) }
                    inline(i < cells.count ? cells[i] : "", font, color)
                        .frame(width: 160, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// T3's fenced block (`NativeCodeBlock`): 10 pt continuous corners, a
    /// hairline border, a 42 pt header with the language in upper-case
    /// mono and a copy button, the code scrolling sideways under 14/12 pt
    /// insets.
    private struct CodeFence: View {
        let language: String?
        let code: String
        let style: Style
        @State private var copied = false

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text((language ?? "code").uppercased()).font(style.languageFont).foregroundStyle(style.muted)
                    Spacer(minLength: 0)
                    Button {
                        Self.copy(code)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 14))
                            .foregroundStyle(copied ? style.link : style.muted)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy \((language ?? "code").lowercased()) code")
                }
                .padding(.leading, 14).padding(.trailing, 6)
                .frame(minHeight: 42)
                .overlay(alignment: .bottom) { Rectangle().fill(style.divider).frame(height: 1) }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(style.codeFont).foregroundStyle(style.codeText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(style.divider, lineWidth: 1))
        }

        private static func copy(_ text: String) {
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        }
    }

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

    /// Line-based block split. Consecutive plain lines join into one
    /// paragraph (soft wraps); a blank line ends it.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
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
                else { out.append(.bullet(item)) }
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed.distance(from: trimmed.startIndex, to: dot) <= 3,
               trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(.numbered(String(trimmed[..<dot]),
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

private struct MarkdownStyleKey: EnvironmentKey {
    static let defaultValue: MarkdownText.Style? = nil
}

public extension EnvironmentValues {
    /// The run styles `MarkdownText` renders with; nil is the system look.
    var markdownStyle: MarkdownText.Style? {
        get { self[MarkdownStyleKey.self] }
        set { self[MarkdownStyleKey.self] = newValue }
    }
}

public extension View {
    func markdownStyle(_ style: MarkdownText.Style?) -> some View { environment(\.markdownStyle, style) }
}
