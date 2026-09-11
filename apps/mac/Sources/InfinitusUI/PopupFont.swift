import SwiftUI

/// Font sizes pinned to the Mac popup's point sizes — SwiftUI's semantic
/// text styles (`.caption`, `.body`, …) resolve larger on iOS than on
/// macOS, which made the iPhone render every row bigger than the Mac
/// popup. On macOS these are exactly the semantic style (bit-identical to
/// before); on iOS they're the matching fixed point size.
public enum PopupFont {
    public static var caption: Font {
        #if os(macOS)
        .caption
        #else
        .system(size: 10)
        #endif
    }

    public static var caption2: Font {
        #if os(macOS)
        .caption2
        #else
        .system(size: 10)
        #endif
    }

    public static var body: Font {
        #if os(macOS)
        .body
        #else
        .system(size: 13)
        #endif
    }
}
