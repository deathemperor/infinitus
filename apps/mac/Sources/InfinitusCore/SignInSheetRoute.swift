import Foundation

/// Where the OAuth page goes. macOS hands an `ASWebAuthenticationSession`
/// to the default https handler whenever that browser's Info.plist
/// declares `ASWebAuthenticationSessionWebBrowserSupportCapabilities`,
/// and only shows Safari's in-app sheet when it does not (or is Safari).
/// Google Chrome declares it, takes the request ("Received notification
/// for new request", unified log 2026-09-14 06:59) and presents nothing:
/// the request stays queued until cancelled, the user sees a flash of
/// Chrome and no page. Nothing on our side can pick the presenter, so
/// such a browser gets the URL directly — in a private window where its
/// command line has one, since the sheet's point was a fresh session.
/// The private flags are the Chromium family's only (probed on Chrome
/// 152 handed to its running instance): any other declaring browser
/// gets the page in its profile, and the companion window says so.
public enum SignInSheetRoute: Equatable, Sendable {
    /// The system sheet: Safari, or a default browser without the key.
    case systemSheet
    /// Open the URL in the default browser ourselves. `privateFlag` is
    /// the command-line switch that browser takes for a private window,
    /// nil when we know none (the page then opens in the user's profile).
    case browser(name: String, privateFlag: String?)

    public static let capabilitiesKey = "ASWebAuthenticationSessionWebBrowserSupportCapabilities"

    static let privateFlags: [String: String] = [
        "com.google.Chrome": "--incognito",
        "com.google.Chrome.beta": "--incognito",
        "com.google.Chrome.canary": "--incognito",
        "com.google.Chrome.dev": "--incognito",
        "org.chromium.Chromium": "--incognito",
        "com.brave.Browser": "--incognito",
        "com.vivaldi.Vivaldi": "--incognito",
        "company.thebrowser.Browser": "--incognito",
        "com.microsoft.edgemac": "--inprivate",
        "com.microsoft.edgemac.Beta": "--inprivate",
        "com.microsoft.edgemac.Dev": "--inprivate",
        "com.microsoft.edgemac.Canary": "--inprivate",
    ]

    /// `bundleID`, `name` and `capabilities` are the default handler's
    /// bundle identifier, display name and the Info.plist dictionary
    /// under `capabilitiesKey`; any of them nil when unknown.
    public static func classify(bundleID: String?, name: String?,
                                capabilities: [String: Any]?) -> SignInSheetRoute {
        guard let bundleID, bundleID != "com.apple.Safari" else { return .systemSheet }
        guard capabilities?["IsSupported"] as? Bool == true else { return .systemSheet }
        return .browser(name: name ?? bundleID, privateFlag: privateFlags[bundleID])
    }
}
