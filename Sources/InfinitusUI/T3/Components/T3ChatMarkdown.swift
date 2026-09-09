import SwiftUI
import InfinitusCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// T3's chat markdown surface for the Mac workspace window
/// (`components/ChatMarkdown.tsx`; `.chat-markdown` rules in `index.css`).
/// Renders the same `MarkdownBlock`s `MarkdownText` does, styled with the
/// web palette instead of the phone's: paragraphs `sm`/`messageForeground`,
/// headings per `.chat-markdown h1..h6` (index.css:1661-1683 — weight 600
/// throughout; h1 1.25rem, h2 1.125rem, h3+ 1rem, matching
/// `T3TypeScale.Web.xl/.lg/.base`), fenced code on `codeBackground` with a
/// language label and a "Copy code" ghost button (`MarkdownCodeBlock`,
/// ChatMarkdown.tsx:886-1013; `copyLabel` :898), tables as a bordered grid
/// (`MarkdownTable`, ChatMarkdown.tsx:672-763 — no "Copy table" affordance
/// here, the interface for this view doesn't ask for one), task items as a
/// checkbox glyph + text (upstream renders a raw `<input type="checkbox">`
/// at ChatMarkdown.tsx:2694-2710 — no Lucide icon is vendored for a square
/// checkbox, `Lucide.generated.swift`'s case set is driven by T3's own
/// imports and it never imports one, so this draws the SF Symbol
/// equivalent instead of `LucideIcon`).
///
/// A plain view over `MarkdownBlocks.parse` — memoizing per message id is
/// the row view's job (Task 11).
public struct T3ChatMarkdown: View {
    @Environment(\.t3) private var t3
    public let text: String
    /// The surface is `text-foreground/80` (`ChatMarkdown.tsx:3147`); a caller
    /// overrides it the way the user bubble does
    /// (`className="text-message-foreground"`, `MessagesTimeline.tsx:2540`).
    private let foreground: Color?
    public init(text: String, foreground: Color? = nil) {
        self.text = text
        self.foreground = foreground
    }

    private var p: T3Theme.WebPalette { t3.web }
    private var textColor: Color { foreground ?? p.foreground.color.opacity(0.8) }

    /// `leading-relaxed` on the surface (`:3129`): a 22.75 px line box under
    /// the 14 px body. SwiftUI's `.lineSpacing` is the gap ADDED to the font's
    /// own line height — SF at 14 pt is ~16.7 — so the scale step's 6 lands
    /// the pitch at ~22.7 pt.
    private static let bodyLineSpacing = T3TypeScale.lineSpacing(T3TypeScale.Web.sm.step)

    /// CSS puts HALF the extra leading above the first line of a block and
    /// half below the last one; `.lineSpacing` only ever goes BETWEEN two
    /// lines, so a SwiftUI text block is one full leading short of its `div`
    /// (a one-line paragraph is 17 pt where the browser's box is 22.75). The
    /// reference measured exactly that: every block ran 6 pt short and the
    /// error accumulated down the reply. The half goes back on as padding.
    private static let halfLeading = T3TypeScale.lineSpacing(T3TypeScale.Web.sm.step) / 2

    private static func halfLeading(_ step: T3TypeScale.Step) -> Double {
        T3TypeScale.lineSpacing(step) / 2
    }

    public var body: some View {
        // `margin: 0.65rem 0` on every block (index.css:1652-1658); adjacent
        // margins collapse to one gap.
        VStack(alignment: .leading, spacing: 0.65 * 16) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    @ViewBuilder private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, font: headingFont(level), color: p.messageForeground.color)
                .padding(.vertical, Self.halfLeading(headingStep(level)))
        case .code(let language, let code):
            CodeFence(language: language, code: code, palette: p)
        case .bullet(indent: let indent, let text):
            listRow(marker: "•", text: text)
                .padding(.leading, CGFloat(indent) * 14)
                .padding(.vertical, Self.halfLeading)
        case .task(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(p.mutedForeground.color)
                inline(text, font: T3Font.web(.sm), color: textColor)
                    .lineSpacing(Self.bodyLineSpacing)
            }
            .padding(.vertical, Self.halfLeading)
        case .numbered(indent: let indent, let number, let text):
            listRow(marker: "\(number).", text: text)
                .padding(.leading, CGFloat(indent) * 14)
                .padding(.vertical, Self.halfLeading)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(p.border.color).frame(width: 2)
                inline(text, font: T3Font.web(.sm), color: p.mutedForeground.color)
                    .lineSpacing(Self.bodyLineSpacing)
                    .padding(.vertical, Self.halfLeading)
            }
        case .rule:
            Rectangle().fill(p.border.color).frame(height: 1)
        case .table(let header, let rows):
            Table(header: header, rows: rows, palette: p)
        case .paragraph(let text):
            inline(text, font: T3Font.web(.sm), color: textColor)
                .lineSpacing(Self.bodyLineSpacing)
                .padding(.vertical, Self.halfLeading)
        }
    }

    /// `.chat-markdown h1..h6` (index.css:1661-1683): weight 600 throughout;
    /// h1 1.25rem (`T3TypeScale.Web.xl`), h2 1.125rem (`.lg`), h3 1rem
    /// (`.base`), h4-h6 0.875rem (`.sm`, index.css:1680-1687).
    /// `T3Font.Weight` has no semibold step, so this sets the system font
    /// directly at the CSS weight.
    private func headingFont(_ level: Int) -> Font {
        .system(size: headingStep(level).size, weight: .semibold)
    }

    private func headingStep(_ level: Int) -> T3TypeScale.Step {
        let scale: T3TypeScale.Web = level == 1 ? .xl : level == 2 ? .lg : level == 3 ? .base : .sm
        return scale.step
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).font(T3Font.web(.sm)).foregroundStyle(textColor)
            inline(text, font: T3Font.web(.sm), color: textColor)
                .lineSpacing(Self.bodyLineSpacing)
        }
    }

    /// Inline bold/code/link runs, the same helper `MarkdownText` uses,
    /// against the web palette's tokens (it has no dedicated `md*` set —
    /// that's mobile-only). `strong: nil` — `<strong>` only bumps the
    /// weight here, it doesn't repaint the color.
    ///
    /// Inline code wears the chip `.chat-markdown :not(pre) > code`
    /// (index.css:1802-1809) describes: `--muted` behind a 0.75 rem
    /// (`Self.inlineCodeSize`) mono run in `--contrast-foreground` — full
    /// `foreground`, brighter than the 80 % body around it — with
    /// `0.35rem` of padding and the 1 px `--contrast-border` the rectangle
    /// stands in for. See `MarkdownInline.CodeChip` for what a SwiftUI text
    /// run can and cannot paint (no radius, no border).
    private func inline(_ text: String, font: Font, color: Color) -> some View {
        MarkdownInline.text(text, font: font, color: color, runs: .init(
            // `.chat-markdown a { color: var(--info-foreground); text-decoration: none }`
            // (index.css:1755-1757): blue-700 light / blue-400 dark, no underline.
            link: p.infoForeground.color,
            codeFont: .system(size: Self.inlineCodeSize, design: .monospaced),
            code: p.foreground.color,
            strongFont: font.weight(.semibold), strong: nil,
            codeChip: .init(background: p.muted.color, fontSize: Self.inlineCodeSize,
                            padding: Self.inlineCodePadding),
            linkGlyph: Self.linkSlot(p.infoForeground),
            linkUnderline: false))
    }

    /// `font-size: 0.75rem` and `padding: 0.1rem 0.35rem` + `border: 1px`
    /// (index.css:1802-1809).
    private static let inlineCodeSize: Double = 12
    private static let inlineCodePadding: Double = 0.35 * 16 + 1

    /// The favicon slot before a link (`MarkdownLinkFavicon`,
    /// ChatMarkdown.tsx:1193-1218) as one image in the text flow: lucide's
    /// `globe` at `size-[14px]`, stroked in the link's own colour (the span
    /// inherits the anchor's `currentColor`), inside a box widened by the
    /// span's `ms-[0.25em]` / `me-[0.2em]` margins — em of the 14 pt body —
    /// so the slot advances exactly as upstream's does and the paragraph
    /// wraps where the reference's does.
    ///
    /// Nothing is FETCHED: a favicon request on the render path is off the
    /// table here, so every host gets the globe upstream falls back to when
    /// there is no favicon (`:1211`, the reference's own `localhost` line),
    /// and no brand mark is drawn (`:1193`). See `MarkdownInline.LinkGlyph`
    /// for why this is an image and not an attributed run.
    private static let slotGlyphSize: Double = 14
    private static let slotMarginStart: Double = 0.25 * 14
    private static let slotMarginEnd: Double = 0.2 * 14

    #if canImport(AppKit)
    private static func linkSlot(_ token: T3RGBA) -> MarkdownInline.LinkGlyph {
        let size = slotGlyphSize, lead = slotMarginStart
        let box = NSSize(width: lead + size + slotMarginEnd, height: size)
        // `flipped: true` — lucide's 24-unit view box is y-down, like the
        // `Path` `LucideShape` builds from it.
        let image = NSImage(size: box, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(LucideShape(icon: .globe)
                .path(in: CGRect(x: lead, y: 0, width: size, height: size)).cgPath)
            ctx.setStrokeColor(CGColor(srgbRed: token.r / 255, green: token.g / 255,
                                       blue: token.b / 255, alpha: token.a))
            ctx.setLineWidth(2 * size / 24)   // lucide's stroke-width 2 in the view box
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            return true
        }
        return .init(image: Image(nsImage: image))
    }
    #else
    /// The workspace is a Mac window; the phone renders markdown with
    /// `MarkdownText`, which asks for no slot.
    private static func linkSlot(_ token: T3RGBA) -> MarkdownInline.LinkGlyph? { nil }
    #endif

    private struct Table: View {
        let header: [String]
        let rows: [[String]]
        let palette: T3Theme.WebPalette
        var body: some View {
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    row(header, columns: columns, font: T3Font.web(.sm, .medium), color: palette.messageForeground.color)
                        .background(palette.codeBackground.color)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                        Rectangle().fill(palette.border.color).frame(height: 1)
                        row(cells, columns: columns, font: T3Font.web(.sm), color: palette.messageForeground.color)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius, style: .continuous)
                    .stroke(palette.border.color, lineWidth: 1))
            }
        }
        private func row(_ cells: [String], columns: Int, font: Font, color: Color) -> some View {
            HStack(spacing: 0) {
                ForEach(0..<columns, id: \.self) { i in
                    if i > 0 { Rectangle().fill(palette.border.color).frame(width: 1) }
                    Text(i < cells.count ? cells[i] : "").font(font).foregroundStyle(color)
                        .frame(width: 160, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `MarkdownCodeBlock` (ChatMarkdown.tsx:886-1013): a surface on
    /// `codeBackground` (index.css:1318-1322 wins over the utility classes),
    /// a header (`pt-1.5 pr-1.5 pb-0 pl-3`) carrying the language in MONO at
    /// 0.6875 rem and, at its right, a two-button toolbar (`gap-0.5`) of
    /// `icon-xs` ghosts — wrap and copy, both `size-3`, in
    /// `code-foreground` at 72 % (index.css:1333-1336). "Wrap lines" /
    /// "Copy code" are the tooltip labels, never text in the row. The body is
    /// `pre`'s `padding: 0.8rem 0.9rem` (index.css:1822-1829), scrolling
    /// horizontally until the wrap toggle turns soft wrap on
    /// (`readInitialWordWrapSetting` starts it off).
    ///
    /// Upstream resets the copied label after 1200 ms via `setTimeout`; this
    /// keeps `MarkdownText.CodeFence`'s 1.5 s `Task.sleep` (no Timer, per the
    /// idle-CPU rule).
    private struct CodeFence: View {
        let language: String?
        let code: String
        let palette: T3Theme.WebPalette
        @State private var copied = false
        @State private var wrapped = false

        /// `extractFenceLanguage` (`:518-522`): a fence with no info string
        /// is labelled `text`.
        private var label: String { language ?? "text" }
        private var chrome: Color { palette.codeForeground.color.opacity(0.72) }

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(chrome)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        action(.wrapText, pressed: wrapped,
                               help: wrapped ? "Disable line wrap" : "Wrap lines") { wrapped.toggle() }
                        action(copied ? .check : .copy, pressed: false,
                               help: copied ? "Copied" : "Copy code") {
                            Self.copy(code)
                            copied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                copied = false
                            }
                        }
                    }
                }
                .padding(.top, 6).padding(.trailing, 6).padding(.leading, 12)
                if wrapped {
                    body_.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) { body_ }
                }
            }
            .background(palette.codeBackground.color, in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius, style: .continuous))
        }

        private var body_: some View {
            Text(code)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(palette.codeForeground.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wrapped, vertical: true)
                .padding(.horizontal, 0.9 * 16).padding(.vertical, 0.8 * 16)
        }

        /// `size="icon-xs"` = `size-6` at this breakpoint with a `size-3`
        /// glyph; `.chat-markdown-chrome-action:hover` and its pressed state
        /// take the full `code-foreground`.
        private func action(_ icon: Lucide, pressed: Bool, help: String,
                            _ act: @escaping () -> Void) -> some View {
            Button(action: act) {
                LucideIcon(icon, size: 12)
                    .foregroundStyle(pressed ? palette.codeForeground.color : chrome)
                    .frame(width: 24, height: 24)
                    .background(pressed ? palette.muted.color : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
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
}

#Preview("T3 chat markdown") {
    T3ChatMarkdown(text: """
    # Heading one
    ## Heading two
    ### Heading three

    A paragraph with **bold** text, `inline code`, and a [link](https://t3.chat).

    - a bullet
      - a nested bullet
    1. first
    2. second

    - [ ] open task
    - [x] done task

    > a quoted line

    ---

    | Col A | Col B |
    |---|---|
    | 1 | 2 |
    | 3 | 4 |

    ```swift
    let a = 1
    ```
    """)
    .padding(16)
    .t3(platform: .web, scheme: .light)
    .preferredColorScheme(.light)
}
