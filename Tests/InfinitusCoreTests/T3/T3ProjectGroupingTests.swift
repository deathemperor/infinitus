import XCTest
@testable import InfinitusCore

final class T3ProjectGroupingTests: XCTestCase {
    typealias G = T3ProjectGrouping
    let local = G.Project(id: "p-lim", environmentId: "mac-1", name: "limitless", cwd: "/Users/x/death/limitless")
    let remote = G.Project(id: "p-lim-r", environmentId: "mac-2", name: "limitless", cwd: "/home/y/limitless")
    let other = G.Project(id: "p-ban", environmentId: "mac-1", name: "banyan", cwd: "/Users/x/death/banyan")

    func testLogicalModeMergesSameFolderNameAcrossEnvironments() {
        let g = G.groups(projects: [local, remote, other], settings: .init(), primaryEnvironmentId: "mac-1") { $0 == "mac-2" ? "Studio" : nil }
        XCTAssertEqual(g.map(\.displayName), ["limitless", "banyan"])
        XCTAssertEqual(g[0].members.map(\.id), ["p-lim", "p-lim-r"])
        XCTAssertEqual(g[0].representative.id, "p-lim")                 // the primary environment's member leads
        XCTAssertEqual(g[0].environmentPresence, .mixed); XCTAssertEqual(g[0].remoteEnvironmentLabels, ["Studio"])
        XCTAssertEqual(g[1].environmentPresence, .localOnly); XCTAssertEqual(g[1].remoteEnvironmentLabels, [])
    }
    func testPhysicalModeAndOverridesSplitGroups() {
        let g = G.groups(projects: [local, remote], settings: .init(mode: .physical), primaryEnvironmentId: "mac-1") { _ in nil }
        XCTAssertEqual(g.count, 2)
        // overrides are keyed by `physicalKey`, matching upstream's `deriveProjectGroupingOverrideKey`.
        let o = G.groups(projects: [local, remote], settings: .init(mode: .logical, overrides: [G.physicalKey(local): .physical]), primaryEnvironmentId: "mac-1") { _ in nil }
        XCTAssertEqual(o.count, 2)
    }
    func testNoPrimaryEnvironmentIsLocalOnly() {
        let g = G.groups(projects: [local, remote], settings: .init(), primaryEnvironmentId: nil) { _ in "X" }
        XCTAssertEqual(g[0].environmentPresence, .localOnly); XCTAssertEqual(g[0].remoteEnvironmentLabels, [])
    }
    // Representative selection is a separate lookup from member order: when the primary
    // environment's member is not first in insertion order, `members` keeps insertion order
    // (matches upstream) while `representative` still resolves to the primary-environment member.
    func testRepresentativeIsThePrimaryEnvironmentMemberEvenWhenNotFirstInInsertionOrder() {
        let g = G.groups(projects: [remote, local], settings: .init(), primaryEnvironmentId: "mac-1") { _ in nil }
        XCTAssertEqual(g[0].members.map(\.id), ["p-lim-r", "p-lim"])  // insertion order preserved
        XCTAssertEqual(g[0].representative.id, "p-lim")               // but the primary environment leads
    }
    func testPickerEntriesRotatePreferredToFront() {
        let g = G.groups(projects: [other, local, remote], settings: .init(), primaryEnvironmentId: "mac-1") { _ in nil }
        let e = G.pickerEntries(groups: g, preferred: (environmentId: "mac-2", projectId: "p-lim-r"))
        XCTAssertEqual(e.map(\.group.displayName), ["limitless", "banyan"])
        XCTAssertTrue(e[0].isPreferred); XCTAssertEqual(e[0].target.id, "p-lim-r"); XCTAssertEqual(e[1].target.id, "p-ban")
        XCTAssertEqual(G.pickerEntries(groups: g, preferred: nil).map(\.isPreferred), [false, false])
    }

    // The `it`s below transcribe `packages/client-runtime/src/state/projectGrouping.test.ts`'s
    // `buildProjectGroups` describe (the load-balancing describe in the same file tests an
    // unrelated export and is skipped). `T3ProjectGrouping.Project` is the typed port's own
    // trimmed record — no `repositoryIdentity`, `updatedAt`/`createdAt`, or the physical-path
    // freshness dedup that lets several stale registrations at one path collapse to the newest;
    // the five `it`s that specifically exercise that machinery aren't expressible and are noted,
    // not silently dropped.

    // "preserves every physical clone as a selectable member in repository modes"
    func testPreservesEveryCloneAsASelectableMemberInLogicalMode() {
        let a = G.Project(id: "t3code", environmentId: "e", name: "t3code", cwd: "/work/t3code")
        let b = G.Project(id: "t3code-2", environmentId: "e", name: "t3code-2", cwd: "/work/t3code-2")
        // upstream groups these by shared repository identity; the typed port groups by folder
        // name, so give them the same folder name to exercise the same merge.
        let c = G.Project(id: "t3code-3", environmentId: "e", name: "t3code-3", cwd: "/work/t3code")
        let g = G.groups(projects: [a, c, b], settings: .init(), primaryEnvironmentId: nil) { _ in nil }
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].members.map(\.id), ["t3code", "t3code-3"])
    }
    // "uses a shared custom title as the repository group's label"
    func testUsesASharedNameAsTheGroupsDisplayName() {
        let first = G.Project(id: "first", environmentId: "e", name: "Custom project", cwd: "/work/t3code")
        let second = G.Project(id: "second", environmentId: "e", name: "Custom project", cwd: "/work/t3code")
        let g = G.groups(projects: [first, second], settings: .init(), primaryEnvironmentId: nil) { _ in nil }
        XCTAssertEqual(g[0].displayName, "Custom project")
    }
    // "keeps the repository label when shared titles match its repository name" — depends on
    // upstream's separate repositoryIdentity.displayName field the typed `Project` doesn't carry;
    // not expressible here.

    // "keeps physical clones in separate groups when requested"
    func testKeepsPhysicalClonesInSeparateGroupsWhenRequested() {
        let g = G.groups(projects: [local, remote], settings: .init(mode: .physical), primaryEnvironmentId: nil) { _ in nil }
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.flatMap(\.members).count, 2)
        XCTAssertEqual(g.map(\.displayName), ["limitless", "limitless"])
    }
    // "applies a physical-project override without dropping its siblings" — overriding one
    // clone's `physicalKey` splits only that clone out; its folder-name siblings stay merged.
    func testAppliesAPhysicalProjectOverrideWithoutDroppingItsSiblings() {
        let first = G.Project(id: "t3code", environmentId: "e", name: "t3code", cwd: "/work/t3code")
        let second = G.Project(id: "t3code-2", environmentId: "e", name: "t3code-2", cwd: "/work/t3code")
        let third = G.Project(id: "t3code-3", environmentId: "e", name: "t3code-3", cwd: "/work/t3code")
        let g = G.groups(projects: [first, second, third], settings: .init(overrides: [G.physicalKey(second): .physical]), primaryEnvironmentId: nil) { _ in nil }
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.flatMap { $0.members.map(\.id) }, ["t3code", "t3code-3", "t3code-2"])
    }
    // "dedupes stale registrations at one physical path using the freshest project",
    // "uses repository identity from a duplicate registration when the winner lacks it",
    // "uses the freshest winner's repository identity when stale duplicates disagree",
    // "uses the freshest identity-bearing duplicate when the winner lacks identity" — all four
    // depend on `updatedAt`/`createdAt` freshness comparison and `repositoryIdentity` fallback
    // that `T3ProjectGrouping.Project` doesn't model (the Mac sidebar's project list is already
    // deduplicated by the engine before it reaches this layer). Not expressible; not ported.
}
