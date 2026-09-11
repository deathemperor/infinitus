# Team nearby (plan 7 of the team design) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Machines on one LAN see each other's team standing (`_infinitus._tcp` TXT keys `n k t r d`), and a would-be member sends a join request straight to a leader over the LAN — from the Mac app's existing Bonjour listener, and from `infinitusctl team nearby|request --nearby|--discoverable` on Linux over a multicast-DNS responder/browser and `PosixHTTPServer`.

**Architecture:** Four new files carry everything: `NearbyRecord.swift` (the TXT record, shared bytes for every platform), `MDNS.swift` (a pure DNS message codec with byte-exact fixtures, a pure responder/collector, and a thin POSIX multicast socket fenced to macOS/Linux), `TeamNearby.swift` (local standing, the two LAN routes as pure `Request → Data?` functions, pending-request storage that also writes the `requests` branch), and `TeamNearbyCommand.swift` (the CLI). The Mac's `MirrorServer` gains the TXT record and mounts the same route function; discoverable is a `UserDefaults` bool (`team_discoverable`) that a control command flips and the listener observes event-driven. `POST /team/invite` and the invite payload are step 6's and are not in this plan.

**Tech Stack:** Swift 5.9 toolchain syntax (Swift 6.1 on Linux CI, 6.4 on the Mac), `swift-crypto` (already a dependency), POSIX sockets (`Darwin` / `Glibc`), Network.framework (Mac only, already used), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` (§6.4 nearby, §9 "Linux/Windows discovery", §11 mDNS packet encode/decode tests, §12 step 7). Read §1, §3, §4, §11, §12 too.

## Global Constraints

- Worktree /Users/deathemperor/death/limitless-t-nearby, branch team-nearby; stage by explicit path; every commit ends with "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"; push nothing.
- No cswap anywhere; never read engine internals (~/.claude-swap-backup/*, proxy config/auth files, ~/.9router); Claude Code's own files (~/.claude/sessions/*.json, ~/.claude/projects/*/*.jsonl) are fine; never ~/.aws/login or ~/.aws/sso.
- Secrets never in argv or logs; shown masked only.
- Every new InfinitusCore/InfinitusCLI file compiles on Linux: no Darwin imports outside #if canImport(Darwin); no Foundation APIs missing from swift-foundation; Process is unavailable on iOS (fence like TeamGit.run).
- Crypto.SHA256 fully qualified (MirrorRendezvous.swift declares an internal enum SHA256 that shadows it).
- Canonical JSON for every signed document ([.sortedKeys, .withoutEscapingSlashes]); no floating-point fields in signed docs (Int unix seconds).
- kid = base32(SHA-256(enc ‖ sig)[0..16]); TeamKeys.kid(forEncryptionKey:signingKey:).
- Verification is "swift test" only in this worktree (never tools/e2e.sh: three app instances would collide; CI runs it). If the app must ever run, INFINITUS_CONTROL_SOCKET=/tmp/<short>.sock. One --product per swift build invocation.
- Idle CPU stays ~0%: nothing polls on a timer in the app without a documented cadence; no TimelineView/repeatForever animation.
- Implementers spawn no subagents.
- CHANGELOG.md: one feature, one line, under the current unreleased version's "Team (preview)" heading.

Stream-specific:

- Files this stream may touch: the four new sources, their tests, `Sources/InfinitusCLI/TeamCommand.swift` (ONE dispatch line), `Sources/Infinitus/MirrorServer.swift`, `Sources/InfinitusCore/ControlProtocol.swift` (one manifest entry), `Sources/Infinitus/ControlServer.swift` (one `case`), `CHANGELOG.md`. Never `TeamClient.swift` (the publisher stream's), never `SettingsPane.swift`, `StatusItemController.swift`, `AppModel.swift` (the lock stream's). Settings are read straight from `UserDefaults` inside `MirrorServer`.
- `MDNS.swift`'s socket half and the `--discoverable` server are fenced `#if os(macOS) || os(Linux)` / `#if canImport(Glibc)`; the iOS project (`ios/project.yml`) links InfinitusCore, so the codec/responder/collector half must stay Foundation-only.
- mDNS v1 is IPv4 only: one UDP socket on `0.0.0.0:5353` in the `224.0.0.251` group (the Mac's mirror listener is IPv4-only too). `ff02::fb` is declared as a constant and unused. The encoder never compresses names; the decoder must follow compression pointers (Bonjour compresses everything).
- The hex fixtures in the tests are authoritative: they were generated from a reference encoder and cross-checked with an independent decoder. When a test and the implementation disagree, the implementation is wrong.
- `/team/key` and `/team/request` need no pairing token (peers have none), so on the Mac they answer only connections whose remote address is loopback, link-local or RFC 1918 private (`MirrorServer.isLANPeer`); the listener may be tunnel- or tailnet-exposed and a team request must never be posted from the internet. Linux `--discoverable` is a purpose-run server the operator starts by hand on every interface; its usage line says so. Discoverable off ⇒ TXT is exactly `d=0` and both routes answer 404. Bodies are bounded by `MirrorTransport.defaultBodyCap` (16 KiB); pending requests are one file per kid, at most `TeamNearby.pendingCap` per team.
- The Mac reads its identity through `FileSecrets` under `TeamPaths.standard().secretsDir` (same as the CLI) until plan 5 supplies the keychain-backed `TeamSecrets`.

---

## File structure

| file | responsibility |
|---|---|
| `Sources/InfinitusCore/Team/NearbyRecord.swift` | TXT keys `n k t r d` ↔ `NearbyRecord`; `TXTRecord` packs/unpacks DNS TXT rdata |
| `Sources/InfinitusCore/MDNS.swift` | `DNSName`, `MDNS.Message` codec (encode/decode), `MDNS.Service` records, `MDNS.Responder` (pure), `MDNS.Collector` (pure), `MDNS.Socket` / `MDNS.Advertiser` / `MDNS.browse` (POSIX, macOS+Linux) |
| `Sources/InfinitusCore/Team/TeamNearby.swift` | `TeamNearby.Local` (this machine's standing), `KeyReply` / `Request` / `RequestReply` wire types, `TeamNearby.respond` (the routes), `TeamNearby.Store` (pending + requests branch), the `team_discoverable` defaults key |
| `Sources/InfinitusCLI/TeamNearbyCommand.swift` | `infinitusctl team nearby`, `team request --nearby <kid>`, `team --discoverable` |
| `Sources/InfinitusCLI/TeamCommand.swift` | one dispatch line at the top of `runTeam` |
| `Sources/Infinitus/MirrorServer.swift` | TXT record on the Bonjour service, `/team/*` routes, `team_discoverable` observation |
| `Sources/InfinitusCore/ControlProtocol.swift`, `Sources/Infinitus/ControlServer.swift` | `team-discoverable on\|off` |
| `Tests/InfinitusCoreTests/NearbyRecordTests.swift`, `MDNSCodecTests.swift`, `MDNSResponderTests.swift`, `MDNSSocketTests.swift`, `TeamNearbyTests.swift`, `TeamNearbyManifestTests.swift` | one test file per unit above |
| `CHANGELOG.md` | one line |

---

### Task 1: NearbyRecord — the TXT record

**Files:**
- Create: `Sources/InfinitusCore/Team/NearbyRecord.swift`
- Test: `Tests/InfinitusCoreTests/NearbyRecordTests.swift`

**Interfaces:**
- Consumes: nothing beyond Foundation.
- Produces:
  - `struct NearbyRecord: Equatable, Sendable { name: String; kid: String; team: String?; role: String; discoverable: Bool }`, `init(name:kid:team:role:discoverable:)`, `static let hidden`, `static let roles: Set<String>` (`leader`, `member`, `none`), `var txtStrings: [String]` (wire order `n k t r d`; hidden ⇒ `["d=0"]`), `var txtData: Data`, `init?(txtStrings: [String])`, `init?(txtData: Data)`
  - `enum TXTRecord { static func pack(_ strings: [String]) -> Data; static func unpack(_ data: Data) -> [String] }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/NearbyRecordTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class NearbyRecordTests: XCTestCase {
    func hexData(_ text: String) -> Data {
        let chars = Array(text)
        var out = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            out.append(UInt8(String(chars[i...i + 1]), radix: 16)!)
        }
        return out
    }

    func testDiscoverableRecordPacksInWireOrder() {
        let r = NearbyRecord(name: "bo", kid: "abc", team: nil, role: "none", discoverable: true)
        XCTAssertEqual(r.txtStrings, ["n=bo", "k=abc", "t=", "r=none", "d=1"])
        XCTAssertEqual(r.txtData, hexData("046e3d626f056b3d61626302743d06723d6e6f6e6503643d31"))
        XCTAssertEqual(NearbyRecord(txtData: r.txtData), r)
        let leader = NearbyRecord(name: "Loc", kid: "kid1", team: "t-1", role: "leader", discoverable: true)
        XCTAssertEqual(NearbyRecord(txtStrings: leader.txtStrings), leader)
    }

    func testHiddenRecordIsDZeroAlone() {
        XCTAssertEqual(NearbyRecord.hidden.txtStrings, ["d=0"])
        XCTAssertEqual(NearbyRecord.hidden.txtData, Data([3, 0x64, 0x3d, 0x30]))
        // A machine that went hidden advertises nothing about its team, whatever it knows.
        let team = NearbyRecord(name: "Loc", kid: "kid1", team: "t-1", role: "leader", discoverable: false)
        XCTAssertEqual(team.txtStrings, ["d=0"])
        // A peer that says d=0 is hidden even if fields ride along.
        XCTAssertEqual(NearbyRecord(txtStrings: ["n=bo", "k=abc", "d=0"]), .hidden)
    }

    func testForeignOrBrokenRecordsAreNil() {
        XCTAssertNil(NearbyRecord(txtStrings: ["txtvers=1"]))                 // some other service
        XCTAssertNil(NearbyRecord(txtStrings: ["d=1", "k=abc", "r=boss"]))    // unknown role
        XCTAssertNil(NearbyRecord(txtStrings: ["d=1", "r=none"]))             // no kid
        // RFC 6763 §6.4: the first occurrence of a key wins.
        XCTAssertEqual(NearbyRecord(txtStrings: ["d=1", "k=abc", "r=member", "t=team-9", "d=0"])?.team, "team-9")
    }

    func testTXTPackerHonoursTheWireLimits() {
        XCTAssertEqual(TXTRecord.pack([]), Data([0]))
        XCTAssertEqual(TXTRecord.unpack(Data([0])), [])
        let long = String(repeating: "x", count: 300)
        let packed = TXTRecord.pack(["n=" + long])
        XCTAssertEqual(packed.count, 256)
        XCTAssertEqual(TXTRecord.unpack(packed).first?.count, 255)
        // Truncated rdata never crashes.
        XCTAssertEqual(TXTRecord.unpack(Data([5, 0x61, 0x62])), ["ab"])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/death/limitless-t-nearby && swift test --filter NearbyRecordTests 2>&1 | tail -3`
Expected: compile error, `NearbyRecord` not found.

- [ ] **Step 3: Implement**

Create `Sources/InfinitusCore/Team/NearbyRecord.swift`:

```swift
import Foundation

/// The `_infinitus._tcp` TXT record (spec §6.4): what one machine tells
/// the LAN about its team standing. Nothing secret — `n` machine name,
/// `k` kid, `t` team id (empty when none), `r` leader|member|none, `d`
/// discoverable 0/1. Discoverable off ⇒ the record is `d=0` alone: no
/// name, no team fields. The Mac hands `txtData` to
/// `NWListener.Service(txtRecord:)`, the POSIX responder (MDNS.swift)
/// puts `txtStrings` in its TXT rdata — the same bytes either way,
/// which is why the packer lives here and not in either listener.
public struct NearbyRecord: Equatable, Sendable {
    public var name: String
    public var kid: String
    public var team: String?
    /// "leader" | "member" | "none"
    public var role: String
    public var discoverable: Bool

    public static let roles: Set<String> = ["leader", "member", "none"]

    public init(name: String, kid: String, team: String?, role: String, discoverable: Bool) {
        self.name = name; self.kid = kid; self.team = team; self.role = role; self.discoverable = discoverable
    }

    /// What an undiscoverable machine advertises.
    public static let hidden = NearbyRecord(name: "", kid: "", team: nil, role: "none", discoverable: false)

    /// The TXT strings in wire order (`n`, `k`, `t`, `r`, `d`).
    public var txtStrings: [String] {
        guard discoverable else { return ["d=0"] }
        return ["n=\(name)", "k=\(kid)", "t=\(team ?? "")", "r=\(role)", "d=1"]
    }

    /// TXT rdata: the strings, each length-prefixed.
    public var txtData: Data { TXTRecord.pack(txtStrings) }

    /// nil when the strings aren't an Infinitus record at all (no `d`);
    /// `d` other than `1` is `.hidden`, whatever else rides along.
    public init?(txtStrings strings: [String]) {
        var pairs: [String: String] = [:]
        for s in strings {
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[s.startIndex..<eq])
            // RFC 6763 §6.4: the first occurrence of a key wins.
            if pairs[key] == nil { pairs[key] = String(s[s.index(after: eq)...]) }
        }
        guard let d = pairs["d"] else { return nil }
        guard d == "1" else { self = .hidden; return }
        guard let kid = pairs["k"], !kid.isEmpty,
              let role = pairs["r"], Self.roles.contains(role) else { return nil }
        let team = pairs["t"] ?? ""
        self.init(name: pairs["n"] ?? "", kid: kid, team: team.isEmpty ? nil : team, role: role, discoverable: true)
    }

    public init?(txtData: Data) {
        self.init(txtStrings: TXTRecord.unpack(txtData))
    }
}

/// DNS TXT rdata (RFC 6763 §6): a sequence of length-prefixed strings,
/// each at most 255 bytes; an empty record is one zero-length string.
public enum TXTRecord {
    public static func pack(_ strings: [String]) -> Data {
        var out = Data()
        for s in strings {
            let bytes = Data(s.utf8).prefix(255)
            out.append(UInt8(bytes.count))
            out.append(bytes)
        }
        return out.isEmpty ? Data([0]) : out
    }

    public static func unpack(_ data: Data) -> [String] {
        var out: [String] = []
        var i = data.startIndex
        while i < data.endIndex {
            let len = Int(data[i])
            i += 1
            let end = min(i + len, data.endIndex)
            if len > 0 { out.append(String(decoding: data[i..<end], as: UTF8.self)) }
            i = end
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd ~/death/limitless-t-nearby && swift test --filter NearbyRecordTests 2>&1 | tail -3`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/death/limitless-t-nearby && git add Sources/InfinitusCore/Team/NearbyRecord.swift Tests/InfinitusCoreTests/NearbyRecordTests.swift && \
git commit -m "team: nearby TXT record — n k t r d, hidden is d=0 alone, shared packer for Bonjour and the POSIX responder

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: MDNS codec — DNS messages, byte-exact

**Files:**
- Create: `Sources/InfinitusCore/MDNS.swift`
- Test: `Tests/InfinitusCoreTests/MDNSCodecTests.swift`

**Interfaces:**
- Consumes: `TXTRecord.pack` / `unpack` (Task 1).
- Produces:
  - `struct DNSName: Hashable, Sendable { labels: [String] }`, `init(labels:)`, `init(dotted:)`, `var dotted: String`, `var key: String` (lowercased join), `func matches(_:) -> Bool`
  - `enum MDNS` constants: `groupIPv4 = "224.0.0.251"`, `groupIPv6 = "ff02::fb"`, `port: UInt16 = 5353`, `serviceName: DNSName` (`_infinitus._tcp.local.`), `ttlLong: UInt32 = 4500`, `ttlShort: UInt32 = 120`, `typeA = 1`, `typePTR = 12`, `typeTXT = 16`, `typeSRV = 33`, `typeANY = 255`, `classIN = 1`, `classFlag = 0x8000`, `flagsResponse = 0x8400`, `flagsQuery = 0`
  - `struct MDNS.Question: Equatable, Sendable { name: DNSName; type: UInt16; cls: UInt16 }`, `init(name:type:cls: = classIN)`, `var unicastResponse: Bool`
  - `enum MDNS.RData: Equatable, Sendable { case ptr(DNSName); case srv(priority: UInt16, weight: UInt16, port: UInt16, target: DNSName); case txt([String]); case a(String); case other(Data) }`
  - `struct MDNS.Record: Equatable, Sendable { name: DNSName; type: UInt16; cacheFlush: Bool; ttl: UInt32; rdata: RData }`, `init(name:type:cacheFlush:ttl:rdata:)`
  - `struct MDNS.Message: Equatable, Sendable { id: UInt16; flags: UInt16; questions; answers; authorities; additionals }`, `init(id: = 0, flags:, questions: = [], answers: = [], authorities: = [], additionals: = [])`, `var isResponse: Bool`, `var records: [Record]`, `static func query(_ name: DNSName, type: UInt16 = typePTR) -> Message`, `static func response(_ answers: [Record]) -> Message`, `func encode() -> Data`, `static func decode(_ data: Data) throws -> Message`
  - `enum MDNS.DecodeError: Error, Equatable { case truncated, badPointer, badLabel }`
  - `struct MDNS.Service: Equatable, Sendable { instance: String; host: String; port: UInt16; txt: [String]; ipv4: String }`, `init(instance:host:port:txt:ipv4:)`, `var instanceName: DNSName`, `var hostName: DNSName`, `func records() -> [Record]` (PTR, SRV, TXT, A in that order), `func announcement() -> Message`, `func goodbye() -> Message`
  - `static func MDNS.hostLabel(_ text: String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/MDNSCodecTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

/// Byte-exact fixtures (spec §11 "mDNS packet encode/decode"), generated
/// from a reference encoder and cross-checked with an independent
/// decoder: `bo._infinitus._tcp.local.` on `bo.local.` 192.168.1.7:47824.
final class MDNSCodecTests: XCTestCase {
    /// PTR query for `_infinitus._tcp.local.`, id 0, flags 0.
    static let query = "0000000000010000000000000a5f696e66696e69747573045f746370056c6f63616c00000c0001"
    /// Announcement: PTR (ttl 4500) + SRV (cache-flush, ttl 120) + TXT (cache-flush, ttl 4500) + A (cache-flush, ttl 120), uncompressed.
    static let response = "0000840000000004000000000a5f696e66696e69747573045f746370056c6f63616c00000c000100001194001a02626f0a5f696e66696e69747573045f746370056c6f63616c0002626f0a5f696e66696e69747573045f746370056c6f63616c000021800100000078001000000000bad002626f056c6f63616c0002626f0a5f696e66696e69747573045f746370056c6f63616c0000108001000011940019046e3d626f056b3d61626302743d06723d6e6f6e6503643d3102626f056c6f63616c0000018001000000780004c0a80107"
    /// The same four records the way Bonjour sends them: names compressed with pointers (`c00c`, `c02d`, `c01c`, `c044`).
    static let compressed = "0000840000000004000000000a5f696e66696e69747573045f746370056c6f63616c00000c000100001194000502626fc00cc02d0021800100000078000b00000000bad002626fc01cc02d00108001000011940019046e3d626f056b3d61626302743d06723d6e6f6e6503643d31c04400018001000000780004c0a80107"
    /// Goodbye: the PTR with TTL 0.
    static let goodbye = "0000840000000001000000000a5f696e66696e69747573045f746370056c6f63616c00000c000100000000001a02626f0a5f696e66696e69747573045f746370056c6f63616c00"
    /// SRV question for the instance with the unicast-response bit (class 0x8001).
    static let srvQuestion = "00000000000100000000000002626f0a5f696e66696e69747573045f746370056c6f63616c0000218001"

    func hexData(_ text: String) -> Data {
        let chars = Array(text)
        var out = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            out.append(UInt8(String(chars[i...i + 1]), radix: 16)!)
        }
        return out
    }

    let bo = MDNS.Service(instance: "bo", host: "bo", port: 47824,
                          txt: ["n=bo", "k=abc", "t=", "r=none", "d=1"], ipv4: "192.168.1.7")

    func testServiceQueryBytes() throws {
        XCTAssertEqual(MDNS.Message.query(MDNS.serviceName).encode(), hexData(Self.query))
        let back = try MDNS.Message.decode(hexData(Self.query))
        XCTAssertEqual(back.questions, [MDNS.Question(name: MDNS.serviceName, type: MDNS.typePTR)])
        XCTAssertFalse(back.isResponse)
        XCTAssertEqual(back.records, [])
    }

    func testAnnouncementBytesAndRoundTrip() throws {
        let message = bo.announcement()
        XCTAssertEqual(message.encode(), hexData(Self.response))
        XCTAssertEqual(try MDNS.Message.decode(hexData(Self.response)), message)
        XCTAssertEqual(message.flags, 0x8400)
        XCTAssertTrue(message.isResponse)
        XCTAssertEqual(message.answers.map(\.type), [MDNS.typePTR, MDNS.typeSRV, MDNS.typeTXT, MDNS.typeA])
        XCTAssertEqual(message.answers.map(\.cacheFlush), [false, true, true, true])
        XCTAssertEqual(message.answers.map(\.ttl), [4500, 120, 4500, 120])
    }

    func testCompressedNamesDecodeToTheSameRecords() throws {
        XCTAssertEqual(try MDNS.Message.decode(hexData(Self.compressed)), bo.announcement())
    }

    func testGoodbyeBytes() {
        XCTAssertEqual(bo.goodbye().encode(), hexData(Self.goodbye))
    }

    func testUnicastQuestionKeepsItsFlag() throws {
        let m = try MDNS.Message.decode(hexData(Self.srvQuestion))
        XCTAssertEqual(m.questions.first?.name, bo.instanceName)
        XCTAssertEqual(m.questions.first?.type, MDNS.typeSRV)
        XCTAssertEqual(m.questions.first?.unicastResponse, true)
        // Encoding keeps the raw class, so a re-encode is byte-identical.
        XCTAssertEqual(m.encode(), hexData(Self.srvQuestion))
    }

    func testMalformedPacketsThrowInsteadOfCrashing() {
        XCTAssertThrowsError(try MDNS.Message.decode(hexData(Self.response).prefix(30)))
        XCTAssertThrowsError(try MDNS.Message.decode(Data()))
        // A pointer to itself must not loop.
        var loop = hexData("000000000001000000000000")
        loop.append(contentsOf: [0xC0, 0x0C, 0x00, 0x0C, 0x00, 0x01])
        XCTAssertThrowsError(try MDNS.Message.decode(loop)) {
            XCTAssertEqual($0 as? MDNS.DecodeError, .badPointer)
        }
        // The reserved 0x40 label prefix.
        var bad = hexData("000000000001000000000000")
        bad.append(contentsOf: [0x40, 0x00, 0x00, 0x0C, 0x00, 0x01])
        XCTAssertThrowsError(try MDNS.Message.decode(bad)) {
            XCTAssertEqual($0 as? MDNS.DecodeError, .badLabel)
        }
    }

    func testNamesAndHostLabels() {
        XCTAssertEqual(DNSName(dotted: "bo._infinitus._tcp.local.").labels, ["bo", "_infinitus", "_tcp", "local"])
        XCTAssertEqual(DNSName(dotted: "bo.local").labels, ["bo", "local"])
        // An instance label may hold dots; the wire is length-prefixed, only text is ambiguous.
        XCTAssertEqual(DNSName(labels: ["Loc's Mac 1.2", "_infinitus", "_tcp", "local"]).dotted,
                       "Loc's Mac 1.2._infinitus._tcp.local.")
        XCTAssertTrue(DNSName(dotted: "BO.LOCAL").matches(DNSName(dotted: "bo.local.")))
        XCTAssertFalse(DNSName(dotted: "bo.local").matches(DNSName(dotted: "ba.local")))
        XCTAssertEqual(MDNS.hostLabel("Loc's Mac"), "loc-s-mac")
        XCTAssertEqual(MDNS.hostLabel("Bo"), "bo")
        XCTAssertEqual(MDNS.hostLabel("---"), "infinitus")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/death/limitless-t-nearby && swift test --filter MDNSCodecTests 2>&1 | tail -3`
Expected: compile error, `MDNS` not found.

- [ ] **Step 3: Implement the codec**

Create `Sources/InfinitusCore/MDNS.swift` (Tasks 3 appends the responder, collector and sockets to this same file):

```swift
import Foundation

// MARK: - Multicast DNS for `_infinitus._tcp` (spec §6.4, §9)
//
// RFC 6762 (mDNS) + RFC 6763 (DNS-SD), the minimum that lets a Linux box
// advertise and browse the same service the Mac advertises through
// Network.framework. The codec and the responder/collector logic are
// pure and run under `swift test` on every platform; the UDP socket at
// the bottom is fenced to macOS + Linux.

/// A DNS name as labels, so an instance label may contain dots ("Loc's
/// Mac 1.2"): the wire is length-prefixed, only the dotted text is
/// ambiguous.
public struct DNSName: Hashable, Sendable {
    public var labels: [String]

    public init(labels: [String]) { self.labels = labels }

    /// "a.b.c." split on dots (the trailing dot is optional).
    public init(dotted: String) {
        labels = dotted.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }

    public var dotted: String { labels.map { $0 + "." }.joined() }

    /// DNS names compare case-insensitively (RFC 6762 §16).
    public var key: String { labels.map { $0.lowercased() }.joined(separator: "\u{0}") }

    public func matches(_ other: DNSName) -> Bool { key == other.key }
}

public enum MDNS {
    public static let groupIPv4 = "224.0.0.251"
    /// Declared for a v6 socket later; v1 sends and listens on IPv4 only
    /// (the Mac's mirror listener is v4-only as well).
    public static let groupIPv6 = "ff02::fb"
    public static let port: UInt16 = 5353
    public static let serviceName = DNSName(labels: ["_infinitus", "_tcp", "local"])
    /// RFC 6762 §10: 75 minutes for PTR/TXT, 2 minutes for SRV/A.
    public static let ttlLong: UInt32 = 4500
    public static let ttlShort: UInt32 = 120

    public static let typeA: UInt16 = 1
    public static let typePTR: UInt16 = 12
    public static let typeTXT: UInt16 = 16
    public static let typeSRV: UInt16 = 33
    public static let typeANY: UInt16 = 255
    public static let classIN: UInt16 = 1
    /// Top bit of the class: cache-flush on a record, unicast-reply on a question.
    public static let classFlag: UInt16 = 0x8000
    /// QR + AA.
    public static let flagsResponse: UInt16 = 0x8400
    public static let flagsQuery: UInt16 = 0

    public struct Question: Equatable, Sendable {
        public var name: DNSName
        public var type: UInt16
        /// The raw class, QU bit included.
        public var cls: UInt16

        public init(name: DNSName, type: UInt16, cls: UInt16 = MDNS.classIN) {
            self.name = name; self.type = type; self.cls = cls
        }

        public var unicastResponse: Bool { cls & MDNS.classFlag != 0 }
    }

    public enum RData: Equatable, Sendable {
        case ptr(DNSName)
        case srv(priority: UInt16, weight: UInt16, port: UInt16, target: DNSName)
        case txt([String])
        /// Dotted quad.
        case a(String)
        case other(Data)
    }

    public struct Record: Equatable, Sendable {
        public var name: DNSName
        public var type: UInt16
        public var cacheFlush: Bool
        public var ttl: UInt32
        public var rdata: RData

        public init(name: DNSName, type: UInt16, cacheFlush: Bool, ttl: UInt32, rdata: RData) {
            self.name = name; self.type = type; self.cacheFlush = cacheFlush; self.ttl = ttl; self.rdata = rdata
        }
    }

    public struct Message: Equatable, Sendable {
        public var id: UInt16
        public var flags: UInt16
        public var questions: [Question]
        public var answers: [Record]
        public var authorities: [Record]
        public var additionals: [Record]

        public init(id: UInt16 = 0, flags: UInt16, questions: [Question] = [], answers: [Record] = [],
                    authorities: [Record] = [], additionals: [Record] = []) {
            self.id = id; self.flags = flags; self.questions = questions
            self.answers = answers; self.authorities = authorities; self.additionals = additionals
        }

        public var isResponse: Bool { flags & 0x8000 != 0 }
        public var records: [Record] { answers + authorities + additionals }

        public static func query(_ name: DNSName, type: UInt16 = MDNS.typePTR) -> Message {
            Message(flags: MDNS.flagsQuery, questions: [Question(name: name, type: type)])
        }

        public static func response(_ answers: [Record]) -> Message {
            Message(flags: MDNS.flagsResponse, answers: answers)
        }

        // MARK: encode

        public func encode() -> Data {
            var out = Data()
            out.appendUInt16(id)
            out.appendUInt16(flags)
            out.appendUInt16(UInt16(questions.count))
            out.appendUInt16(UInt16(answers.count))
            out.appendUInt16(UInt16(authorities.count))
            out.appendUInt16(UInt16(additionals.count))
            for q in questions {
                out.appendName(q.name)
                out.appendUInt16(q.type)
                out.appendUInt16(q.cls)
            }
            for r in answers + authorities + additionals { out.appendRecord(r) }
            return out
        }

        // MARK: decode

        public static func decode(_ data: Data) throws -> Message {
            var r = Reader(bytes: [UInt8](data))
            let id = try r.u16(), flags = try r.u16()
            let qd = try r.u16(), an = try r.u16(), ns = try r.u16(), ar = try r.u16()
            var m = Message(id: id, flags: flags)
            for _ in 0..<qd {
                m.questions.append(Question(name: try r.name(), type: try r.u16(), cls: try r.u16()))
            }
            for _ in 0..<an { m.answers.append(try r.record()) }
            for _ in 0..<ns { m.authorities.append(try r.record()) }
            for _ in 0..<ar { m.additionals.append(try r.record()) }
            return m
        }
    }

    public enum DecodeError: Error, Equatable { case truncated, badPointer, badLabel }

    // MARK: service

    /// One `_infinitus._tcp` instance: what a responder advertises.
    public struct Service: Equatable, Sendable {
        /// The instance label (the machine name, any characters).
        public var instance: String
        /// One label; the host is `<host>.local.`.
        public var host: String
        public var port: UInt16
        public var txt: [String]
        public var ipv4: String

        public init(instance: String, host: String, port: UInt16, txt: [String], ipv4: String) {
            self.instance = instance; self.host = host; self.port = port; self.txt = txt; self.ipv4 = ipv4
        }

        public var instanceName: DNSName { DNSName(labels: [instance] + MDNS.serviceName.labels) }
        public var hostName: DNSName { DNSName(labels: [host, "local"]) }

        /// PTR, SRV, TXT, A — the unique ones with cache-flush set (RFC 6762 §10.2).
        public func records() -> [Record] {
            [Record(name: MDNS.serviceName, type: MDNS.typePTR, cacheFlush: false, ttl: MDNS.ttlLong,
                    rdata: .ptr(instanceName)),
             Record(name: instanceName, type: MDNS.typeSRV, cacheFlush: true, ttl: MDNS.ttlShort,
                    rdata: .srv(priority: 0, weight: 0, port: port, target: hostName)),
             Record(name: instanceName, type: MDNS.typeTXT, cacheFlush: true, ttl: MDNS.ttlLong,
                    rdata: .txt(txt)),
             Record(name: hostName, type: MDNS.typeA, cacheFlush: true, ttl: MDNS.ttlShort,
                    rdata: .a(ipv4))]
        }

        public func announcement() -> Message { .response(records()) }

        /// TTL 0 on the PTR: browsers drop the instance (RFC 6762 §10.1).
        public func goodbye() -> Message {
            .response([Record(name: MDNS.serviceName, type: MDNS.typePTR, cacheFlush: false, ttl: 0,
                              rdata: .ptr(instanceName))])
        }
    }

    /// A host label out of free text: lowercase ASCII letters, digits and
    /// single hyphens (RFC 1123), "infinitus" when nothing survives.
    public static func hostLabel(_ text: String) -> String {
        var out = ""
        var lastHyphen = true
        for ch in text.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch); lastHyphen = false
            } else if !lastHyphen {
                out.append("-"); lastHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "infinitus" : String(out.prefix(63))
    }
}

// MARK: - Wire helpers

private extension Data {
    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xff))
    }

    mutating func appendUInt32(_ v: UInt32) {
        appendUInt16(UInt16(v >> 16)); appendUInt16(UInt16(v & 0xffff))
    }

    /// Uncompressed: our packets are small, and every decoder must follow
    /// pointers anyway (ours does, below).
    mutating func appendName(_ name: DNSName) {
        for label in name.labels {
            let bytes = Data(label.utf8).prefix(63)
            append(UInt8(bytes.count)); append(bytes)
        }
        append(0)
    }

    mutating func appendRecord(_ r: MDNS.Record) {
        appendName(r.name)
        appendUInt16(r.type)
        appendUInt16(MDNS.classIN | (r.cacheFlush ? MDNS.classFlag : 0))
        appendUInt32(r.ttl)
        var rd = Data()
        switch r.rdata {
        case .ptr(let target):
            rd.appendName(target)
        case .srv(let priority, let weight, let port, let target):
            rd.appendUInt16(priority); rd.appendUInt16(weight); rd.appendUInt16(port); rd.appendName(target)
        case .txt(let strings):
            rd = TXTRecord.pack(strings)
        case .a(let ip):
            rd = Data(ip.split(separator: ".").compactMap { UInt8($0) })
        case .other(let bytes):
            rd = bytes
        }
        appendUInt16(UInt16(rd.count))
        append(rd)
    }
}

private struct Reader {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw MDNS.DecodeError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard pos + n <= bytes.count else { throw MDNS.DecodeError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    /// RFC 1035 §4.1.4: labels ending in 0 or in a pointer (0xC0xx) to an
    /// earlier offset; pointers may chain, only backwards, so a packet
    /// can't loop us. `pos` lands after the in-line part.
    mutating func name() throws -> DNSName {
        var labels: [String] = []
        var cursor = pos
        var end: Int? = nil
        var jumps = 0
        while true {
            guard cursor < bytes.count else { throw MDNS.DecodeError.truncated }
            let len = Int(bytes[cursor])
            if len & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { throw MDNS.DecodeError.truncated }
                let target = (len & 0x3F) << 8 | Int(bytes[cursor + 1])
                guard target < cursor, jumps < 32 else { throw MDNS.DecodeError.badPointer }
                if end == nil { end = cursor + 2 }
                cursor = target
                jumps += 1
                continue
            }
            guard len & 0xC0 == 0 else { throw MDNS.DecodeError.badLabel }
            cursor += 1
            if len == 0 {
                if end == nil { end = cursor }
                break
            }
            guard cursor + len <= bytes.count else { throw MDNS.DecodeError.truncated }
            labels.append(String(decoding: bytes[cursor..<cursor + len], as: UTF8.self))
            cursor += len
        }
        pos = end ?? cursor
        return DNSName(labels: labels)
    }

    mutating func record() throws -> MDNS.Record {
        let owner = try name()
        let type = try u16(), cls = try u16(), ttl = try u32()
        let len = Int(try u16())
        guard pos + len <= bytes.count else { throw MDNS.DecodeError.truncated }
        let end = pos + len
        let rdata: MDNS.RData
        switch type {
        case MDNS.typePTR:
            rdata = .ptr(try name())
        case MDNS.typeSRV:
            rdata = .srv(priority: try u16(), weight: try u16(), port: try u16(), target: try name())
        case MDNS.typeTXT:
            rdata = .txt(TXTRecord.unpack(Data(try take(len))))
        case MDNS.typeA where len == 4:
            rdata = .a(try take(4).map { String($0) }.joined(separator: "."))
        default:
            rdata = .other(Data(try take(len)))
        }
        // A name inside rdata may end before `len` (pointers), never after.
        guard pos <= end else { throw MDNS.DecodeError.truncated }
        pos = end
        return MDNS.Record(name: owner, type: type, cacheFlush: cls & MDNS.classFlag != 0, ttl: ttl, rdata: rdata)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd ~/death/limitless-t-nearby && swift test --filter MDNSCodecTests 2>&1 | tail -3`
Expected: 7 tests pass. If `testCompressedNamesDecodeToTheSameRecords` fails, the bug is in `Reader.name()` pointer handling (the fixture is correct: `c00c` → offset 12, `c02d` → 45, `c01c` → 28, `c044` → 68).

- [ ] **Step 5: Commit**

```bash
cd ~/death/limitless-t-nearby && git add Sources/InfinitusCore/MDNS.swift Tests/InfinitusCoreTests/MDNSCodecTests.swift && \
git commit -m "team: mDNS codec — DNS messages for _infinitus._tcp, byte-exact fixtures, pointer-following decoder

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: MDNS responder, collector and the multicast socket

**Files:**
- Modify: `Sources/InfinitusCore/MDNS.swift` (append)
- Test: `Tests/InfinitusCoreTests/MDNSResponderTests.swift`, `Tests/InfinitusCoreTests/MDNSSocketTests.swift`

**Interfaces:**
- Consumes: everything from Task 2; `NearbyRecord.hidden.txtStrings` (Task 1, in the socket test).
- Produces:
  - `enum MDNS.Responder { static func answer(_ query: Message, service: Service) -> Message? }`
  - `struct MDNS.Peer: Equatable, Sendable { instance: String; host: String; port: UInt16; txt: [String]; ipv4: String? }`, `init(instance:host:port:txt:ipv4:)`
  - `struct MDNS.Collector: Equatable, Sendable { init(); mutating func ingest(_ message: Message, from sender: String?); var peers: [Peer] }`
  - macOS/Linux only: `enum MDNS.SocketError: Error, Equatable { case socket(Int32), bind(Int32), membership(Int32), send(Int32) }`, `final class MDNS.Socket { init() throws; func send(_ message: Message) throws; func receive(timeout: TimeInterval) -> (message: Message, sender: String)?; func tearDown() }`, `final class MDNS.Advertiser { init(service: Service) throws; func start() throws; func stop() }`, `static func MDNS.browse(seconds: TimeInterval) throws -> [Peer]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/MDNSResponderTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class MDNSResponderTests: XCTestCase {
    let bo = MDNS.Service(instance: "bo", host: "bo", port: 47824,
                          txt: ["n=bo", "k=abc", "t=", "r=none", "d=1"], ipv4: "192.168.1.7")

    func testAnswersOnlyWhatItHolds() {
        // A PTR hit is the whole announcement: one packet resolves the peer.
        XCTAssertEqual(MDNS.Responder.answer(.query(MDNS.serviceName), service: bo), bo.announcement())
        let srvOnly = MDNS.Responder.answer(.query(bo.instanceName, type: MDNS.typeSRV), service: bo)
        XCTAssertEqual(srvOnly?.answers.map(\.type), [MDNS.typeSRV])
        XCTAssertEqual(srvOnly?.flags, MDNS.flagsResponse)
        XCTAssertEqual(MDNS.Responder.answer(.query(bo.instanceName, type: MDNS.typeANY), service: bo)?.answers.count, 2)
        XCTAssertEqual(MDNS.Responder.answer(.query(bo.hostName, type: MDNS.typeA), service: bo)?.answers.map(\.rdata),
                       [.a("192.168.1.7")])
        XCTAssertNil(MDNS.Responder.answer(.query(DNSName(dotted: "_http._tcp.local.")), service: bo))
        XCTAssertNil(MDNS.Responder.answer(.query(DNSName(dotted: "ba._infinitus._tcp.local."), type: MDNS.typeSRV), service: bo))
        // Never answer a response, whatever it carries.
        XCTAssertNil(MDNS.Responder.answer(bo.announcement(), service: bo))
        // Names match case-insensitively.
        XCTAssertNotNil(MDNS.Responder.answer(.query(DNSName(dotted: "_INFINITUS._TCP.LOCAL")), service: bo))
    }

    func testCollectorNeedsSrvAndTxtAndHonoursGoodbye() {
        var c = MDNS.Collector()
        c.ingest(bo.announcement(), from: "192.168.1.9")
        XCTAssertEqual(c.peers, [MDNS.Peer(instance: "bo", host: "bo.local.", port: 47824, txt: bo.txt, ipv4: "192.168.1.7")])
        // Without an A record the datagram's sender stands in.
        var partial = MDNS.Collector()
        partial.ingest(.response(Array(bo.records()[1...2])), from: "10.0.0.5")
        XCTAssertEqual(partial.peers.first?.ipv4, "10.0.0.5")
        // SRV alone is not a peer yet.
        var half = MDNS.Collector()
        half.ingest(.response([bo.records()[1]]), from: nil)
        XCTAssertEqual(half.peers, [])
        // Goodbye forgets the instance.
        c.ingest(bo.goodbye(), from: nil)
        XCTAssertEqual(c.peers, [])
        // Queries are never peers.
        var q = MDNS.Collector()
        q.ingest(.query(MDNS.serviceName), from: nil)
        XCTAssertEqual(q.peers, [])
        // Another service's records are ignored.
        let foreign = DNSName(labels: ["web", "_http", "_tcp", "local"])
        var other = MDNS.Collector()
        other.ingest(.response([
            MDNS.Record(name: foreign, type: MDNS.typeSRV, cacheFlush: true, ttl: 120,
                        rdata: .srv(priority: 0, weight: 0, port: 80, target: DNSName(dotted: "web.local."))),
            MDNS.Record(name: foreign, type: MDNS.typeTXT, cacheFlush: true, ttl: 4500, rdata: .txt([])),
        ]), from: "1.2.3.4")
        XCTAssertEqual(other.peers, [])
    }

    func testCollectorSortsAndKeepsTheLatestTxt() {
        let al = MDNS.Service(instance: "al", host: "al", port: 1, txt: ["d=0"], ipv4: "10.0.0.1")
        var c = MDNS.Collector()
        c.ingest(bo.announcement(), from: nil)
        c.ingest(al.announcement(), from: nil)
        XCTAssertEqual(c.peers.map(\.instance), ["al", "bo"])
        var flipped = al
        flipped.txt = ["n=al", "k=k2", "t=", "r=none", "d=1"]
        c.ingest(flipped.announcement(), from: nil)
        XCTAssertEqual(c.peers.first?.txt, flipped.txt)
        XCTAssertEqual(c.peers.count, 2)
    }
}
```

Create `Tests/InfinitusCoreTests/MDNSSocketTests.swift`:

```swift
#if os(macOS) || os(Linux)
import XCTest
@testable import InfinitusCore

/// The real socket on this host: an advertiser and a browser in one
/// process hear each other through multicast loopback. Skipped where
/// the host has no multicast (a container without a multicast route,
/// or `INFINITUS_SKIP_MDNS` set) — the pure tests cover the logic.
final class MDNSSocketTests: XCTestCase {
    func testAdvertiserIsFoundByTheBrowser() throws {
        if ProcessInfo.processInfo.environment["INFINITUS_SKIP_MDNS"] != nil { throw XCTSkip("INFINITUS_SKIP_MDNS set") }
        let instance = "infinitus-test-" + String(UUID().uuidString.prefix(8))
        let service = MDNS.Service(instance: instance, host: MDNS.hostLabel(instance), port: 1,
                                   txt: NearbyRecord.hidden.txtStrings, ipv4: "127.0.0.1")
        let advertiser: MDNS.Advertiser
        do {
            advertiser = try MDNS.Advertiser(service: service)
            try advertiser.start()
        } catch {
            throw XCTSkip("no multicast here: \(error)")
        }
        defer { advertiser.stop() }
        let peers: [MDNS.Peer]
        do { peers = try MDNS.browse(seconds: 2) } catch { throw XCTSkip("no multicast here: \(error)") }
        let mine = try XCTUnwrap(peers.first { $0.instance == instance }, "peers seen: \(peers.map(\.instance))")
        XCTAssertEqual(mine.port, 1)
        XCTAssertEqual(mine.txt, ["d=0"])
        XCTAssertEqual(mine.ipv4, "127.0.0.1")
        XCTAssertEqual(mine.host, MDNS.hostLabel(instance) + ".local.")
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/death/limitless-t-nearby && swift test --filter 'MDNSResponderTests|MDNSSocketTests' 2>&1 | tail -3`
Expected: compile error, `MDNS.Responder` not found.

- [ ] **Step 3: Append the responder, collector and socket to MDNS.swift**

Append to the end of `Sources/InfinitusCore/MDNS.swift`:

```swift
// MARK: - Responder and browser logic (pure)

extension MDNS {
    public enum Responder {
        /// What to send back for `query`, nil when it asks for nothing of
        /// ours. Replies go multicast whatever the QU bit says (RFC 6762
        /// §5.4 allows it); a PTR hit returns the whole announcement so a
        /// browser resolves the peer from one packet.
        public static func answer(_ query: Message, service: Service) -> Message? {
            guard !query.isResponse else { return nil }
            var records: [Record] = []
            for q in query.questions {
                let wants: (UInt16) -> Bool = { q.type == $0 || q.type == MDNS.typeANY }
                if q.name.matches(MDNS.serviceName), wants(MDNS.typePTR) {
                    return service.announcement()
                }
                for r in service.records() where r.name.matches(q.name) && wants(r.type) && !records.contains(r) {
                    records.append(r)
                }
            }
            return records.isEmpty ? nil : .response(records)
        }
    }

    public struct Peer: Equatable, Sendable {
        public var instance: String
        /// The SRV target, dotted (`bo.local.`).
        public var host: String
        public var port: UInt16
        public var txt: [String]
        public var ipv4: String?

        public init(instance: String, host: String, port: UInt16, txt: [String], ipv4: String?) {
            self.instance = instance; self.host = host; self.port = port; self.txt = txt; self.ipv4 = ipv4
        }
    }

    /// Folds datagrams into peers: an instance is a peer once its SRV and
    /// TXT have both arrived; its address is the A record for the SRV
    /// target, else the datagram's sender. A TTL-0 PTR or SRV forgets it.
    public struct Collector: Equatable, Sendable {
        private struct SRV: Equatable, Sendable { var port: UInt16; var target: DNSName }
        private var names: [String: DNSName] = [:]
        private var srv: [String: SRV] = [:]
        private var txt: [String: [String]] = [:]
        /// host key → address
        private var addresses: [String: String] = [:]
        /// instance key → datagram sender
        private var senders: [String: String] = [:]

        public init() {}

        public mutating func ingest(_ message: Message, from sender: String?) {
            guard message.isResponse else { return }
            for r in message.records {
                switch r.rdata {
                case .ptr(let instance) where r.name.matches(MDNS.serviceName):
                    if r.ttl == 0 { forget(instance.key) }
                case .srv(_, _, let port, let target) where isOurs(r.name):
                    if r.ttl == 0 { forget(r.name.key); continue }
                    names[r.name.key] = r.name
                    srv[r.name.key] = SRV(port: port, target: target)
                    if let sender { senders[r.name.key] = sender }
                case .txt(let strings) where isOurs(r.name):
                    names[r.name.key] = r.name
                    txt[r.name.key] = strings
                    if let sender { senders[r.name.key] = sender }
                case .a(let ip):
                    addresses[r.name.key] = ip
                default:
                    break
                }
            }
        }

        /// `<instance>._infinitus._tcp.local.`
        private func isOurs(_ name: DNSName) -> Bool {
            name.labels.count == 4 && DNSName(labels: Array(name.labels.dropFirst())).matches(MDNS.serviceName)
        }

        private mutating func forget(_ key: String) {
            names[key] = nil; srv[key] = nil; txt[key] = nil; senders[key] = nil
        }

        public var peers: [Peer] {
            names.keys.sorted().compactMap { key in
                guard let name = names[key], let s = srv[key], let t = txt[key] else { return nil }
                return Peer(instance: name.labels[0], host: s.target.dotted, port: s.port, txt: t,
                            ipv4: addresses[s.target.key] ?? senders[key])
            }
        }
    }
}

// MARK: - Sockets (macOS + Linux)

#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
private let datagramSocketType = SOCK_DGRAM
#else
import Glibc
private let datagramSocketType = Int32(SOCK_DGRAM.rawValue)
#endif

extension MDNS {
    public enum SocketError: Error, Equatable {
        case socket(Int32), bind(Int32), membership(Int32), send(Int32)
    }

    /// One UDP socket on 0.0.0.0:5353 in the 224.0.0.251 group. Bound with
    /// SO_REUSEADDR + SO_REUSEPORT so it sits beside mDNSResponder (macOS)
    /// or avahi (Linux), with multicast loopback on so two sockets in one
    /// process hear each other (the tests; `--discoverable` browsing itself).
    public final class Socket: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var closed = false

        public init() throws {
            let fd = socket(AF_INET, datagramSocketType, 0)
            guard fd >= 0 else { throw SocketError.socket(errno) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = MDNS.port.bigEndian
            addr.sin_addr = in_addr(s_addr: in_addr_t(0))   // INADDR_ANY
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { let e = errno; close(fd); throw SocketError.bind(e) }
            var mreq = ip_mreq()
            inet_pton(AF_INET, MDNS.groupIPv4, &mreq.imr_multiaddr)
            mreq.imr_interface = in_addr(s_addr: in_addr_t(0))
            guard setsockopt(fd, Int32(IPPROTO_IP), Int32(IP_ADD_MEMBERSHIP), &mreq,
                             socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                let e = errno; close(fd); throw SocketError.membership(e)
            }
            var ttl: UInt8 = 255
            setsockopt(fd, Int32(IPPROTO_IP), Int32(IP_MULTICAST_TTL), &ttl, 1)
            var loop: UInt8 = 1
            setsockopt(fd, Int32(IPPROTO_IP), Int32(IP_MULTICAST_LOOP), &loop, 1)
            self.fd = fd
        }

        public func send(_ message: Message) throws {
            var to = sockaddr_in()
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = MDNS.port.bigEndian
            inet_pton(AF_INET, MDNS.groupIPv4, &to.sin_addr)
            let bytes = [UInt8](message.encode())
            let sent = withUnsafePointer(to: &to) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == bytes.count else { throw SocketError.send(errno) }
        }

        /// One datagram, or nil after `timeout` (or on an undecodable one).
        public func receive(timeout: TimeInterval) -> (message: Message, sender: String)? {
            var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, nfds_t(1), Int32(timeout * 1000)) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 9000)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            guard n > 0, let message = try? Message.decode(Data(buffer[0..<n])) else { return nil }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = from.sin_addr
            inet_ntop(AF_INET, &address, &text, socklen_t(text.count))
            return (message, String(cString: text))
        }

        /// Named so the libc `close(fd)` calls in `init` stay unambiguous
        /// (a method called `close` would shadow them).
        public func tearDown() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            close(fd)
        }

        deinit { tearDown() }
    }

    /// Advertises one service: announces on start and again a second
    /// later (RFC 6762 §8.3), answers queries until `stop()`, which sends
    /// the goodbye. One thread blocked in poll(); nothing runs while the
    /// network is quiet.
    public final class Advertiser: @unchecked Sendable {
        public let service: Service
        private let socket: Socket
        private let lock = NSLock()
        private var stopping = false
        private var thread: Thread?

        public init(service: Service) throws {
            self.service = service
            self.socket = try Socket()
        }

        public func start() throws {
            try socket.send(service.announcement())
            let thread = Thread { [self] in
                var secondAnnouncement: Date? = Date().addingTimeInterval(1)
                while !isStopping {
                    if let received = socket.receive(timeout: 1),
                       let reply = Responder.answer(received.message, service: service) {
                        try? socket.send(reply)
                    }
                    if let due = secondAnnouncement, Date() >= due {
                        try? socket.send(service.announcement())
                        secondAnnouncement = nil
                    }
                }
            }
            self.thread = thread
            thread.start()
        }

        private var isStopping: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopping
        }

        public func stop() {
            lock.lock(); stopping = true; lock.unlock()
            while let t = thread, !t.isFinished { Thread.sleep(forTimeInterval: 0.05) }
            try? socket.send(service.goodbye())
            socket.tearDown()
        }
    }

    /// Sends the PTR query (again after a second) and collects answers
    /// for `seconds`. Blocking — the CLI calls it; the app never does.
    public static func browse(seconds: TimeInterval) throws -> [Peer] {
        let socket = try Socket()
        defer { socket.tearDown() }
        var collector = Collector()
        let deadline = Date().addingTimeInterval(seconds)
        var resend: Date? = Date().addingTimeInterval(1)
        try socket.send(.query(serviceName))
        while Date() < deadline {
            if let received = socket.receive(timeout: 0.25) {
                collector.ingest(received.message, from: received.sender)
            }
            if let due = resend, Date() >= due {
                try socket.send(.query(serviceName))
                resend = nil
            }
        }
        return collector.peers
    }
}
#endif
```

- [ ] **Step 4: Run the tests**

Run: `cd ~/death/limitless-t-nearby && swift test --filter 'MDNSResponderTests|MDNSSocketTests' 2>&1 | tail -5`
Expected: 3 responder tests pass; the socket test passes on this Mac (mDNSResponder shares port 5353 through SO_REUSEPORT) or reports `skipped` with the socket error — a skip is acceptable, a failure is not. If the Linux import of `IPPROTO_IP` / `IP_ADD_MEMBERSHIP` is not an integer literal type, wrap it in `Int32(...)` exactly as written; if `pollfd(fd:events:revents:)` lacks a memberwise init on Linux, build it as `var fds = pollfd(); fds.fd = fd; fds.events = Int16(POLLIN)`.

- [ ] **Step 5: Run the whole suite**

Run: `cd ~/death/limitless-t-nearby && swift test 2>&1 | tail -3`
Expected: everything green (the new socket test adds ~3 s).

- [ ] **Step 6: Commit**

```bash
cd ~/death/limitless-t-nearby && git add Sources/InfinitusCore/MDNS.swift Tests/InfinitusCoreTests/MDNSResponderTests.swift Tests/InfinitusCoreTests/MDNSSocketTests.swift && \
git commit -m "team: mDNS responder + browser — pure answer/collect logic, one multicast UDP socket on macOS and Linux

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: TeamNearby — local standing, the two routes, request storage

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamNearby.swift`
- Test: `Tests/InfinitusCoreTests/TeamNearbyTests.swift`

**Interfaces:**
- Consumes: `NearbyRecord` (Task 1); existing `TeamClient.identity(paths:secrets:)`, `TeamClient.open(id:paths:secrets:)`, `TeamClient.isLeader` / `isMember` / `config`, `TeamClient.tokenName(_:)`, `TeamClient.identitySecretName`, `TeamConfig`, `TeamPaths` (`teamIDs()`, `teamDir`, `configFile`, `storeDir`), `TeamSecrets`, `TeamGit(dir:remote:token:author:)` + `open()` + `put(_:_:)`, `TeamKeys`, `TeamRequest`, `Signed<T>` (`verify(with:)`), `CanonicalJSON`, `MirrorTransport.Request` / `jsonResponse` / `notFoundResponse` / `badRequestResponse` / `response(status:reason:contentType:body:)`.
- Produces:
  - `enum TeamNearby` with `keyPath = "/team/key"`, `requestPath = "/team/request"`, `routePrefix = "/team/"`, `discoverableDefaultsKey = "team_discoverable"`, `pendingCap = 100`
  - `struct TeamNearby.KeyReply: Codable, Equatable, Sendable { name: String; keys: TeamKeys; team: String?; role: String }`
  - `struct TeamNearby.Request: Codable, Equatable, Sendable { team: String; request: Signed<TeamRequest> }`
  - `struct TeamNearby.RequestReply: Codable, Equatable, Sendable { ok: Bool; stored: String }` (`"branch"` | `"pending"`)
  - `struct TeamNearby.Local: Equatable, Sendable { record: NearbyRecord; keys: TeamKeys? }`, `static let hidden`, `static func load(name:discoverable:paths:secrets:) -> Local`
  - `struct TeamNearby.Endpoint { local: Local; store: (Request) throws -> String }`, `init(local:store:)`
  - `static func TeamNearby.respond(_ request: MirrorTransport.Request, endpoint: Endpoint?) -> Data?` (nil = not a team route)
  - `enum TeamNearby.StoreError: Error, Equatable { case unknownTeam, badKid, full }`
  - `enum TeamNearby.Store { static func pendingDir(team:paths:) -> URL; static func save(_:paths:secrets:) throws -> String; static func pending(team:paths:) -> [Signed<TeamRequest>]; static func writeToRequestsBranch(team:signed:paths:secrets:) throws }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/InfinitusCoreTests/TeamNearbyTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamNearbyTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("teamnearby-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    func makeRemote() throws -> String {
        let bare = scratch.appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "--bare", "-q", bare.path]
        try p.run(); p.waitUntilExit()
        return "file://" + bare.path
    }

    /// One "machine": its own paths and secrets.
    func machine(_ name: String) -> (TeamPaths, FileSecrets) {
        let paths = TeamPaths(base: scratch.appendingPathComponent(name))
        return (paths, FileSecrets(dir: paths.secretsDir))
    }

    func http(_ method: String, _ path: String, body: Data = Data()) -> MirrorTransport.Request {
        MirrorTransport.Request(method: method, target: path, headers: [:], body: body)
    }

    func status(_ data: Data?) -> Int? { data.flatMap(MirrorTransport.parseResponse)?.status }

    func body<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
        try CanonicalJSON.decode(type, from: try XCTUnwrap(data.flatMap(MirrorTransport.parseResponse)).body)
    }

    func testLocalStandingFollowsTheRosterAndTheSwitch() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let on = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        XCTAssertEqual(on.record, NearbyRecord(name: "Loc", kid: leader.identity.kid, team: leader.config.id,
                                               role: "leader", discoverable: true))
        XCTAssertEqual(on.keys, leader.identity.keys)
        XCTAssertEqual(TeamNearby.Local.load(name: "Loc", discoverable: false, paths: lp, secrets: ls), .hidden)
        // No team yet: role none, and an identity is minted so an invite has a kid to target.
        let (jp, js) = machine("joiner")
        let joiner = TeamNearby.Local.load(name: "Bo", discoverable: true, paths: jp, secrets: js)
        XCTAssertEqual(joiner.record.role, "none")
        XCTAssertNil(joiner.record.team)
        XCTAssertEqual(joiner.keys, try TeamClient.identity(paths: jp, secrets: js).keys)
        // Hidden never mints one.
        let (hp, hs) = machine("hidden")
        _ = TeamNearby.Local.load(name: "H", discoverable: false, paths: hp, secrets: hs)
        XCTAssertNil(hs.read(TeamClient.identitySecretName))
    }

    func testRoutesAnswerOnlyWhenDiscoverable() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let local = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        let endpoint = TeamNearby.Endpoint(local: local) { _ in "branch" }
        // Not ours: the caller keeps routing.
        XCTAssertNil(TeamNearby.respond(http("GET", "/snapshot"), endpoint: endpoint))
        let key = TeamNearby.respond(http("GET", TeamNearby.keyPath), endpoint: endpoint)
        XCTAssertEqual(status(key), 200)
        XCTAssertEqual(try body(TeamNearby.KeyReply.self, key),
                       TeamNearby.KeyReply(name: "Loc", keys: leader.identity.keys, team: leader.config.id, role: "leader"))
        // Hidden or absent: 404 on every team route, nothing about the team leaks.
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.keyPath), endpoint: nil)), 404)
        let hidden = TeamNearby.Endpoint(local: .hidden) { _ in "branch" }
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.keyPath), endpoint: hidden)), 404)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath), endpoint: hidden)), 404)
        // Wrong method, and step 6's route that isn't here yet.
        XCTAssertEqual(status(TeamNearby.respond(http("GET", TeamNearby.requestPath), endpoint: endpoint)), 404)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", "/team/invite"), endpoint: endpoint)), 404)
    }

    func testRequestOverTheLanLandsInTheRequestsBranch() throws {
        let remote = try makeRemote()
        let (lp, ls) = machine("leader")
        let (jp, js) = machine("joiner")
        let leader = try TeamClient.create(name: "Papaya", remote: remote, token: nil, paths: lp, secrets: ls, now: 1_000)
        let joiner = try TeamClient.identity(paths: jp, secrets: js)
        let signed = try Signed.make(TeamRequest(keys: joiner.keys, name: "Bo", devices: ["Linux"], platform: "linux", at: 1_010),
                                     by: joiner)
        let request = try CanonicalJSON.encode(TeamNearby.Request(team: leader.config.id, request: signed))
        let local = TeamNearby.Local.load(name: "Loc", discoverable: true, paths: lp, secrets: ls)
        let endpoint = TeamNearby.Endpoint(local: local) { try TeamNearby.Store.save($0, paths: lp, secrets: ls) }

        let response = TeamNearby.respond(http("POST", TeamNearby.requestPath, body: request), endpoint: endpoint)
        XCTAssertEqual(status(response), 200)
        XCTAssertEqual(try body(TeamNearby.RequestReply.self, response), TeamNearby.RequestReply(ok: true, stored: "branch"))
        XCTAssertEqual(TeamNearby.Store.pending(team: leader.config.id, paths: lp), [])
        // The leader's ordinary path sees it and approves it.
        _ = try leader.fetch()
        XCTAssertEqual(try leader.requests().map(\.doc.name), ["Bo"])
        try leader.approve(kid: joiner.kid, now: 1_020)
        XCTAssertEqual(leader.roster?.doc.members.map(\.name), ["Bo"])

        // Wrong team → 404; a tampered document → 400; not JSON → 400.
        let elsewhere = try CanonicalJSON.encode(TeamNearby.Request(team: "other", request: signed))
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: elsewhere), endpoint: endpoint)), 404)
        var forged = signed
        forged.doc.name = "Eve"
        let forgedBody = try CanonicalJSON.encode(TeamNearby.Request(team: leader.config.id, request: forged))
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: forgedBody), endpoint: endpoint)), 400)
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: Data("nope".utf8)), endpoint: endpoint)), 400)
        // The store refusing is a 503, not a crash.
        let broken = TeamNearby.Endpoint(local: local) { _ in throw TeamNearby.StoreError.full }
        XCTAssertEqual(status(TeamNearby.respond(http("POST", TeamNearby.requestPath, body: request), endpoint: broken)), 503)
    }

    func testRequestStaysPendingWhenTheStoreIsUnreachable() throws {
        let (lp, ls) = machine("leader")
        // A team whose remote doesn't exist: config on disk, store never cloned.
        let me = try TeamClient.identity(paths: lp, secrets: ls)
        let config = TeamConfig(id: "t-offline", name: "Ghost", remote: "file:///nonexistent/ghost.git",
                                kid: me.kid, joinedAt: 1, leaderKid: me.kid)
        try FileManager.default.createDirectory(at: lp.teamDir("t-offline"), withIntermediateDirectories: true)
        try CanonicalJSON.encode(config).write(to: lp.configFile("t-offline"))
        let joiner = TeamIdentity.random()
        let signed = try Signed.make(TeamRequest(keys: joiner.keys, name: "Bo", devices: [], platform: "linux", at: 5), by: joiner)
        let incoming = TeamNearby.Request(team: "t-offline", request: signed)
        XCTAssertEqual(try TeamNearby.Store.save(incoming, paths: lp, secrets: ls), "pending")
        XCTAssertEqual(TeamNearby.Store.pending(team: "t-offline", paths: lp), [signed])
        // The same kid again replaces, never duplicates.
        XCTAssertEqual(try TeamNearby.Store.save(incoming, paths: lp, secrets: ls), "pending")
        XCTAssertEqual(TeamNearby.Store.pending(team: "t-offline", paths: lp).count, 1)
        // An unknown team is refused.
        XCTAssertThrowsError(try TeamNearby.Store.save(TeamNearby.Request(team: "nope", request: signed), paths: lp, secrets: ls)) {
            XCTAssertEqual($0 as? TeamNearby.StoreError, .unknownTeam)
        }
        // A garbled pending file is skipped, not fatal.
        try Data("junk".utf8).write(to: TeamNearby.Store.pendingDir(team: "t-offline", paths: lp).appendingPathComponent("zzz.json"))
        XCTAssertEqual(TeamNearby.Store.pending(team: "t-offline", paths: lp), [signed])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/death/limitless-t-nearby && swift test --filter TeamNearbyTests 2>&1 | tail -3`
Expected: compile error, `TeamNearby` not found.

- [ ] **Step 3: Implement**

Create `Sources/InfinitusCore/Team/TeamNearby.swift`:

```swift
import Foundation

/// The team side of Nearby (spec §6.4): what this machine advertises,
/// the two LAN routes (`GET /team/key`, `POST /team/request`) as pure
/// request → response functions so the Mac's MirrorServer and the
/// Linux PosixHTTPServer mount one handler, and where an incoming
/// request lands. `POST /team/invite` is step 6's. Lives beside
/// TeamClient, never in it: TeamClient's surface is the publisher's.
public enum TeamNearby {
    public static let keyPath = "/team/key"
    public static let requestPath = "/team/request"
    public static let routePrefix = "/team/"
    /// The UserDefaults bool the Mac app, its Team pane (plan 5) and
    /// `infinitusctl team-discoverable` share. Off by default.
    public static let discoverableDefaultsKey = "team_discoverable"
    /// Pending requests kept per team: the LAN route needs no token, so
    /// its footprint on disk is bounded.
    public static let pendingCap = 100

    /// `GET /team/key`.
    public struct KeyReply: Codable, Equatable, Sendable {
        public var name: String
        public var keys: TeamKeys
        public var team: String?
        public var role: String

        public init(name: String, keys: TeamKeys, team: String?, role: String) {
            self.name = name; self.keys = keys; self.team = team; self.role = role
        }
    }

    /// `POST /team/request` body. `TeamRequest` names no team (a leader
    /// may lead several), so the LAN body says which one.
    public struct Request: Codable, Equatable, Sendable {
        public var team: String
        public var request: Signed<TeamRequest>

        public init(team: String, request: Signed<TeamRequest>) {
            self.team = team; self.request = request
        }
    }

    public struct RequestReply: Codable, Equatable, Sendable {
        public var ok: Bool
        /// "branch": the team's requests branch took it (the leader's
        /// `requests()` sees it); "pending": kept locally until it can.
        public var stored: String

        public init(ok: Bool, stored: String) { self.ok = ok; self.stored = stored }
    }

    // MARK: local standing

    public struct Local: Equatable, Sendable {
        public var record: NearbyRecord
        /// nil while hidden: no identity is minted for a machine that
        /// isn't advertising.
        public var keys: TeamKeys?

        public init(record: NearbyRecord, keys: TeamKeys?) { self.record = record; self.keys = keys }

        public static let hidden = Local(record: .hidden, keys: nil)

        /// Leader of any team → leader of the first (sorted) such team;
        /// else member likewise; else none. Opens the team clones (file
        /// IO, no network on an existing mirror) — the app calls this off
        /// the main actor.
        public static func load(name: String, discoverable: Bool, paths: TeamPaths, secrets: TeamSecrets) -> Local {
            guard discoverable, let me = try? TeamClient.identity(paths: paths, secrets: secrets) else { return .hidden }
            var team: String? = nil
            var role = "none"
            for id in paths.teamIDs() {
                guard let client = try? TeamClient.open(id: id, paths: paths, secrets: secrets) else { continue }
                if client.isLeader { team = id; role = "leader"; break }
                if client.isMember, role == "none" { team = id; role = "member" }
            }
            return Local(record: NearbyRecord(name: name, kid: me.kid, team: team, role: role, discoverable: true),
                         keys: me.keys)
        }
    }

    // MARK: routes

    /// What the routes need: the local standing and where a request goes
    /// (`store` returns "branch" or "pending").
    public struct Endpoint {
        public var local: Local
        public var store: (Request) throws -> String

        public init(local: Local, store: @escaping (Request) throws -> String) {
            self.local = local; self.store = store
        }
    }

    /// nil = not a `/team/` route, keep routing. A hidden (or absent)
    /// endpoint answers 404 to every team route — the spec's "off ⇒ the
    /// endpoints answer 404". No pairing token here: peers have none.
    public static func respond(_ request: MirrorTransport.Request, endpoint: Endpoint?) -> Data? {
        guard request.path.hasPrefix(routePrefix) else { return nil }
        guard let endpoint, endpoint.local.record.discoverable, let keys = endpoint.local.keys else {
            return MirrorTransport.notFoundResponse()
        }
        switch (request.method, request.path) {
        case ("GET", TeamNearby.keyPath):
            let reply = KeyReply(name: endpoint.local.record.name, keys: keys,
                                 team: endpoint.local.record.team, role: endpoint.local.record.role)
            guard let body = try? CanonicalJSON.encode(reply) else { return MirrorTransport.notFoundResponse() }
            return MirrorTransport.jsonResponse(body)
        case ("POST", TeamNearby.requestPath):
            guard let incoming = try? CanonicalJSON.decode(Request.self, from: request.body),
                  (try? incoming.request.verify(with: incoming.request.doc.keys)) != nil else {
                return MirrorTransport.badRequestResponse()
            }
            guard incoming.team == endpoint.local.record.team else { return MirrorTransport.notFoundResponse() }
            do {
                let stored = try endpoint.store(incoming)
                guard let body = try? CanonicalJSON.encode(RequestReply(ok: true, stored: stored)) else {
                    return MirrorTransport.notFoundResponse()
                }
                return MirrorTransport.jsonResponse(body)
            } catch {
                return MirrorTransport.response(status: 503, reason: "Service Unavailable", contentType: "text/plain",
                                                body: Data("request not stored\n".utf8))
            }
        default:
            return MirrorTransport.notFoundResponse()
        }
    }

    // MARK: storage

    public enum StoreError: Error, Equatable { case unknownTeam, badKid, full }

    public enum Store {
        public static func pendingDir(team: String, paths: TeamPaths) -> URL {
            paths.teamDir(team).appendingPathComponent("pending")
        }

        /// A kid names one file, so it is one path segment.
        static func isPathSegment(_ kid: String) -> Bool {
            !kid.isEmpty && !kid.contains("/") && kid != "." && kid != ".."
        }

        /// Keeps the request under `<team>/pending/<kid>.json`, then tries
        /// the team's `requests` branch; on success the pending copy goes
        /// (the leader's `requests()` sees it there). "branch" | "pending".
        public static func save(_ incoming: Request, paths: TeamPaths, secrets: TeamSecrets) throws -> String {
            let kid = incoming.request.doc.keys.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            guard paths.teamIDs().contains(incoming.team) else { throw StoreError.unknownTeam }
            let dir = pendingDir(team: incoming.team, paths: paths)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(kid).json")
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard existing.count < TeamNearby.pendingCap || FileManager.default.fileExists(atPath: file.path) else {
                throw StoreError.full
            }
            try CanonicalJSON.encode(incoming.request).write(to: file)
            do {
                try writeToRequestsBranch(team: incoming.team, signed: incoming.request, paths: paths, secrets: secrets)
            } catch {
                return "pending"
            }
            try? FileManager.default.removeItem(at: file)
            return "branch"
        }

        /// Requests that never reached the branch, by kid; unreadable or
        /// unverifiable files are skipped.
        public static func pending(team: String, paths: TeamPaths) -> [Signed<TeamRequest>] {
            let dir = pendingDir(team: team, paths: paths)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            return names.compactMap { name in
                guard name.hasSuffix(".json"),
                      let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let signed = try? CanonicalJSON.decode(Signed<TeamRequest>.self, from: data),
                      (try? signed.verify(with: signed.doc.keys)) != nil else { return nil }
                return signed
            }
        }

        /// `requests/<kid>.json` on the team's store, with whatever
        /// credential this machine holds: the leader's when a request
        /// arrives over the LAN, the joiner's own when it already has the
        /// code. TeamClient keeps its store private, so this opens the
        /// same bare mirror TeamClient uses (`paths.storeDir`).
        public static func writeToRequestsBranch(team: String, signed: Signed<TeamRequest>,
                                                 paths: TeamPaths, secrets: TeamSecrets) throws {
            let kid = signed.doc.keys.kid
            guard isPathSegment(kid) else { throw StoreError.badKid }
            let config = try CanonicalJSON.decode(TeamConfig.self, from: try Data(contentsOf: paths.configFile(team)))
            let token = secrets.read(TeamClient.tokenName(team)).map { String(decoding: $0, as: UTF8.self) }
            let store = TeamGit(dir: paths.storeDir(team), remote: config.remote, token: token, author: config.kid)
            try store.open()
            try store.put("requests/\(kid).json", try CanonicalJSON.encode(signed))
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd ~/death/limitless-t-nearby && swift test --filter TeamNearbyTests 2>&1 | tail -3`
Expected: 4 tests pass. `testRequestStaysPendingWhenTheStoreIsUnreachable` exercises `TeamGit.open()` on a fresh mirror whose first fetch fails — that throw is what turns into `"pending"`.

- [ ] **Step 5: Commit**

```bash
cd ~/death/limitless-t-nearby && git add Sources/InfinitusCore/Team/TeamNearby.swift Tests/InfinitusCoreTests/TeamNearbyTests.swift && \
git commit -m "team: nearby standing + LAN routes — GET /team/key, POST /team/request verified and stored to the requests branch or pending

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: CLI — `team nearby`, `team request --nearby`, `team --discoverable`

**Files:**
- Create: `Sources/InfinitusCLI/TeamNearbyCommand.swift`
- Modify: `Sources/InfinitusCLI/TeamCommand.swift` (one line at the top of `runTeam`, currently line 45 `func runTeam(_ args: [String]) -> Int32 {`)

**Interfaces:**
- Consumes: `MDNS.browse(seconds:)`, `MDNS.Service`, `MDNS.Advertiser`, `MDNS.hostLabel` (Task 3); `NearbyRecord(txtStrings:)` (Task 1); `TeamNearby.Local.load`, `TeamNearby.Endpoint`, `TeamNearby.respond`, `TeamNearby.Store.save` / `writeToRequestsBranch`, `TeamNearby.KeyReply` / `Request` / `RequestReply`, `TeamNearby.keyPath` / `requestPath` (Task 4); existing `TeamPaths.standard()`, `FileSecrets`, `TeamClient.identity`, `TeamRequest`, `Signed.make`, `CanonicalJSON`, `PosixHTTPServer` + `PosixInterfaceAddresses.ipv4()` (Glibc only), `MirrorTransport.notFoundResponse()`.
- Produces: `func runTeamNearby(_ args: [String]) -> Int32?` (nil when the args are not a nearby command), `func teamNearbyUsage() -> String`.

- [ ] **Step 1: Add the dispatch line**

In `Sources/InfinitusCLI/TeamCommand.swift`, make the first statement of `runTeam` the nearby dispatch:

```swift
func runTeam(_ args: [String]) -> Int32 {
    if let code = runTeamNearby(args) { return code }   // nearby | --discoverable | request --nearby (TeamNearbyCommand.swift)
    guard let sub = args.first, sub != "--help", sub != "-h" else {
```

Nothing else in that file changes.

- [ ] **Step 2: Write the command**

Create `Sources/InfinitusCLI/TeamNearbyCommand.swift`:

```swift
import Foundation
import InfinitusCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// `infinitusctl team nearby | request --nearby <kid> | --discoverable`
// (spec §6.4, §9 "Linux/Windows discovery"): the mDNS browser and
// responder from MDNS.swift, the two LAN routes over PosixHTTPServer.
// Its own file so TeamCommand.swift (the publisher's) carries only the
// dispatch line at the top of `runTeam`.

func teamNearbyUsage() -> String {
    """
    usage: infinitusctl team nearby [--seconds N]
               list Infinitus machines on this network (default 3 s)
           infinitusctl team request --nearby <kid> --name <n> [--devices a,b] [--seconds N]
               send a join request to that leader over the LAN — no code to paste
           infinitusctl team --discoverable [--name <n>] [--port N]
               advertise this machine and answer /team/key + /team/request until Ctrl-C (Linux;
               on the Mac the app advertises: `infinitusctl team-discoverable on`).
               Binds every interface: run it on a LAN you trust, never on a box with a public address.

    """
}

struct NearbyPeerRow: Encodable {
    var name: String
    var host: String
    var ipv4: String?
    var port: UInt16
    var kid: String?
    var team: String?
    var role: String?
    var discoverable: Bool
}

#if os(macOS)
private let nearbyPlatform = "macos"
#elseif os(Linux)
private let nearbyPlatform = "linux"
#else
private let nearbyPlatform = "windows"
#endif

private func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

private func fail(_ message: String, code: Int32 = 1) -> Int32 {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    return code
}

/// nil when `args` is not a nearby command — `runTeam` carries on.
func runTeamNearby(_ args: [String]) -> Int32? {
    guard let sub = args.first else { return nil }
    let mine = sub == "nearby" || sub == "--discoverable" || (sub == "request" && args.contains("--nearby"))
    guard mine else { return nil }
    if args.contains("--help") || args.contains("-h") {
        print(teamNearbyUsage(), terminator: "")
        return 0
    }
    // Every option takes a value; a bare flag is a typo (same rule as `runTeam`).
    var options: [String: String] = [:]
    var i = 1
    while i < args.count {
        let a = args[i]
        guard a.hasPrefix("--") else { return fail(teamNearbyUsage(), code: 2) }
        let key = String(a.dropFirst(2))
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
            return fail("--\(key) needs a value\n\n\(teamNearbyUsage())", code: 2)
        }
        options[key] = args[i + 1]
        i += 2
    }
    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)
    let seconds = Double(options["seconds"] ?? "3") ?? 3
    do {
        switch sub {
        case "nearby":
            emit(try browsePeers(seconds: seconds))
        case "request":
            guard let kid = options["nearby"], let name = options["name"] else { return fail(teamNearbyUsage(), code: 2) }
            guard let peer = try browsePeers(seconds: seconds).first(where: { $0.kid == kid && $0.discoverable }) else {
                return fail("no discoverable machine with kid \(kid) answered within \(Int(seconds))s")
            }
            guard peer.role == "leader", let team = peer.team else { return fail("\(peer.name) leads no team") }
            let host = peer.ipv4 ?? String(peer.host.dropLast(peer.host.hasSuffix(".") ? 1 : 0))
            // The peer must be who its TXT says it is before anything is sent.
            let (keyStatus, keyBody) = try http("GET", host: host, port: peer.port, path: TeamNearby.keyPath)
            guard keyStatus == 200,
                  let leaderKey = try? CanonicalJSON.decode(TeamNearby.KeyReply.self, from: keyBody),
                  leaderKey.keys.kid == kid else {
                return fail("\(peer.name) is not answering \(TeamNearby.keyPath) (\(keyStatus))")
            }
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            let devices = options["devices"]?.split(separator: ",").map(String.init) ?? []
            let request = TeamRequest(keys: me.keys, name: name, devices: devices, platform: nearbyPlatform,
                                      at: Int(Date().timeIntervalSince1970))
            let signed = try Signed.make(request, by: me)
            let body = try CanonicalJSON.encode(TeamNearby.Request(team: team, request: signed))
            let (status, replyBody) = try http("POST", host: host, port: peer.port, path: TeamNearby.requestPath, body: body)
            guard status == 200, let reply = try? CanonicalJSON.decode(TeamNearby.RequestReply.self, from: replyBody) else {
                return fail("\(peer.name) refused the request (\(status))")
            }
            // Already holding the store credential (a code from before)?
            // Then the branch too, so an offline leader still sees it.
            var stored = reply.stored
            if paths.teamIDs().contains(team) {
                try TeamNearby.Store.writeToRequestsBranch(team: team, signed: signed, paths: paths, secrets: secrets)
                stored = "branch"
            }
            emit(["team": team, "leader": kid, "kid": me.kid, "stored": stored])
        case "--discoverable":
            return runDiscoverable(name: options["name"], port: UInt16(options["port"] ?? "0") ?? 0,
                                   paths: paths, secrets: secrets)
        default:
            return nil
        }
        return 0
    } catch {
        return fail("\(error)")
    }
}

private func browsePeers(seconds: Double) throws -> [NearbyPeerRow] {
    #if os(macOS) || os(Linux)
    return try MDNS.browse(seconds: seconds).map { peer in
        let record = NearbyRecord(txtStrings: peer.txt) ?? .hidden
        return NearbyPeerRow(name: record.discoverable ? record.name : peer.instance,
                             host: peer.host, ipv4: peer.ipv4, port: peer.port,
                             kid: record.discoverable ? record.kid : nil,
                             team: record.team,
                             role: record.discoverable ? record.role : nil,
                             discoverable: record.discoverable)
    }
    #else
    throw NSError(domain: "team", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "nearby discovery is not built for this platform yet"])
    #endif
}

/// One blocking HTTP exchange with a peer; the CLI has no event loop to
/// hand a completion to.
private func http(_ method: String, host: String, port: UInt16, path: String, body: Data? = nil) throws -> (Int, Data) {
    let bracketed = host.contains(":") ? "[\(host)]" : host
    guard let url = URL(string: "http://\(bracketed):\(port)\(path)") else {
        throw NSError(domain: "team", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad peer address \(host):\(port)"])
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 10
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let done = DispatchSemaphore(value: 0)
    var result: (Int, Data) = (0, Data())
    var failure: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { failure = error }
        else { result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    if let failure { throw failure }
    return result
}

/// Set from the signal handler; read by the main thread's wait loop.
private var discoverableStopRequested = false

private func runDiscoverable(name: String?, port: UInt16, paths: TeamPaths, secrets: TeamSecrets) -> Int32 {
    #if canImport(Glibc)
    let machine = name ?? ProcessInfo.processInfo.hostName
    let local = TeamNearby.Local.load(name: machine, discoverable: true, paths: paths, secrets: secrets)
    let endpoint = TeamNearby.Endpoint(local: local) { try TeamNearby.Store.save($0, paths: paths, secrets: secrets) }
    let server = PosixHTTPServer { request in
        TeamNearby.respond(request, endpoint: endpoint) ?? MirrorTransport.notFoundResponse()
    }
    do {
        let bound = try server.start(port: port)
        let ipv4 = PosixInterfaceAddresses.ipv4().first ?? "127.0.0.1"
        let service = MDNS.Service(instance: machine, host: MDNS.hostLabel(machine), port: bound,
                                   txt: local.record.txtStrings, ipv4: ipv4)
        let advertiser = try MDNS.Advertiser(service: service)
        try advertiser.start()
        FileHandle.standardError.write(Data(
            "discoverable as \(machine) (kid \(local.record.kid), \(local.record.role)) on \(ipv4):\(bound) — Ctrl-C to stop\n".utf8))
        // Ctrl-C sends the goodbye first: a bare SIGINT death would leave
        // a stale PTR in every browser's cache for 75 minutes. A
        // non-capturing C handler flips a flag (SIG_IGN is a macro cast
        // Glibc doesn't import; libdispatch signal sources are Darwin-shaped).
        signal(SIGINT) { _ in discoverableStopRequested = true }
        signal(SIGTERM) { _ in discoverableStopRequested = true }
        while !discoverableStopRequested { Thread.sleep(forTimeInterval: 0.25) }
        advertiser.stop()
        server.stop()
        return 0
    } catch {
        return fail("\(error)")
    }
    #else
    return fail("`team --discoverable` serves on Linux; on the Mac the Infinitus app advertises — `infinitusctl team-discoverable on`",
                code: 2)
    #endif
}
```

- [ ] **Step 3: Build and try the command**

Run: `cd ~/death/limitless-t-nearby && swift build --product infinitusctl 2>&1 | tail -3`
Expected: `Build complete!` (Sendable warnings from the closures are fine; no errors).

Run: `cd ~/death/limitless-t-nearby && .build/debug/infinitusctl team nearby --help`
Expected: the usage block above, exit 0.

Run: `cd ~/death/limitless-t-nearby && .build/debug/infinitusctl team nearby --seconds 1`
Expected: a JSON array — `[]` on a quiet network, or one row per Infinitus machine answering (a running Infinitus.app shows with `"discoverable": false` until Task 6 ships and the switch is on).

Run: `cd ~/death/limitless-t-nearby && INFINITUS_TEAM_DIR=$(mktemp -d) .build/debug/infinitusctl team --discoverable; echo "exit $?"`
Expected on the Mac: the guidance line on stderr, `exit 2`.

Run: `cd ~/death/limitless-t-nearby && .build/debug/infinitusctl team code --days x 2>&1 | head -1`
Expected: the existing `runTeam` behaviour is untouched (`error: no team on this machine …` or a code) — the dispatch line only claims the three nearby shapes.

- [ ] **Step 4: Run the suite**

Run: `cd ~/death/limitless-t-nearby && swift test 2>&1 | tail -3`
Expected: green.

- [ ] **Step 5: Commit**

```bash
cd ~/death/limitless-t-nearby && git add Sources/InfinitusCLI/TeamNearbyCommand.swift Sources/InfinitusCLI/TeamCommand.swift && \
git commit -m "team: infinitusctl team nearby / request --nearby <kid> / --discoverable — browse, request over the LAN, advertise on Linux

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Mac — TXT record, `/team/*` routes, `team-discoverable`, CHANGELOG

**Files:**
- Modify: `Sources/Infinitus/MirrorServer.swift` (box after `MirrorSessionInputBox`, ~line 186; properties ~line 214; `start` ~line 222; `listen` ~line 240; `serve`/`receive` ~line 300 onward)
- Modify: `Sources/InfinitusCore/ControlProtocol.swift` (the `ControlCommand.all` array, after the `proxy-routing` entry ~line 226)
- Modify: `Sources/Infinitus/ControlServer.swift` (`dispatch`, before `default:` ~line 463)
- Modify: `CHANGELOG.md` (under `### Team (preview)`, line 56)
- Test: `Tests/InfinitusCoreTests/TeamNearbyManifestTests.swift`

**Interfaces:**
- Consumes: `TeamNearby.Local.load`, `TeamNearby.Endpoint`, `TeamNearby.respond`, `TeamNearby.Store.save`, `TeamNearby.routePrefix`, `TeamNearby.discoverableDefaultsKey` (Task 4); `NearbyRecord.txtData` (Task 1); existing `TeamPaths.standard()`, `FileSecrets`, `MirrorTransport.bonjourType`, `NWListener.Service(name:type:domain:txtRecord:)`, `ControlCommand`, `ControlReply`, `JSONValue`.
- Produces: `MirrorTeamBox` (`current: TeamNearby.Local`, `set(_:)`, `endpoint: TeamNearby.Endpoint`); `MirrorServer.team: MirrorTeamBox`; control command `team-discoverable on|off` → `{discoverable: Bool}`.

- [ ] **Step 1: Write the failing manifest test**

Create `Tests/InfinitusCoreTests/TeamNearbyManifestTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamNearbyManifestTests: XCTestCase {
    func testTeamDiscoverableIsInTheManifest() {
        let command = ControlCommand.named("team-discoverable")
        XCTAssertEqual(command?.args, ["on|off"])
        XCTAssertEqual(command?.effect, .write)
        XCTAssertEqual(command?.replyShape, "{discoverable}")
    }
}
```

Run: `cd ~/death/limitless-t-nearby && swift test --filter TeamNearbyManifestTests 2>&1 | tail -3`
Expected: FAIL (`named` returns nil).

- [ ] **Step 2: The manifest entry and the control case**

In `Sources/InfinitusCore/ControlProtocol.swift`, after the `proxy-routing` entry (the last one in `ControlCommand.all`), add:

```swift
        ControlCommand(name: "team-discoverable", args: ["on|off"], effect: .write,
                       summary: "Advertise this Mac to teams on the LAN (TXT d=1, /team/key and /team/request), or hide it.",
                       replyShape: "{discoverable}"),
```

In `Sources/Infinitus/ControlServer.swift`, in `dispatch`, before `default:`:

```swift
        case "team-discoverable":
            guard let arg = r.args.first, ["on", "off"].contains(arg) else { throw Fail("usage: team-discoverable on|off") }
            // MirrorServer watches this default and re-advertises (Nearby, spec §6.4).
            UserDefaults.standard.set(arg == "on", forKey: TeamNearby.discoverableDefaultsKey)
            return ControlReply(ok: true, result: .object(["discoverable": .bool(arg == "on")]))
```

Run: `cd ~/death/limitless-t-nearby && swift test --filter TeamNearbyManifestTests 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 3: The box**

In `Sources/Infinitus/MirrorServer.swift`, after the `MirrorSessionInputBox` class (just before the `/// Serves the fleet snapshot to the phone (#9)` comment), add:

```swift
/// The Nearby standing (TXT record + `/team/*` routes, spec §6.4), boxed
/// like the rest: the main actor refreshes it when the discoverable
/// switch flips, the connection handlers read it on the network queue.
final class MirrorTeamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var local: TeamNearby.Local = .hidden

    var current: TeamNearby.Local {
        lock.lock(); defer { lock.unlock() }
        return local
    }

    func set(_ new: TeamNearby.Local) {
        lock.lock(); local = new; lock.unlock()
    }

    /// Where a LAN request lands: pending under the team, then the
    /// requests branch — a git push, so callers run it off the network
    /// queue.
    var endpoint: TeamNearby.Endpoint {
        TeamNearby.Endpoint(local: current) { request in
            let paths = TeamPaths.standard()
            return try TeamNearby.Store.save(request, paths: paths, secrets: FileSecrets(dir: paths.secretsDir))
        }
    }
}
```

- [ ] **Step 4: Properties, start, advertise**

In `MirrorServer`, after `let crashes = MirrorCrashBox()`, add:

```swift
    /// Nearby (spec §6.4): the TXT record and `/team/key` + `/team/request`.
    let team = MirrorTeamBox()
    private var advertisedName = ""
    private var teamDiscoverable = false
    private var defaultsObserver: NSObjectProtocol?
```

Replace `start(machineName:token:)` with:

```swift
    func start(machineName: String, token: String) {
        self.token.set(token)
        guard listener == nil else { return }
        advertisedName = machineName
        // The last export renders immediately: a phone that asks before
        // the first refresh of this launch still gets a fleet.
        if payload.latest == nil,
           let data = try? Data(contentsOf: MirrorExporter.url) {
            payload.set(data)
        }
        if defaultsObserver == nil {
            // Event-driven, never polled: the Team pane (plan 5) or
            // `infinitusctl team-discoverable` flips the default and this
            // re-advertises once per change.
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshTeamStanding() }
            }
        }
        status = "starting…"
        listen(on: MirrorTransport.defaultPort, name: machineName)
        refreshTeamStanding(force: true)
    }
```

After `stop()`, add:

```swift
    /// Reads the switch and, when it changed, rebuilds the standing off
    /// the main actor (it opens the team clones) and re-advertises.
    private func refreshTeamStanding(force: Bool = false) {
        let on = UserDefaults.standard.bool(forKey: TeamNearby.discoverableDefaultsKey)
        guard force || on != teamDiscoverable else { return }
        teamDiscoverable = on
        let name = advertisedName
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let paths = TeamPaths.standard()
            let local = TeamNearby.Local.load(name: name, discoverable: on, paths: paths,
                                              secrets: FileSecrets(dir: paths.secretsDir))
            Task { @MainActor in
                guard let self else { return }
                self.team.set(local)
                self.advertise()
                self.log?("📡", on ? "nearby: discoverable as \(name)" : "nearby: hidden")
            }
        }
    }

    /// (Re)registers the Bonjour service with the current TXT record —
    /// setting `service` on a running listener updates the record in
    /// place (nw_listener_set_advertise_descriptor).
    private func advertise() {
        listener?.service = NWListener.Service(name: advertisedName, type: MirrorTransport.bonjourType,
                                               txtRecord: team.current.record.txtData)
    }
```

In `listen(on:name:)`, replace

```swift
        listener.service = NWListener.Service(name: name,
                                              type: MirrorTransport.bonjourType)
```

with

```swift
        listener.service = NWListener.Service(name: name, type: MirrorTransport.bonjourType,
                                              txtRecord: team.current.record.txtData)
```

and, next to `let crashes = self.crashes`, add `let team = self.team`, then pass it into `Self.serve(…)` as a new `team: team` argument right after `crashes: crashes`.

- [ ] **Step 5: The routes on the network queue**

Add `team: MirrorTeamBox` as a parameter to both `serve` and `receive`, right after `crashes:` — the two signatures become:

```swift
    private nonisolated static func serve(_ connection: NWConnection,
                                          payload: MirrorPayloadBox,
                                          token: MirrorTokenBox,
                                          sessionFeed: MirrorSessionFeedBox,
                                          sessionInput: MirrorSessionInputBox,
                                          sessionImage: MirrorSessionImageBox,
                                          activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox,
                                          team: MirrorTeamBox,
                                          awsLogin: MirrorAwsLoginBox,
                                          queue: DispatchQueue,
                                          onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
```

```swift
    private nonisolated static func receive(_ connection: NWConnection,
                                            buffer: Data,
                                            payload: MirrorPayloadBox,
                                            token: MirrorTokenBox,
                                            sessionFeed: MirrorSessionFeedBox,
                                            sessionInput: MirrorSessionInputBox,
                                            sessionImage: MirrorSessionImageBox,
                                            activityTokens: MirrorActivityTokenBox, crashes: MirrorCrashBox,
                                            team: MirrorTeamBox,
                                            awsLogin: MirrorAwsLoginBox,
                                            onServed: @escaping @Sendable (MirrorTransport.Request) -> Void) {
```

and every call between them passes `team: team` in the same position — three places: `serve` → `receive`, the `newConnectionHandler` → `serve` call in `listen`, and the recursive `receive` at the bottom.

Add the LAN check as a static helper right above `serve` (after the `// MARK: - Connection handling (network queue)` comment in `MirrorServer`):

```swift
    /// RFC 1918 / link-local / loopback IPv4, or IPv6 link-local / ULA /
    /// loopback: the addresses a same-LAN peer can have. A tunnel or
    /// tailnet client (100.64/10, public v4, global v6) is never "nearby",
    /// and `/team/*` carries no pairing token, so nothing else gets in.
    nonisolated static func isLANPeer(_ endpoint: NWEndpoint?) -> Bool {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let v4):
            let b = [UInt8](v4.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        case .ipv6(let v6):
            let b = [UInt8](v6.rawValue)
            guard b.count == 16 else { return false }
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }   // fe80::/10
            if (b[0] & 0xfe) == 0xfc { return true }                     // fc00::/7
            if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
            // ::ffff:a.b.c.d — the v4-only listener never yields one, but be exact.
            if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff,
               let v4 = IPv4Address(Data(b[12...])) {
                return isLANPeer(.hostPort(host: .ipv4(v4), port: 0))
            }
            return false
        default:
            return false
        }
    }
```

In `receive`, change the head-only auth check so team routes from LAN peers bypass the pairing token:

```swift
            let head = MirrorTransport.parseRequest(buffer)
            // Peers hold no pairing token: `/team/*` from a LAN address is
            // routed on its own (TeamNearby.respond answers 404 while
            // hidden); everything else — including `/team/*` from a
            // tunnel — still needs the token before a body byte is buffered.
            let teamRoute = (head.map { $0.path.hasPrefix(TeamNearby.routePrefix) } ?? false)
                && Self.isLANPeer(connection.currentPath?.remoteEndpoint ?? connection.endpoint)
            if let head, !teamRoute, !MirrorTransport.isAuthorized(head, token: token.current) {
```

Inside `if let request = MirrorTransport.parseRequestWithBody(buffer, bodyCap: cap) {`, before `let response: Data`, add:

```swift
                if request.path.hasPrefix(TeamNearby.routePrefix),
                   Self.isLANPeer(connection.currentPath?.remoteEndpoint ?? connection.endpoint) {
                    // Off this queue: a stored request pushes to git.
                    DispatchQueue.global(qos: .utility).async {
                        let response = TeamNearby.respond(request, endpoint: team.endpoint)
                            ?? MirrorTransport.notFoundResponse()
                        connection.send(content: response,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                }
```

- [ ] **Step 6: CHANGELOG**

In `CHANGELOG.md`, under `### Team (preview)` (after the existing `infinitusctl team` bullet), add one line:

```markdown
- Nearby: a discoverable Mac or Linux box shows up to teammates on the same network, and `infinitusctl team request --nearby <kid>` sends a join request straight to a leader — no code to paste.
```

- [ ] **Step 7: Build the app and run the suite**

Run: `cd ~/death/limitless-t-nearby && swift build --product Infinitus 2>&1 | grep -E 'error|Build complete' | tail -5`
Expected: `Build complete!`, no `error:` lines (`make-app.sh` builds the same product with `-c release`; the merge owner runs that, not this worktree). (`NWListener.Service(name:type:domain:txtRecord:)` takes `Data?`; if the compiler picks the `NWTXTRecord` overload, label it `txtRecord: Optional(team.current.record.txtData)`.)

Run: `cd ~/death/limitless-t-nearby && swift test 2>&1 | tail -3`
Expected: green.

Run: `cd ~/death/limitless-t-nearby && git diff --stat`
Expected: only `MirrorServer.swift`, `ControlProtocol.swift`, `ControlServer.swift`, `CHANGELOG.md` and the new test file — no `AppModel.swift`, `SettingsPane.swift`, `StatusItemController.swift`, `TeamClient.swift`.

Do not launch the app from this worktree (three instances would collide); the e2e run in CI and the merge-owner's relaunch cover it. When the merged app runs: `infinitusctl team-discoverable on` then `infinitusctl team nearby --seconds 2` lists the Mac with `"discoverable": true` and its kid; `team-discoverable off` → `d=0` and `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:47824/team/key` prints `404`; with it on, the same curl through the tailnet address (`http://100.x.y.z:47824/team/key`) prints `401` (not a LAN peer, so the pairing-token path answers).

- [ ] **Step 8: Commit**

```bash
cd ~/death/limitless-t-nearby && git add Sources/Infinitus/MirrorServer.swift Sources/InfinitusCore/ControlProtocol.swift Sources/Infinitus/ControlServer.swift Tests/InfinitusCoreTests/TeamNearbyManifestTests.swift CHANGELOG.md && \
git commit -m "team: the Mac advertises its nearby standing — TXT n k t r d on the mirror listener, /team/key + /team/request mounted, team-discoverable on|off

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage.** §6.4 TXT keys `n k t r d`, nothing secret → Task 1 (hidden ⇒ `d=0` alone) + Task 6 (Mac) + Task 5 (Linux). §6.4 member "Request" → `POST /team/request` (Task 4), CLI `request --nearby` (Task 5), written to the requests branch when the credential is present on either side (Task 4 `Store.save` for the leader, Task 5 for a joiner that already holds the code). §6.4 "off ⇒ `d=0`, no team fields, endpoints 404" → Task 1, Task 4 `respond`, Task 6. §6.4 discoverable default off → `team_discoverable` bool, control command (Task 6), CLI flag (Task 5); the pane toggle is plan 5's. §6.4 leader "Invite" / `POST /team/invite` and the phone lists → steps 6 and 8, out of scope by decision. §9 "Linux/Windows discovery": `MDNS.swift` responder + browser (Tasks 2–3), `infinitusctl team nearby` / `--discoverable` on `PosixHTTPServer` (Task 5), wire format shared with Apple's Network.framework advertisement (Task 6). §11 mDNS packet encode/decode unit tests → Task 2 fixtures (query, announcement, compressed, goodbye, QU question), Task 3 responder/collector.

**LAN boundary.** The Mac's mirror listener can be tunnel-exposed (quick tunnel, named tunnel, tailnet); `/team/*` bypasses the pairing token only for `isLANPeer` addresses (Task 6), everything else falls through to the 401 path. Linux `--discoverable` is a purpose-run server the operator starts by hand; its usage line says what it binds.

**Placeholders.** None: every code step is complete; the fixtures are verified bytes; every referenced symbol exists in the repo or in an earlier task.

**Type consistency.** `NearbyRecord.txtStrings` / `txtData` / `init?(txtStrings:)` used identically in Tasks 3, 5, 6. `MDNS.Service(instance:host:port:txt:ipv4:)`, `MDNS.browse(seconds:)`, `MDNS.Advertiser(service:)` + `start()` / `stop()` match between Task 3 and Task 5. `TeamNearby.Local.load(name:discoverable:paths:secrets:)`, `TeamNearby.Endpoint(local:store:)`, `TeamNearby.respond(_:endpoint:)`, `TeamNearby.Store.save(_:paths:secrets:)` / `writeToRequestsBranch(team:signed:paths:secrets:)`, `TeamNearby.keyPath` / `requestPath` / `routePrefix` / `discoverableDefaultsKey` match between Tasks 4, 5, 6. `MirrorTransport.Request(method:target:headers:body:)` is the existing public init.
