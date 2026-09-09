import ActivityKit
import Foundation
import InfinitusCore

// The two Live Activities' attributes. Their content states are
// InfinitusCore's `WorkingActivityState` / `RevivalActivityState` — the
// same structs the Mac encodes into APNs pushes, so a push and an
// in-app update carry identical JSON. The attributes are fixed for an
// activity's life; the Mac's push-to-start sends them as `attributes`.

/// A card belongs to one Mac (#144): `macId` is the key the phone files
/// that Mac under (`LiveActivities.macKey`, the hash of its pair token),
/// `machine` its name. `macId` is nil on a card from before the key —
/// or one a Mac started before it learned it — and the name decides.
protocol MacCard: ActivityAttributes {
    var machine: String { get }
    var macId: String? { get }
}

struct RevivalActivity: MacCard {
    typealias ContentState = RevivalActivityState
    var machine: String
    var macId: String?
}

struct WorkingActivity: MacCard {
    typealias ContentState = WorkingActivityState
    var machine: String
    var macId: String?
}
