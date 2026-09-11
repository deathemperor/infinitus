import XCTest
@testable import InfinitusCore

/// `T3TailwindPalette.generated.swift` is the only place a Tailwind stop may
/// come from, so this pins one known stop end to end: the vendored
/// tailwindcss@4.3.3 `theme.css:122` declares
/// `--color-sky-400: oklch(74.6% 0.16 232.661);`, which
/// `gen-tokens.py`'s `oklch_to_rgb` (the same function every other token goes
/// through) resolves to sRGB (0, 188, 255).
///
/// The point of the assertion is that v4 is NOT v3: Tailwind v3's
/// `colors.js` had `sky-400: #38bdf8` = (56, 189, 248), which is what the
/// two hand-typed tables here used to carry before the generator took over.
final class T3TailwindPaletteTests: XCTestCase {
    func testSky400ComesFromTheV4OKLCHStopNotV3Hex() {
        XCTAssertEqual(T3Tailwind.sky400, T3ProjectIcon.RGB(0, 188, 255))
        XCTAssertNotEqual(T3Tailwind.sky400, T3ProjectIcon.RGB(56, 189, 248))   // v3 #38bdf8
    }

    /// The project-icon table reads the generated stops rather than its own
    /// literals (`ProjectFavicon.tsx`'s `PROJECT_ICON_COLOR_BY_NAME`:
    /// `cloud` is `text-sky-600 dark:text-sky-400`).
    func testProjectIconColoursReadTheGeneratedStops() {
        let cloud = T3ProjectIcon.color(for: .cloud)
        XCTAssertEqual(cloud.light, T3Tailwind.sky600)
        XCTAssertEqual(cloud.dark, T3Tailwind.sky400)
    }
}
