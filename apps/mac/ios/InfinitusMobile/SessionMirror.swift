import SwiftUI
import InfinitusCore

/// #144 phase 2: the mirror a session's screens talk to. Screens reached
/// from another Mac's section set it to that Mac's mirror; everything
/// else inherits the primary. Same-body children only — a pushed
/// destination gets the environment of where its
/// `.navigationDestination` is declared, so a route carries `macId`
/// and the destination sets this itself.
private struct SessionMirrorKey: EnvironmentKey {
    static let defaultValue: NetworkFleetMirror = .shared
}

extension EnvironmentValues {
    var sessionMirror: NetworkFleetMirror {
        get { self[SessionMirrorKey.self] }
        set { self[SessionMirrorKey.self] = newValue }
    }
}

/// A session under another paired Mac's section: the Mac travels with
/// the navigation value so two Macs' feeds can sit on one stack.
struct OtherSessionRoute: Hashable {
    let macId: String
    let session: SessionDetail
}
