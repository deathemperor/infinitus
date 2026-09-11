import XCTest
@testable import InfinitusCore

final class LockPolicyTests: XCTestCase {
    func testOffByDefaultNeverLocks() {
        var p = LockPolicy()
        XCTAssertFalse(p.enabled)
        XCTAssertFalse(p.needsUnlock)
        XCTAssertEqual(p.relock, .oneHour)
        p.hidden(); p.sleep(); p.tick(at: 1_000_000)
        XCTAssertFalse(p.needsUnlock, "off: no event locks")
        p.unlocked(at: 5)
        XCTAssertNil(p.lastActivity, "off: nothing to unlock, nothing recorded")
    }

    func testEnablingLocksAndUnlockClears() {
        var p = LockPolicy(enabled: true)
        XCTAssertTrue(p.needsUnlock, "a launch with the setting on starts locked")
        p.unlocked(at: 100)
        XCTAssertFalse(p.needsUnlock)
        XCTAssertEqual(p.lastActivity, 100)
        p.lock()
        XCTAssertTrue(p.needsUnlock)
        XCTAssertNil(p.lastActivity)

        var q = LockPolicy()
        q.setEnabled(true)
        XCTAssertTrue(q.needsUnlock, "turning it on locks until the first unlock")
    }

    func testTimedRelockCountsFromLastActivity() {
        var p = LockPolicy(enabled: true, relock: .fiveMinutes)
        p.unlocked(at: 1_000)
        p.tick(at: 1_299)
        XCTAssertFalse(p.needsUnlock, "one second short")
        p.activity(at: 1_299)
        XCTAssertEqual(p.lastActivity, 1_299, "an interaction extends the window")
        p.tick(at: 1_598)
        XCTAssertFalse(p.needsUnlock)
        p.tick(at: 1_599)
        XCTAssertTrue(p.needsUnlock, "exactly the interval locks")
        XCTAssertNil(p.lastActivity)
        p.activity(at: 1_600)
        XCTAssertTrue(p.needsUnlock, "activity while locked records nothing and never unlocks")
        XCTAssertNil(p.lastActivity)
    }

    func testOneHourIsTheDefaultAndLocksAtTheHour() {
        var p = LockPolicy(enabled: true)
        p.unlocked(at: 0)
        p.wake(at: 3_599)
        XCTAssertFalse(p.needsUnlock)
        p.wake(at: 3_600)
        XCTAssertTrue(p.needsUnlock)
    }

    func testImmediatelyLocksWhenTheSurfaceHidesAndOnSleep() {
        var p = LockPolicy(enabled: true, relock: .immediately)
        p.unlocked(at: 10)
        p.tick(at: 10_000_000)
        XCTAssertFalse(p.needsUnlock, "immediately is not a timer")
        p.hidden()
        XCTAssertTrue(p.needsUnlock)
        p.unlocked(at: 20)
        p.sleep()
        XCTAssertTrue(p.needsUnlock)
    }

    func testOnSleepLocksOnSleepOnly() {
        var p = LockPolicy(enabled: true, relock: .onSleep)
        p.unlocked(at: 10)
        p.tick(at: 10 + 7 * 86_400)
        p.hidden()
        XCTAssertFalse(p.needsUnlock, "neither time nor hiding locks")
        p.sleep()
        XCTAssertTrue(p.needsUnlock)
    }

    func testTimedModeIgnoresSleepButTheWakeTickCatchesUp() {
        var p = LockPolicy(enabled: true, relock: .oneHour)
        p.unlocked(at: 0)
        p.sleep()
        XCTAssertFalse(p.needsUnlock, "a short nap keeps a timed unlock")
        p.wake(at: 600)
        XCTAssertFalse(p.needsUnlock)
        p.sleep()
        p.wake(at: 4_000)
        XCTAssertTrue(p.needsUnlock, "a long sleep passed the hour")
    }

    func testDisablingClearsEverything() {
        var p = LockPolicy(enabled: true, relock: .fiveMinutes)
        p.setEnabled(false)
        XCTAssertFalse(p.enabled)
        XCTAssertFalse(p.needsUnlock)
        XCTAssertNil(p.lastActivity)
        XCTAssertEqual(p.relock, .fiveMinutes, "the re-lock choice survives a toggle")
    }

    func testRelockLabelsAndDefault() {
        XCTAssertEqual(LockPolicy.Relock.allCases.map(\.label), ["immediately", "5 min", "1 h", "on sleep"])
        XCTAssertEqual(LockPolicy.Relock.default, .oneHour)
        XCTAssertEqual(LockPolicy.Relock(rawValue: -1), .onSleep)
    }

    func testLockSettingDecodesStoredValues() {
        XCTAssertEqual(LockSetting.enabledKey, "biometric_lock")
        XCTAssertEqual(LockSetting.relockKey, "biometric_relock")
        XCTAssertFalse(LockSetting.enabled(stored: nil))
        XCTAssertFalse(LockSetting.enabled(stored: "yes"))
        XCTAssertTrue(LockSetting.enabled(stored: true))
        XCTAssertEqual(LockSetting.relock(stored: nil), .oneHour)
        XCTAssertEqual(LockSetting.relock(stored: 300), .fiveMinutes)
        XCTAssertEqual(LockSetting.relock(stored: 42), .oneHour, "an unknown number falls back")
        XCTAssertEqual(LockSetting.relock(stored: -1), .onSleep)
    }
}
