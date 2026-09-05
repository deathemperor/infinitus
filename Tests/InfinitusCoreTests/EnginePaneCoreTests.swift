import XCTest
@testable import InfinitusCore

final class EnginePaneCoreTests: XCTestCase {
    func testEngineCatalogCapabilitiesVsLiveEngines() {
        XCTAssertEqual(EngineCatalog.capabilities(for: "cswap"), CswapEngine(cli: CswapCLI(binaryPath: "/nonexistent")).capabilities)
        XCTAssertEqual(EngineCatalog.capabilities(for: "cswap"), EngineCapabilities.all)

        let cliproxy = CLIProxyEngine(managementKey: "test")
        XCTAssertEqual(EngineCatalog.capabilities(for: "cliproxy"), cliproxy.capabilities)
        XCTAssertEqual(EngineCatalog.capabilities(for: "cliproxy"), [.switch, .hold, .rename, .remove, .addOAuth, .costReport, .prefer])

        let nr = NineRouterEngine(password: "test")
        XCTAssertEqual(EngineCatalog.capabilities(for: "9router"), nr.capabilities)
        XCTAssertEqual(EngineCatalog.capabilities(for: "9router"), [.switch, .hold, .remove])
    }

    func testSettingsFormLabels() {
        XCTAssertEqual(SettingsFormLabels.sectionTitle("autoswitch"), "Auto-switch")
        XCTAssertEqual(SettingsFormLabels.sectionTitle("ui"), "Interface")
        XCTAssertEqual(SettingsFormLabels.sectionTitle("misc"), "Misc")
        XCTAssertEqual(SettingsFormLabels.sectionTitle("other"), "Other")

        XCTAssertEqual(SettingsFormLabels.humanLabel("autoswitch.limitScanIntervalSeconds"), "Limit scan interval seconds")
        XCTAssertEqual(SettingsFormLabels.humanLabel("threshold"), "Threshold")
    }

    func testJSONValueEditableText() {
        XCTAssertEqual(JSONValue.null.editableText, "")
        XCTAssertEqual(JSONValue.bool(true).editableText, "true")
        XCTAssertEqual(JSONValue.bool(false).editableText, "false")
        XCTAssertEqual(JSONValue.number(42).editableText, "42")
        XCTAssertEqual(JSONValue.number(42.5).editableText, "42.5")
        XCTAssertEqual(JSONValue.string("alpha").editableText, "alpha")
        XCTAssertEqual(JSONValue.array([]).editableText, "")
        XCTAssertEqual(JSONValue.object([:]).editableText, "")
    }

    func testProxyRoutingNotes() {
        XCTAssertEqual(ProxyRoutingNotes.explainer(strategy: "round-robin"), "Each request goes to the next credential in turn.")
        XCTAssertEqual(ProxyRoutingNotes.explainer(strategy: "weighted-round-robin"), "Requests rotate in proportion to each credential's priority.")
        XCTAssertEqual(ProxyRoutingNotes.explainer(strategy: nil), "Read from the proxy on the next refresh.")
        XCTAssertTrue(ProxyRoutingNotes.explainer(strategy: "fill-first").contains("Highest priority wins"))

        XCTAssertNil(ProxyRoutingNotes.affinityWarning(strategy: "fill-first", affinity: true))
        XCTAssertNil(ProxyRoutingNotes.affinityWarning(strategy: "fill-first", affinity: false))
        XCTAssertNil(ProxyRoutingNotes.affinityWarning(strategy: nil, affinity: nil))

        let warnNil = ProxyRoutingNotes.affinityWarning(strategy: "round-robin", affinity: nil)
        XCTAssertTrue(warnNil?.contains("Turn on session-affinity in the proxy's config") == true)

        let warnFalse = ProxyRoutingNotes.affinityWarning(strategy: "round-robin", affinity: false)
        XCTAssertTrue(warnFalse?.contains("Turn on session affinity so a conversation stays") == true)

        let warnTrue = ProxyRoutingNotes.affinityWarning(strategy: "round-robin", affinity: true)
        XCTAssertTrue(warnTrue?.contains("Under affinity, Switch only steers new sessions") == true)
    }

    func testClaudeCodeConfigStandardHome() {
        #if os(Windows)
        let cfg = ClaudeCodeConfig.standard(home: "C:\\Users\\MockUser")
        XCTAssertTrue(cfg.userSettingsURL.path.contains(".claude") && cfg.userSettingsURL.path.hasSuffix("settings.json"))
        XCTAssertTrue(cfg.managedSettingsURL.path.contains(".infinitus-no-managed-settings"))
        #else
        let cfg = ClaudeCodeConfig.standard(home: "/Users/mock")
        XCTAssertEqual(cfg.userSettingsURL.path, "/Users/mock/.claude/settings.json")
        #endif
    }
}
