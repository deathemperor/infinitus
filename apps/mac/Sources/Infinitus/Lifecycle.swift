import AppKit
import os

/// The app's trail in the unified log (#54): the 2026-09-05 06:21 exit
/// left no crash report and no log line, because the app wrote none.
/// Read it back with
/// `log show --last 1d --predicate 'subsystem == "run.infinitus"'`.
/// Notices persist to the store; nothing here is user data.
enum Lifecycle {
    static let log = Logger(subsystem: "run.infinitus", category: "lifecycle")

    static func armed() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "-"
        log.notice("launching \(version, privacy: .public) (\(build, privacy: .public)) pid \(getpid())")
        NSSetUncaughtExceptionHandler { e in
            Lifecycle.log.fault("uncaught exception \(e.name.rawValue, privacy: .public): \(e.reason ?? "", privacy: .public)\n\(e.callStackSymbols.joined(separator: "\n"), privacy: .public)")
        }
        // #637: a write to a pipe whose reader already exited (the login
        // wrapper quits before the app's next line to its stdin) raised
        // SIGPIPE, whose default action ends the process with no crash
        // report and no last line. Ignored, the write returns EPIPE and
        // the writers' do/catch copes. Children don't inherit it: NSTask
        // resets dispositions (probed 2026-09-11). CI never saw the death
        // because its runner already ignores SIGPIPE and that survives exec.
        signal(SIGPIPE, SIG_IGN)
        // Off the main queue, and `_exit` (no atexit handlers, no stdio
        // flush, nothing that takes a lock), so a hung main thread still
        // dies on SIGTERM the way it did before — with one line left behind.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                Lifecycle.log.notice("signal \(sig) — exiting")
                _exit(128 + sig)
            }
            source.resume()
            sources.append(source)
        }
    }

    private nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []

    /// The process that sent the Quit Apple event, when there is one
    /// (osascript, the relaunch path, a `killall`-less quit from another
    /// app); nil for the menu's Quit and NSApp.terminate.
    static var quitSenderPID: Int32? {
        // 'spid' — keySenderPIDAttr from AEDataModel.h.
        NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(0x7370_6964))?.int32Value
    }
}
