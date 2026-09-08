import SwiftUI
import InfinitusCore
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

    /// The block split lives in InfinitusCore (`MarkdownBlocksTests` needs it
    /// without linking SwiftUI); this keeps the phone's `MarkdownText.Block`
    /// / `.blocks(_:)` call sites compiling unchanged.
    typealias Block = MarkdownBlock

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
        case .bullet(indent: let indent, let text):
            listRow(marker: "•", markerWidth: 18, text: text)
                .padding(.leading, CGFloat(indent) * 14)
        case .task(let done, let text):
            // U+FE0E keeps the boxes as text glyphs, not emoji (T3's "☑︎"/"☐︎").
            listRow(marker: done ? "☑\u{FE0E}" : "☐\u{FE0E}", markerWidth: 20, text: text)
        case .numbered(indent: let indent, let number, let text):
            listRow(marker: "\(number).", markerWidth: 28, text: text, trailingMarker: true)
                .padding(.leading, CGFloat(indent) * 14)
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
        guard let style else { return Text(text).font(font).foregroundStyle(color) }
        return MarkdownInline.text(text, font: font, color: color, runs: .init(
            link: style.link, codeFont: style.inlineCodeFont, code: style.inlineCode,
            strongFont: style.boldFont, strong: style.strong))
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

    static func blocks(_ text: String) -> [Block] { MarkdownBlocks.parse(text) }
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
