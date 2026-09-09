import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One inline-run styler for both markdown renderers (MarkdownText on the
/// phone palette, T3ChatMarkdown on the web palette): bold, code and links.
enum MarkdownInline {
    struct Runs {
        var link: Color
        var codeFont: Font
        var code: Color
        var strongFont: Font
        /// `nil` leaves the run's color alone (T3's web `<strong>` only
        /// bumps the weight; the phone repaints it in `style.strong`).
        var strong: Color?
        /// `nil` renders inline code as font + colour only — the phone's look,
        /// unchanged. `T3ChatMarkdown` passes one (below).
        var codeChip: CodeChip? = nil
        /// `nil` draws a link as its text alone — the phone's look, unchanged.
        /// `T3ChatMarkdown` passes one so every external link keeps the
        /// reference's favicon slot.
        var linkGlyph: LinkGlyph? = nil
        /// The phone underlines a link; T3's `.chat-markdown a` is
        /// `text-decoration: none` (index.css:1755-1757), so `T3ChatMarkdown`
        /// turns this off.
        var linkUnderline = true
    }

    /// The inline-code chip, `.chat-markdown :not(pre) > code`
    /// (index.css:1802-1809): a 6 px-radius box on `--muted` with a
    /// `--contrast-border` hairline, `0.1rem 0.35rem` of padding around a
    /// 0.75 rem mono run.
    ///
    /// **Technique, and what it can't do.** SwiftUI has no inline attachment
    /// that flows with text, so the chip has to be an attribute of the run
    /// itself: `AttributedString.backgroundColor`, which paints a plain
    /// RECTANGLE behind the glyphs — no corner radius and no border are
    /// reachable this way (a `TextRenderer` could draw both, but it is
    /// macOS 15 / iOS 18 and this target is iOS 17). CSS padding is not
    /// reachable either, so the run is grown by a mono SPACE on each side,
    /// carrying the same background and `kern`ed to exactly the padding
    /// width: the background then widens like the CSS box does, and — the
    /// point of the whole exercise — the line wraps where the reference's do,
    /// because a chip in the middle of a paragraph is 13.2 pt wider than its
    /// bare text.
    ///
    /// Colours are the caller's tokens; a user bubble takes the same chip
    /// (upstream only retints one under the light `t3-chat` theme,
    /// index.css:1341-1356).
    struct CodeChip {
        /// `background: var(--muted)`.
        var background: Color
        /// The mono run's point size — the pad space is measured in it.
        var fontSize: Double
        /// Space between the box edge and the text, per side: CSS
        /// `padding-inline` plus the 1 px border the rectangle stands in for.
        var padding: Double
    }

    /// The favicon slot upstream reserves before an external link's text
    /// (`MarkdownLinkFavicon`, ChatMarkdown.tsx:1193-1218): an
    /// `ms-[0.25em] me-[0.2em] size-[14px] [vertical-align:-0.125em]` span
    /// holding the site's favicon, or lucide's globe when there is none.
    ///
    /// **Technique, and what it can't do.** SwiftUI draws no attachment
    /// inside a `Text`'s `AttributedString` — an `NSTextAttachment` carried
    /// in through `AttributedString(NSAttributedString)` renders NOTHING
    /// (probed on macOS 26) — but `Text(Image(nsImage:))` in a `Text`
    /// CONCATENATION does, at the image's own point size and in the text
    /// flow, wrapping like a word. So a paragraph carrying links is built as
    /// concatenated `Text`s instead of one attributed run, which costs two
    /// things:
    /// - the margins have to be baked into the image's own width rather than
    ///   set as spacing — a padding space would be a wrap opportunity between
    ///   the glyph and the link's first word, which upstream's
    ///   `whitespace-nowrap` span forbids;
    /// - the glyph sits ON the baseline, not at upstream's `-0.125em`.
    ///   `.baselineOffset` is the only way down and it GROWS the line box by
    ///   the offset (17 → 18.75 pt at 14 pt, measured), which would push every
    ///   following line of the reply down; 1.75 pt too high is the cheaper
    ///   error, and the reference's own glyph clears the baseline by ~1 pt.
    struct LinkGlyph {
        /// The whole slot, margins included — see `T3ChatMarkdown`.
        var image: Image
    }

    static func text(_ markdown: String, font: Font, color: Color, runs: Runs) -> Text {
        guard var attributed = try? AttributedString(
            markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(markdown).font(font).foregroundStyle(color)
        }
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            if run.link != nil {
                attributed[run.range].foregroundColor = runs.link
                if runs.linkUnderline { attributed[run.range].underlineStyle = .single }
            } else if intent.contains(.code) {
                attributed[run.range].font = runs.codeFont
                attributed[run.range].foregroundColor = runs.code
                if let chip = runs.codeChip {
                    attributed[run.range].backgroundColor = chip.background
                }
            } else if intent.contains(.stronglyEmphasized) {
                attributed[run.range].font = runs.strongFont
                if let strong = runs.strong {
                    attributed[run.range].foregroundColor = strong
                }
            }
        }
        if let chip = runs.codeChip {
            attributed = padded(attributed, chip: chip, codeFont: runs.codeFont)
        }
        // Only a paragraph that actually carries an external link is rebuilt
        // as concatenated `Text`s; everything else takes the single attributed
        // run it took before.
        guard let glyph = runs.linkGlyph,
              attributed.runs.contains(where: { $0.link.map(wantsSlot) ?? false }) else {
            return Text(attributed).font(font).foregroundStyle(color)
        }
        return slotted(attributed, glyph: glyph).font(font).foregroundStyle(color)
    }

    /// The same string as concatenated `Text`s, with `glyph` in front of every
    /// external link. One slot per LINK, not per run: a bold or coded word
    /// inside a link splits it into several runs carrying the same URL.
    private static func slotted(_ attributed: AttributedString, glyph: LinkGlyph) -> Text {
        var out = Text(verbatim: "")
        var previous: URL?
        for run in attributed.runs {
            if let link = run.link, link != previous, wantsSlot(link) {
                out = out + Text(glyph.image)
            }
            previous = run.link
            out = out + Text(AttributedString(attributed[run.range]))
        }
        return out
    }

    /// Which links get the slot: `resolveExternalWebLinkHost`
    /// (externalLinkContextMenu.ts:76-85) — an http(s) URL with a host.
    /// A `file:` link or an in-document fragment gets nothing, as upstream.
    private static func wantsSlot(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host()?.isEmpty ?? true)
    }

    /// A padding space on each side of every code run, in the run's own font
    /// and background — rebuilt rather than inserted in place so the run
    /// ranges stay valid while it happens.
    private static func padded(_ attributed: AttributedString, chip: CodeChip, codeFont: Font) -> AttributedString {
        var pad = AttributedString(" ")
        pad.font = codeFont
        pad.backgroundColor = chip.background
        // The mono space is wider than the CSS padding; `kern` is the
        // difference, so the pad's advance IS the padding.
        pad.kern = chip.padding - spaceAdvance(size: chip.fontSize)
        var out = AttributedString()
        for run in attributed.runs {
            let piece = AttributedString(attributed[run.range])
            guard (run.inlinePresentationIntent ?? []).contains(.code), run.link == nil else {
                out.append(piece)
                continue
            }
            out.append(pad)
            out.append(piece)
            out.append(pad)
        }
        return out
    }

    /// The advance of a space in the monospaced system font at `size` — the
    /// same face `Font.system(size:design:.monospaced)` renders, measured
    /// rather than assumed so the kern above lands on the CSS padding exactly.
    private static func spaceAdvance(size: Double) -> Double {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
        return NSAttributedString(string: " ", attributes: [.font: font]).size().width
    }
}
