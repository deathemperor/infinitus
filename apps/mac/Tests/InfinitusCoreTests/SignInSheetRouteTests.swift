import XCTest
import InfinitusCore

final class SignInSheetRouteTests: XCTestCase {
    private let supported: [String: Any] = [
        "IsSupported": true, "EphemeralBrowserSessionIsSupported": true,
    ]

    func testSafariKeepsTheSystemSheet() {
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: "com.apple.Safari", name: "Safari",
                                                 capabilities: supported), .systemSheet)
    }

    func testUnknownHandlerKeepsTheSystemSheet() {
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: nil, name: nil, capabilities: nil), .systemSheet)
    }

    func testBrowserWithoutTheKeyKeepsTheSystemSheet() {
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: "org.example.browser", name: "Example",
                                                 capabilities: nil), .systemSheet)
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: "org.example.browser", name: "Example",
                                                 capabilities: ["IsSupported": false]), .systemSheet)
    }

    func testChromeGetsAnIncognitoWindow() {
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: "com.google.Chrome", name: "Google Chrome",
                                                 capabilities: supported),
                       .browser(name: "Google Chrome", privateFlag: "--incognito"))
    }

    func testEdgeGetsAnInPrivateWindow() {
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge",
                                                 capabilities: supported),
                       .browser(name: "Microsoft Edge", privateFlag: "--inprivate"))
    }

    func testDeclaringBrowserWithNoKnownFlagOpensInProfile() {
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: "org.example.browser", name: nil,
                                                 capabilities: supported),
                       .browser(name: "org.example.browser", privateFlag: nil))
    }
}

extension SignInSheetRouteTests {
    /// The runtime dictionary comes off Info.plist, where `<true/>` lands as
    /// a CFBoolean, not a Swift Bool.
    func testPlistBooleanCounts() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>IsSupported</key><true/>
        <key>EphemeralBrowserSessionIsSupported</key><true/>
        </dict></plist>
        """
        let dict = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(SignInSheetRoute.classify(bundleID: "com.google.Chrome", name: "Google Chrome",
                                                 capabilities: dict),
                       .browser(name: "Google Chrome", privateFlag: "--incognito"))
    }
}
