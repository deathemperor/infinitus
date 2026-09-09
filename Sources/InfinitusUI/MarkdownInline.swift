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
    }

    /// The inline-code chip, `.chat-markdown :not(pre) > code`
    /// (index.css:1792-1799): a 6 px-radius box on `--muted` with a
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

    static func text(_ markdown: String, font: Font, color: Color, runs: Runs) -> Text {
        guard var attributed = try? AttributedString(
            markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(markdown).font(font).foregroundStyle(color)
        }
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            if run.link != nil {
                attributed[run.range].foregroundColor = runs.link
                attributed[run.range].underlineStyle = .single
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
        return Text(attributed).font(font).foregroundStyle(color)
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
