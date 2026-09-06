import Foundation
import InfinitusCore

/// Opens a new terminal on this Mac running an engine in a folder (#91):
/// a cmux workspace when cmux is installed, else Terminal.app through
/// AppleScript — each host driven by its own interface, never a
/// synthetic click. Then waits for the Claude session to register so
/// the phone can open its chat. Blocking; called off the main thread.
enum SessionLauncher {
    static func start(_ request: SessionStart.Request, preferredHost: String) -> SessionStart.Reply {
        let cwd = ((request.cwd as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return SessionStart.Reply(outcome: "badCwd", detail: "no such folder on the Mac: \(request.cwd)")
        }
        let command = SessionStart.shellCommand(cwd: cwd, engine: request.engine, prompt: request.prompt,
                                                resume: request.resume)
        let claudeDir = ClaudeSessions.configHome()
        let before = Set(ClaudeSessions.list(claudeDir: claudeDir).map(\.pid))
        let host: String
        do {
            if preferredHost != "terminal", let cmux = Subprocess.find(CmuxHost.candidates) {
                _ = try Subprocess.run(cmux, ["new-workspace", "--name", (cwd as NSString).lastPathComponent,
                                              "--cwd", cwd, "--command", command])
                host = "cmux"
            } else if preferredHost != "cmux" {
                let script = "tell application \"Terminal\" to do script \"\(AppleScriptEscaping.literal(command))\""
                _ = try Subprocess.run("/usr/bin/osascript", ["-e", script, "-e", "tell application \"Terminal\" to activate"])
                host = "Terminal"
            } else {
                return SessionStart.Reply(outcome: "noHost", detail: "cmux isn't installed on the Mac")
            }
        } catch {
            return SessionStart.Reply(outcome: "failed", detail: "\(error)")
        }
        guard (request.engine ?? "claude") == "claude" else {
            return SessionStart.Reply(outcome: "started", host: host)
        }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            if let fresh = ClaudeSessions.list(claudeDir: claudeDir)
                .first(where: { !before.contains($0.pid) && ($0.cwd as NSString).standardizingPath == cwd }) {
                return SessionStart.Reply(outcome: "started", host: host, pid: Int(fresh.pid))
            }
        }
        return SessionStart.Reply(outcome: "started", detail: "opened in \(host); the session hasn't registered yet",
                                  host: host)
    }
}
