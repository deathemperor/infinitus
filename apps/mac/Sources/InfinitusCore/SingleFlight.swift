import Foundation

/// One pass at a time, with coalescing (#1310 finding 5): a caller that
/// arrives while a pass runs gets one more pass after it — never a
/// concurrent one, never a stale one — and every caller arriving during
/// the same pass shares that one follow-up. `run` returns once the pass
/// that started after the call has completed, so a control verb that
/// wrote to an engine and then refreshes reads its own write.
public actor SingleFlight {
    private var inFlight: Task<Void, Never>?
    private var followUp: Task<Void, Never>?

    public init() {}

    public func run(_ work: @escaping @Sendable () async -> Void) async {
        if let inFlight {
            if let followUp {
                await followUp.value
                return
            }
            let follow = Task {
                await inFlight.value
                await work()
            }
            followUp = follow
            await follow.value
            settle(follow)
            return
        }
        let pass = Task { await work() }
        inFlight = pass
        await pass.value
        settle(pass)
    }

    /// Whichever awaiter resumes first clears the finished pass; a
    /// follow-up becomes the pass in flight, and its own awaiters clear
    /// it the same way. Both resume orders leave the slots clean.
    private func settle(_ done: Task<Void, Never>) {
        if followUp == done { followUp = nil }
        if inFlight == done {
            inFlight = followUp
            followUp = nil
        }
    }
}
