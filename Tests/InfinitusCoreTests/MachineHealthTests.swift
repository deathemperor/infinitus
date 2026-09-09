import XCTest
@testable import InfinitusCore

final class MachineHealthTests: XCTestCase {
    func testWarningKindsMatchTheMutes() {
        XCTAssertEqual(MachineReport.warningKind("new hook: semgrep on PostToolUse (plugin)"), .hooks)
        XCTAssertEqual(MachineReport.warningKind("peon has 12 instances (oldest 53 min, 3 stuck)"), .hooks)
        XCTAssertEqual(MachineReport.warningKind("semgrep runs 4 commands on every PreToolUse Bash call"), .hooks)
        XCTAssertEqual(MachineReport.warningKind("temp directory holds 12000 entries (pip 9600)"), .temp)
        XCTAssertEqual(MachineReport.warningKind("temp directory listing timed out"), .temp)
        XCTAssertEqual(MachineReport.warningKind("a hook installing into ~/.claude/security/agent-sdk-venv keeps re-running pip install — 185 new temp dirs per hour; its installs die and get retried"), .hooks)
        XCTAssertEqual(MachineReport.warningKind("swap 95% full"), .other)
    }

    let ps = """
        1     0 Ss    25152 04-00:36:41   0.9 /sbin/launchd
     4120     1 S    812000    02:39:50   3.2 /Applications/Infinitus.app/Contents/MacOS/Infinitus
     5000     1 S    900000    01:00:00   0.1 claude
     5001  5000 U     30000       53:10   0.0 /bin/bash /Users/me/.claude/hooks/peon-ping/peon.sh
     5002  5001 U     20000       53:00   0.0 python3 /Users/me/.claude/hooks/peon-ping/helper.py
     5003  5000 R  140000000       55:00  99.0 bun test src/a.test.ts
     5004  5000 S     50000    03:10:00   0.0 node /x/node_modules/typescript/lib/tsc.js
     5005     1 S     10000       00:05   0.0 python3 /Users/me/.claude/hooks/cst_post_tool_use.py
      300     1 S    100000 04-00:00:00  85.0 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon
    """

    func testPSParsesColumnsAndElapsed() {
        let rows = MachineSampler.parsePS(ps)
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows[0].elapsedSeconds, 4 * 86400 + 36 * 60 + 41)
        XCTAssertEqual(rows[1].command, "/Applications/Infinitus.app/Contents/MacOS/Infinitus")
        XCTAssertEqual(rows[5].command, "bun test src/a.test.ts")
        XCTAssertEqual(MachineSampler.parseElapsed("05"), 5)
        let s = MachineSampler.summarize(rows: rows, sessionPids: [5000])
        XCTAssertEqual(s.running, 1); XCTAssertEqual(s.uninterruptible, 2)
        XCTAssertEqual(s.windowServerCPU, 85); XCTAssertEqual(s.claudeRSSMB, 900000 / 1024)
    }

    func testLoadAndSwapParse() {
        XCTAssertEqual(MachineSampler.parseLoad("{ 17.44 11.66 12.34 }").0, 17.44)
        let swap = MachineSampler.parseSwap("total = 5120.00M  used = 4126.19M  free = 993.81M  (encrypted)")
        XCTAssertEqual(swap.used, 4126); XCTAssertEqual(swap.total, 5120)
        XCTAssertEqual(MachineSampler.parseSwap("total = 40.00G  used = 39.50G  free = 0.50G").used, 40448)
    }

    func testTimedWorkGivesUpOnTheDeadline() {
        let (value, seconds) = MachineSampler.timed(0.2) { Thread.sleep(forTimeInterval: 2); return 1 }
        XCTAssertNil(value); XCTAssertLessThan(seconds, 1)
        XCTAssertEqual(MachineSampler.timed(1) { 7 }.0, 7)
    }

    func testOwnerOfConditionalCommandAndWarningsOncePerOwner() {
        XCTAssertEqual(HookInventory.owner(of: "[ -f /Users/me/.claude/hooks/x.sh ] && bash /Users/me/.claude/hooks/x.sh", source: .user).name, "x")
        let a = HookRegistration(event: "Notification", matcher: nil, command: "/Users/me/.claude/hooks/peon-ping/peon.sh", timeout: nil, source: .user)
        let b = HookRegistration(event: "Stop", matcher: nil, command: "/Users/me/.claude/hooks/peon-ping/peon.sh", timeout: nil, source: .user)
        var live = HookInventory.Live(); live.instances = 556; live.oldestSeconds = 165 * 60
        let hooks = [a, b].map { MachineReport.Hook(registration: $0, spawnsPerHour: 300, live: live) }
        let warnings = MachineReport.warnings(sample: MachineSample(), hooks: hooks, newcomers: [])
        XCTAssertEqual(warnings.filter { $0.hasPrefix("peon-ping has") }.count, 1)
    }

    func testRetryLoopWarningFromTempGrowthAndPipSpawner() {
        let then = Date(timeIntervalSince1970: 1000), now = then.addingTimeInterval(1800)
        let growth = MachineReport.tempGrowthPerHour(previous: ["pip": 100, "other": 5], previousAt: then,
                                                     current: ["pip": 130, "python": 10, "other": 5], now: now)
        XCTAssertEqual(growth["pip"], 60); XCTAssertEqual(growth["python"], 20); XCTAssertNil(growth["other"])
        let warnings = MachineReport.warnings(sample: MachineSample(), hooks: [], newcomers: [],
                                              tempGrowthPerHour: growth, pipSpawner: "security-guidance")
        XCTAssertTrue(warnings.contains("security-guidance's hook keeps re-running pip install — 80 new temp dirs per hour; its installs die and get retried"))
        // No hook tree holds the pip (spawned detached): the venv names it.
        let byTarget = MachineReport.warnings(sample: MachineSample(), hooks: [], newcomers: [],
                                              tempGrowthPerHour: growth, pipTarget: "~/.claude/security/agent-sdk-venv")
        XCTAssertTrue(byTarget.contains("a hook installing into ~/.claude/security/agent-sdk-venv keeps re-running pip install — 80 new temp dirs per hour; its installs die and get retried"))
        let venvRow = ProcessRow(pid: 12, ppid: 1, stat: "S", rssKB: 1, elapsedSeconds: 4, cpu: 0,
                                 command: "/Users/me/.claude/security/agent-sdk-venv/bin/python -m pip install --quiet claude-agent-sdk")
        XCTAssertEqual(MachineReport.pipInstallTarget(rows: [venvRow], home: "/Users/me"), "~/.claude/security/agent-sdk-venv")
        let targetRow = ProcessRow(pid: 13, ppid: 1, stat: "S", rssKB: 1, elapsedSeconds: 4, cpu: 0,
                                   command: "/usr/bin/python3 -m pip install --target /opt/libs --upgrade sdk")
        XCTAssertEqual(MachineReport.pipInstallTarget(rows: [targetRow], home: "/Users/me"), "/opt/libs")
        XCTAssertNil(MachineReport.pipInstallTarget(rows: [], home: "/Users/me"))
        XCTAssertTrue(MachineReport.warnings(sample: MachineSample(), hooks: [], newcomers: [], tempGrowthPerHour: ["pip": 8]).isEmpty)
        let rows = [
            ProcessRow(pid: 10, ppid: 1, stat: "S", rssKB: 1, elapsedSeconds: 5, cpu: 0, command: "python3 /Users/me/.claude/plugins/cache/m/security-guidance/1/hooks/ensure_agent_sdk.py"),
            ProcessRow(pid: 11, ppid: 10, stat: "S", rssKB: 1, elapsedSeconds: 4, cpu: 0, command: "/venv/bin/python -m pip install --no-cache-dir sdk"),
        ]
        let reg = HookRegistration(event: "SessionStart", matcher: nil, command: "python3 /Users/me/.claude/plugins/cache/m/security-guidance/1/hooks/ensure_agent_sdk.py", timeout: 180, source: .plugin("security-guidance"))
        XCTAssertEqual(HookInventory.spawner(of: "pip install", rows: rows, registrations: [reg]), "security-guidance")
    }

    func testScriptPathSkipsInterpretersAndExpandsHome() {
        XCTAssertEqual(HookInventory.scriptPath(in: "/bin/bash /Users/me/.claude/hooks/x.sh", home: "/Users/me"), "/Users/me/.claude/hooks/x.sh")
        XCTAssertEqual(HookInventory.scriptPath(in: "python3 ~/.claude/hooks/y.py --fast", home: "/Users/me"), "/Users/me/.claude/hooks/y.py")
        XCTAssertNil(HookInventory.scriptPath(in: "/usr/bin/env node", home: "/Users/me"))
    }

    func testHookInventoryAttributesOwnersAndCountsLiveInstances() {
        let settings: [String: Any] = ["hooks": [
            "Notification": [["hooks": [["command": "/Users/me/.claude/hooks/peon-ping/peon.sh"]]]],
            "PostToolUse": [["matcher": "Bash", "hooks": [["command": "python3 /Users/me/.claude/hooks/cst_post_tool_use.py", "timeout": 5]]]],
            "SessionStart": [["hooks": [
                ["command": "node \"/Users/me/.claude/vendor/claude-session-logger/scripts/start.js\""],
                ["command": "/opt/homebrew/opt/herdr/bin/herdr report"],
                ["command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/event.sh\""],
            ]]],
        ]]
        let regs = HookInventory.parse(settings: settings, source: .user)
        XCTAssertEqual(regs.count, 5)
        let byOwner = Dictionary(grouping: regs, by: \.owner)
        XCTAssertEqual(byOwner["peon-ping"]?.first?.ownerKind, .handInstalled)
        XCTAssertEqual(byOwner["cst"]?.first?.ownerKind, .handInstalled)
        XCTAssertEqual(byOwner["claude-session-logger"]?.first?.ownerKind, .vendored)
        XCTAssertEqual(byOwner["herdr"]?.first?.ownerKind, .brew)
        XCTAssertEqual(regs.filter { $0.ownerKind == .plugin }.count, 1)
        XCTAssertTrue(byOwner["cst"]!.first!.heavy)
        XCTAssertFalse(byOwner["peon-ping"]!.first!.heavy)
        XCTAssertEqual(HookInventory.spawnsPerHour(event: "PostToolUse", liveSessions: 9), 4050)

        let rows = MachineSampler.parsePS(ps)
        let live = HookInventory.live(of: byOwner["peon-ping"]!.first!, rows: rows)
        XCTAssertEqual(live.instances, 1); XCTAssertEqual(live.helpers, 1)
        let shared = HookInventory.live(of: byOwner["peon-ping"]!.first!, rows: rows, index: HookInventory.ProcessIndex(rows))
        XCTAssertEqual(shared.instances, 1); XCTAssertEqual(shared.helpers, 1)
        XCTAssertTrue(HookInventory.bytesContain(Array("/usr/bin/python3 /Users/x/hooks/run.sh --fast".utf8), Array("/Users/x/hooks/run.sh".utf8)))
        XCTAssertFalse(HookInventory.bytesContain(Array("/Users/x/hooks/run.s".utf8), Array("/Users/x/hooks/run.sh".utf8)))
        XCTAssertTrue(HookInventory.bytesContain(Array("abc".utf8), []))
        XCTAssertEqual(live.uninterruptible, 2); XCTAssertEqual(live.oldestSeconds, 53 * 60 + 10)

        let before = Set(regs.dropLast().map(\.id))
        XCTAssertEqual(HookInventory.newcomers(regs, since: before).map(\.owner), ["infinitus"].isEmpty ? [] : [regs.last!.owner])
    }

    func testRunawaysFlagSessionDescendantsByRule() {
        let rows = MachineSampler.parsePS(ps)
        let flagged = Runaways.flagged(rows: rows, sessionPids: [5000])
        let byPid = Dictionary(uniqueKeysWithValues: flagged.map { ($0.pid, $0) })
        XCTAssertEqual(byPid[5003]?.rule, "bun test")        // 134 GB and 55 min
        XCTAssertEqual(byPid[5003]?.sessionPid, 5000)
        XCTAssertEqual(byPid[5004]?.rule, "tsc")             // 3 h 10 min
        XCTAssertNil(byPid[4120])                            // not a session's, under the RSS ceiling
        XCTAssertEqual(Runaways.attribution(rows: rows, sessionPids: [5000])[5002], 5000)
    }

    func testResidueRulesAreOwnerDead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("residue-\(UUID().uuidString)")
        let socks = dir.appendingPathComponent("cc-socks"); let envs = dir.appendingPathComponent("session-env"); let tmp = dir.appendingPathComponent("T")
        for d in [socks, envs, tmp] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for name in ["100.sock", "200.sock", "junk.txt"] { FileManager.default.createFile(atPath: socks.appendingPathComponent(name).path, contents: Data()) }
        for name in ["live-id", "gone-id"] { try FileManager.default.createDirectory(at: envs.appendingPathComponent(name), withIntermediateDirectories: true) }
        let old = tmp.appendingPathComponent("tmp.ABCDEFGHIJ"), fresh = tmp.appendingPathComponent("tmp.KLMNOPQRST"), held = tmp.appendingPathComponent("tmp.UVWXYZABCD")
        for f in [old, fresh, held] { FileManager.default.createFile(atPath: f.path, contents: Data("x".utf8)) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: held.path)

        XCTAssertEqual(Residue.staleSockets(dir: socks.path, alive: { $0 == 100 }).map(\.path), [socks.appendingPathComponent("200.sock").path])
        XCTAssertEqual(Residue.staleSessionEnvs(dir: envs.path, liveSessionIds: ["live-id"]).map(\.path), [envs.appendingPathComponent("gone-id").path])
        let pip = tmp.appendingPathComponent("pip-unpack-abc12"), py = tmp.appendingPathComponent("TemporaryDirectory.x9"), theirs = tmp.appendingPathComponent("roadmap-report-1")
        for d in [pip, py, theirs] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false)
            FileManager.default.createFile(atPath: d.appendingPathComponent("f").path, contents: Data("y".utf8))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: d.path)
        }
        let temps = Residue.orphanTemps(dir: tmp.path, openPaths: [held.path])
        XCTAssertEqual(Set(temps.map(\.path)), [old.path, pip.path, py.path])
        XCTAssertNil(Residue.tempOwner(of: "roadmap-report-1"))
        XCTAssertEqual(Residue.reclaim(temps).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        try? FileManager.default.removeItem(at: dir)
    }

    func testKillSwitchParksAndRestoresOneOwner() throws {
        let settings: [String: Any] = ["model": "opus", "hooks": [
            "Notification": [["hooks": [["command": "/Users/me/.claude/hooks/peon-ping/peon.sh"]]]],
            "SessionStart": [["hooks": [
                ["command": "python3 /Users/me/.claude/hooks/cst_session_start.py"],
                ["command": "/Users/me/.claude/hooks/peon-ping/peon.sh"],
            ]]],
        ]]
        let (off, moved) = HookKillSwitch.disable(owner: "peon-ping", in: settings)
        XCTAssertEqual(moved, 2)
        let hooks = off["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["Notification"])
        XCTAssertEqual(((hooks?["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(HookKillSwitch.parkedOwners(in: off), ["peon-ping"])
        XCTAssertEqual(off["model"] as? String, "opus")
        let (back, restored) = HookKillSwitch.restore(owner: "peon-ping", in: off)
        XCTAssertEqual(restored, 2)
        XCTAssertNil(back[HookKillSwitch.parkedKey])
        let regs = HookInventory.parse(settings: back, source: .user)
        XCTAssertEqual(regs.filter { $0.owner == "peon-ping" }.map(\.event).sorted(), ["Notification", "SessionStart"])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
        let (backup, n) = try HookKillSwitch.apply({ HookKillSwitch.disable(owner: "cst", in: $0) }, to: url)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let reread = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(HookKillSwitch.parkedOwners(in: reread ?? [:]), ["cst"])
        try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: backup)
    }

    func testReportWarningsAndSessionIdle() {
        var sample = MachineSample(swapUsedMB: 950, swapTotalMB: 1000, uninterruptible: 300, tempListSeconds: 10)
        let reg = HookRegistration(event: "PostToolUse", matcher: nil, command: "python3 /Users/me/.claude/hooks/cst_x.py", timeout: nil, source: .user)
        var live = HookInventory.Live(); live.instances = 485; live.oldestSeconds = 53 * 60; live.uninterruptible = 224
        let hook = MachineReport.Hook(registration: reg, spawnsPerHour: 4050, live: live)
        XCTAssertTrue(hook.risky); XCTAssertTrue(hook.stuck)
        let warnings = MachineReport.warnings(sample: sample, hooks: [hook], newcomers: [reg])
        XCTAssertEqual(warnings.count, 5)
        XCTAssertTrue(warnings[0].hasPrefix("new hook: cst on PostToolUse"))
        XCTAssertTrue(warnings.contains("swap 95% full"))
        XCTAssertTrue(warnings.contains("temp directory listing timed out"))
        sample.tempEntries = 47_224; sample.tempListSeconds = 3
        XCTAssertTrue(MachineReport.warnings(sample: sample, hooks: [], newcomers: []).contains("temp directory holds 47224 entries"))
        sample.tempByOwner = ["pip": 19_600, "python": 12_814, "mktemp": 245, "other": 14_565]
        XCTAssertTrue(MachineReport.warnings(sample: sample, hooks: [], newcomers: []).contains("temp directory holds 47224 entries (pip 19600, other 14565, python 12814, mktemp 245)"))
        let fan = (1...5).map { i in
            MachineReport.Hook(registration: HookRegistration(event: "PostToolUse", matcher: "Bash", command: "python3 /Users/me/.claude/plugins/cache/m/security-guidance/1/hooks/h\(i).py", timeout: nil, source: .plugin("security-guidance")), spawnsPerHour: 450, live: .init())
        }
        XCTAssertTrue(MachineReport.warnings(sample: MachineSample(), hooks: fan, newcomers: []).contains("security-guidance runs 5 commands on every PostToolUse Bash call"))

        let now = Date()
        let s = SessionHealth(pid: 1, name: "a", cwd: "/r", rssMB: 900, ageSeconds: 4 * 86400, lastActivityAt: now.addingTimeInterval(-13 * 3600))
        XCTAssertEqual(SessionHealth.idle([s], hours: 12, announced: [], now: now).count, 1)
        XCTAssertEqual(SessionHealth.idle([s], hours: 12, announced: [1], now: now).count, 0)
        XCTAssertEqual(SessionHealth.idle([s], hours: 24, announced: [], now: now).count, 0)
        let unknown = SessionHealth(pid: 2, name: "b", cwd: "/r", rssMB: 100, ageSeconds: 4 * 86400, lastActivityAt: nil)
        XCTAssertEqual(SessionHealth.idle([unknown], hours: 12, announced: [], now: now).count, 0)
    }
}
