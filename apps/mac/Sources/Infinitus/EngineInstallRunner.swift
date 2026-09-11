import Foundation
import InfinitusCore

/// Running the engine install from the first-run card (#871).
///
/// The plan is `EngineInstallPlan`'s; this only spawns what it names, one
/// step at a time, and reports the last line worth reading. Both steps are
/// minutes long, so a silent window would read as a hang.
///
/// The engine binary is resolved once at launch (`AppModel.swapd` is a
/// `let`), so a finished install ends in "relaunch", not a live swap.
@MainActor final class EngineInstallRunner: ObservableObject {
    enum State: Equatable {
        case idle
        /// Running `step`; `line` is the newest thing the tool said.
        case running(step: EngineInstallStep, line: String?)
        /// The tool's own last words, never a bare exit code.
        case failed(String)
        /// Installed at this path — the card now offers a relaunch.
        case installed(String)
        /// Nothing the app can run: the user has to bring a toolchain.
        case blocked(EngineInstallBlocker)
    }

    @Published private(set) var state: State = .idle

    var isRunning: Bool { if case .running = state { return true }; return false }

    private var task: Task<Void, Never>?

    /// Where the child looks for tools: a GUI app inherits a bare PATH, and
    /// cargo needs its own bin plus the linker Homebrew and the CLT put on
    /// there. Everything else (HOME above all) is inherited as-is.
    private static func childEnvironment(home: String = NSHomeDirectory()) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = ["\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extras.filter { !existing.contains($0) } + existing).joined(separator: ":")
        // cargo's progress bars redraw a single line; plain output is what
        // `EngineInstallProgress.label` reads.
        env["CARGO_TERM_COLOR"] = "never"
        env["CARGO_TERM_PROGRESS_WHEN"] = "never"
        return env
    }

    func start() {
        guard task == nil else { return }
        let plan = EngineInstallPlan.make(engine: SwapdLocator.locate(),
                                          cargo: EngineToolLocator.locate(EngineToolLocator.cargoCandidates()),
                                          brew: EngineToolLocator.locate(EngineToolLocator.brewCandidates))
        if let blocker = plan.blocker {
            state = .blocked(blocker)
            return
        }
        guard plan.isRunnable else { return }
        state = .running(step: plan.steps[0], line: nil)
        task = Task { [weak self] in
            await self?.run(plan)
            await MainActor.run { self?.task = nil }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning { state = .idle }
    }

    private func run(_ plan: EngineInstallPlan) async {
        for step in plan.steps {
            if Task.isCancelled { return }
            state = .running(step: step, line: nil)
            // Re-resolved per step: brew has just put cargo on disk.
            let cargo = EngineToolLocator.locate(EngineToolLocator.cargoCandidates())
            let brew = EngineToolLocator.locate(EngineToolLocator.brewCandidates)
            guard let command = EngineInstallPlan.command(step, cargo: cargo, brew: brew) else {
                state = .failed("\(step.title) failed: the tool it needs is not on this Mac.")
                return
            }
            let result = await Self.spawn(command, environment: Self.childEnvironment()) { [weak self] line in
                Task { @MainActor in
                    guard let self, case .running = self.state,
                          let label = EngineInstallProgress.label(for: line) else { return }
                    self.state = .running(step: step, line: label)
                }
            }
            if Task.isCancelled { return }
            guard result.status == 0 else {
                state = .failed(EngineInstallProgress.failure(step: step, output: result.output,
                                                              status: result.status))
                return
            }
        }
        guard let installed = SwapdLocator.locate() else {
            state = .failed("The install finished but no swapd binary turned up in "
                            + "~/.cargo/bin. Open a terminal and run `swapd version`.")
            return
        }
        state = .installed(installed)
    }

    private struct Run { let status: Int32; let output: [String] }

    /// One child, its two streams merged and read line by line. The blocking
    /// Process dance stays off the async executor, as `SwapdCLI.run` does.
    private static func spawn(_ command: EngineInstallCommand, environment: [String: String],
                              onLine: @escaping (String) -> Void) async -> Run {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: Run(status: -1, output: ["\(error)"]))
                    return
                }
                var output: [String] = []
                var carry = ""
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    carry += String(decoding: chunk, as: UTF8.self)
                    while let newline = carry.firstIndex(of: "\n") {
                        let line = String(carry[carry.startIndex..<newline])
                        carry = String(carry[carry.index(after: newline)...])
                        // The tail is all the failure message needs, and an
                        // unbounded log of a ten-minute build is not worth
                        // the memory.
                        output.append(line)
                        if output.count > 200 { output.removeFirst() }
                        onLine(line)
                    }
                }
                if !carry.isEmpty { output.append(carry); onLine(carry) }
                process.waitUntilExit()
                cont.resume(returning: Run(status: process.terminationStatus, output: output))
            }
        }
    }
}
