import Foundation

/// Text-vs-emoji presentation for theme glyphs bound for iOS (see
/// InfinitusUI.PopupGlyph, which applies this on the phone and is the
/// identity on the Mac): appends U+FE0E to every emoji-capable scalar
/// that isn't already emoji-presentation, so ⚔ / ⏸ draw as monochrome
/// text on both platforms.
public enum GlyphText {
    public static func textPresentation(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            out.append(scalar)
            guard scalar.properties.isEmoji, !scalar.properties.isEmojiPresentation else { continue }
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if next?.value != 0xFE0F, next?.value != 0xFE0E {
                out.append(Unicode.Scalar(0xFE0E)!)
            }
        }
        return String(out)
    }
}
