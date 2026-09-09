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
    /// The checked-out branch name, or nil when `cwd` is not a work tree or
    /// HEAD is detached. Read straight from the repo's HEAD file — a git
    /// spawn per cwd per minute was the project list's largest idle cost
    /// (#346), and this works where there are no child processes at all.
    /// `cwd` may be anywhere inside the work tree; a linked worktree's
    /// `.git` is a file naming its git dir.
    public static func branch(cwd: String) -> String? {
        guard let head = headFile(cwd: cwd),
              let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: ") else { return nil }
        let ref = String(line.dropFirst("ref: ".count))
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    /// `<git dir>/HEAD` for the work tree containing `cwd`: the first
    /// ancestor with a `.git` entry — a directory, or a file whose one
    /// line is `gitdir: <path>` (linked worktrees, submodules).
    static func headFile(cwd: String) -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dotGit.appendingPathComponent("HEAD") }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first,
                      line.hasPrefix("gitdir: ") else { return nil }
                let path = String(line.dropFirst("gitdir: ".count))
                let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                    : dir.appendingPathComponent(path).standardizedFileURL
                return gitDir.appendingPathComponent("HEAD")
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { return nil }
            dir = parent
        }
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
