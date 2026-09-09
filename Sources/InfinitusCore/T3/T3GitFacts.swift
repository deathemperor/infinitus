import Foundation

/// The git facts the composer's context strip reads (`BranchToolbar.tsx`).
/// Upstream gets them from its own server's repo projection; this port asks
/// git itself, once per thread switch — never on a timer, and never on the
/// main actor.
///
/// `T3FileMention.gitListed`'s rules apply verbatim: `/usr/bin/env git` under
/// a five-second killer, locks and prompts off, and nil on every platform
/// that has no child processes.
public enum T3GitFacts {
    /// The checked-out branch name, or nil when `cwd` is not a work tree, git
    /// is missing, or HEAD is detached (`rev-parse --abbrev-ref` answers
    /// `HEAD` there, which is not a branch to show). Blocking.
    public static func branch(cwd: String) -> String? {
        guard let out = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    static func run(_ arguments: [String], cwd: String) -> String? {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return nil
        #else
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
        #endif
    }

    /// `resolveLockedWorkspaceLabel` (`BranchToolbar.logic.ts:93-95`): the
    /// strip's left control names the workspace the thread runs in. B has no
    /// worktree mode, so every thread is the checkout itself.
    public static func workspaceLabel(worktreePath: String?) -> String {
        worktreePath == nil ? "Local checkout" : "Worktree"
    }
}
