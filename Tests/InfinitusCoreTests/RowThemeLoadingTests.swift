import XCTest
@testable import InfinitusCore

final class RowThemeLoadingTests: XCTestCase {
    func testEveryThemedBuiltinNamesEveryPlaceholderWithAMovingIcon() {
        let motions: Set<String> = ["spin", "pulse", "bounce", "flicker"]
        for theme in RowTheme.builtins where !theme.plain {
            for key in RowTheme.plainLoadingWords.keys {
                XCTAssertNotNil(theme.loadingWords[key], "\(theme.id) lacks \(key)")
                XCTAssertNotEqual(theme.loadingWord(key), RowTheme.plainLoadingWords[key], "\(theme.id) keeps the plain \(key)")
            }
            XCTAssertTrue(theme.loadingIcon.hasPrefix("sf:"), "\(theme.id) icon \(theme.loadingIcon)")
            XCTAssertTrue(motions.contains(theme.loadingMotion), "\(theme.id) motion \(theme.loadingMotion)")
        }
    }

    func testEveryBuiltInThemeNamesTheTeamTab() {
        XCTAssertEqual(RowTheme.plainTabLabels["team"], "Team")
        XCTAssertTrue(RowTheme.plainTabIcons["team"]?.hasPrefix("sf:") == true)
        for theme in RowTheme.builtins where !theme.tabLabels.isEmpty {
            XCTAssertNotNil(theme.tabLabels["team"], "\(theme.id) names sessions/fleet/settings but not team")
            XCTAssertNotNil(theme.tabIcons["team"], "\(theme.id) lacks a team icon")
        }
    }

    func testOffAndUnthemedKeysFallBackToThePlainWords() {
        XCTAssertEqual(RowTheme.off.loadingWord("loading"), "Loading…")
        XCTAssertEqual(RowTheme.off.loadingWord("searching"), "Looking for the Mac…")
        XCTAssertEqual(RowTheme.off.loadingIcon, "")
        var partial = RowTheme.rpg
        partial.loadingWords = ["loading": "Rolling…"]
        XCTAssertEqual(partial.loadingWord("loading"), "Rolling…")
        XCTAssertEqual(partial.loadingWord("empty"), "Nothing here yet")
    }

    func testDecodeWithoutTheKeysKeepsThePlainPlaceholders() throws {
        let json = #"{"id": "x", "name": "X"}"#.data(using: .utf8)!
        let theme = try JSONDecoder().decode(RowTheme.self, from: json)
        XCTAssertTrue(theme.loadingWords.isEmpty)
        XCTAssertEqual(theme.loadingWord("noSessions"), "No live sessions")
        XCTAssertEqual(theme.loadingMotion, "")
        XCTAssertEqual(theme.rateIcon, "")
        XCTAssertEqual(theme.rateLabel, "")
        XCTAssertNil(theme.rateUnit)
    }

    func testEveryThemedBuiltinNamesTheRate() {
        for theme in RowTheme.builtins where !theme.plain {
            XCTAssertFalse(theme.rateIcon.isEmpty, "\(theme.id) lacks a rate icon")
            XCTAssertFalse(theme.rateLabel.isEmpty, "\(theme.id) lacks a rate unit")
            XCTAssertLessThanOrEqual(theme.rateLabel.count, 9, "\(theme.id) rate unit widens the footer chip")
            XCTAssertNotEqual(theme.rateIcon, theme.creditLabel, "\(theme.id) rate icon collides with the credit label")
        }
        XCTAssertNil(RowTheme.off.rateGlyph)
    }

    func testRateReadoutsSpeakTheTheme() {
        let rate = TokenRate(perMinute: 1234, peakPerMinute: 2000)
        XCTAssertEqual(rate.label, "1.2k/min")
        XCTAssertEqual(rate.label(theme: .off), "1.2k/min")
        XCTAssertEqual(rate.label(theme: .rpg), "1.2k mana/min")
        XCTAssertEqual(TokenRate(perMinute: 340, peakPerMinute: 340).label(theme: .cyber), "340 baud")
        XCTAssertEqual(Stats.Presentation.perMinute(12_345), "12.3k tok/min")
        XCTAssertEqual(Stats.Presentation.perMinute(12_345, theme: .cyber), "12.3k baud")
        XCTAssertEqual(Stats.Presentation.recordTitle(theme: .off), "Tokens/min records")
        XCTAssertEqual(Stats.Presentation.recordTitle(theme: .rpg), "Mana/min records")
        XCTAssertTrue(Stats.Presentation.groups(Stats.Summary(period: .week, from: "2026-09-01", to: "2026-09-07", total: Stats.Day(), previous: Stats.Day(), daily: [], streak: 0), theme: .rpg).flatMap { $0.tiles.map(\.id) }.contains("Peak mana/min"))
    }

    func testTemplateCarriesThePlaceholderFields() throws {
        let themes = try JSONDecoder().decode([RowTheme].self, from: RowTheme.templateJSON.data(using: .utf8)!)
        let synth = try XCTUnwrap(themes.first)
        XCTAssertEqual(synth.loadingWord("loading"), "Booting the grid…")
        XCTAssertEqual(synth.loadingIcon, "sf:waveform")
        XCTAssertEqual(synth.loadingMotion, "pulse")
        XCTAssertEqual(synth.rateIcon, "🎛")
        XCTAssertEqual(synth.rateLabel, "bpm")
    }
}
