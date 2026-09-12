import Foundation

/// The pop-out's re-measure decision (`StatusItemController.fitPinned`),
/// kept pure so its two loop guards are testable. `want` is the content's
/// ideal in whole points, `current` the window's content size, `refused`
/// the size the window last did not take (a screen clamp), `recent` the
/// sizes asked for within the last second.
public enum PopoutFit {
    /// Points; `CGSize` is not `Equatable` in this module's Foundation.
    public struct Size: Equatable, Sendable {
        public var width: Double, height: Double
        public init(width: Double, height: Double) { self.width = width; self.height = height }
    }
    public struct Ask: Equatable, Sendable {
        public var size: Size
        /// `want` was asked for within the second — the content measures
        /// differently in each of two window sizes — so the ask is the
        /// larger of the two, which clips nothing, and the loop stops.
        public var settled: Bool
    }

    /// What to ask the window for, or nil to leave it alone: the window
    /// already fits, the settled size is what it already is, or the size
    /// about to be asked for is the one it refused. The refused size is
    /// compared with the ask, not with `want`: a settled size the screen
    /// clamps differs from `want`, and matching against `want` asked for
    /// it again on every re-measure for the whole second (#229).
    public static func ask(want: Size, current: Size, refused: Size?, recent: [Size]) -> Ask? {
        func same(_ a: Size, _ b: Size) -> Bool { abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5 }
        guard !same(current, want) else { return nil }
        var ask = Ask(size: want, settled: false)
        if recent.contains(where: { same($0, want) }) {
            ask = Ask(size: Size(width: max(want.width, current.width), height: max(want.height, current.height)), settled: true)
            guard !same(ask.size, current) else { return nil }
        }
        if let refused, same(refused, ask.size) { return nil }
        return ask
    }
}
