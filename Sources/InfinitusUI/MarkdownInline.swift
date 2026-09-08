import SwiftUI

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
            } else if intent.contains(.stronglyEmphasized) {
                attributed[run.range].font = runs.strongFont
                if let strong = runs.strong {
                    attributed[run.range].foregroundColor = strong
                }
            }
        }
        return Text(attributed).font(font).foregroundStyle(color)
    }
}
