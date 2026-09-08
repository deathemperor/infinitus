/// T3's four visual states plus the resting one (`threadListV2.ts`
/// `resolveThreadListV2Status`): approval outranks input outranks a
/// running session outranks a failed one.
public enum T3ThreadStatus: String, Sendable, CaseIterable {
    case approval, input, working, failed, ready

    public init(_ t: T3Thread) {
        if t.hasPendingApprovals { self = .approval }
        else if t.hasPendingUserInput { self = .input }
        else if t.session?.status == .running || t.session?.status == .starting { self = .working }
        else if t.session?.status == .error { self = .failed }
        else { self = .ready }
    }

    /// The same rule over Infinitus facts (spec §2.2).
    public init(facts: SessionFacts) {
        if facts.hasPendingApprovals { self = .approval }
        else if facts.hasPendingUserInput { self = .input }
        else if facts.status == .running || facts.status == .starting { self = .working }
        else if facts.status == .error { self = .failed }
        else { self = .ready }
    }
}
