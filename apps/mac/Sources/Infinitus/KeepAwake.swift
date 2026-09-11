import Foundation
import IOKit.pwr_mgt

/// Prevents idle sleep while Claude Code sessions are mid-turn — the
/// native `caffeinate`, in-process (the Caffeine.app path was dropped
/// 2026-08-29: it meant writing another app's prefs). `display` is what
/// a caffeine app does: the screen stays on too (an idle-display
/// assertion implies the system one); off, the screen may go dark while
/// the agents keep working. The user still ran Caffeine beside the
/// system-only assertion (#455). Visible in `pmset -g assertions` as
/// "Infinitus: Claude Code sessions working".
@MainActor
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private(set) var active = false
    private var activeDisplay = false

    func update(wanted: Bool, display: Bool, busyCount: Int) {
        let should = wanted && busyCount > 0
        if active, !should || activeDisplay != display {
            IOPMAssertionRelease(assertionID)
            active = false
        }
        guard should, !active else { return }
        var id: IOPMAssertionID = 0
        let type = display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let rc = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Infinitus: Claude Code sessions working" as CFString, &id)
        if rc == kIOReturnSuccess {
            assertionID = id
            active = true
            activeDisplay = display
        }
    }
}
