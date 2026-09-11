# Team identity — export/import, recovery key, AASA + entitlement plumbing, the passkey scaffold (plan 4 of the team design) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An identity survives its machine: `infinitusctl team identity show|recovery|export|import` writes the 32-byte identity secret as a passphrase-sealed file (PBKDF2-HMAC-SHA256 600k rounds + ChaChaPoly, byte-identical on every platform) or shows it as a recovery key (base32 in 8 groups), and reads either back; the site serves the `apple-app-site-association` file the passkey path needs; `make-app.sh` embeds a provisioning profile and the associated-domains entitlement when one is supplied (dev and CI builds unchanged); a compile-checked `PasskeyIdentity` scaffold derives the secret from a passkey's PRF output for the next round to wire in.

**Architecture:** Pure InfinitusCore, all Linux-portable: `PBKDF2` over swift-crypto's `HMAC<SHA256>`; `TeamIdentityExport` (a versioned JSON file, header authenticated as ChaChaPoly AAD); `RecoveryKey` (Base32 gains `decode`); the CLI `identity` subcommand over `FileSecrets`. Site and packaging: a static JSON file plus a `_headers` line; a gated `--entitlements` in the signing step. App: one new file (`PasskeyIdentity.swift`) that nothing calls yet — `isEntitled` is false without a provisioning profile, so the local identity stays the default (spec §2.1).

**Tech Stack:** Swift 5.9 syntax (6.1 on Linux CI), swift-crypto (`HMAC`, `ChaChaPoly`, `SymmetricKey`), AuthenticationServices (macOS 15+ PRF API; the SDK interface at `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/AuthenticationServices.framework/Modules/AuthenticationServices.swiftmodule/arm64e-apple-macos.swiftinterface` is the authority on spellings), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-05-team-design.md` §2.1 (passkey path, local path + recovery key, derivation, the export: "PBKDF2-HMAC-SHA256 (600k rounds, written over swift-crypto's HMAC so it is the same on every platform) + ChaChaPoly"), §9 CLI (`identity export|import`), §11 (identity derivation vectors), §12 step 4. GitHub issue #55: the recovery-key deviation note.

## Global Constraints

- Worktree `/Users/deathemperor/death/limitless-t-identity`, branch `team-identity`, branched from main `1a850a3`; stage by explicit path; every commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; push nothing.
- **File ownership this round (three streams in parallel; the merge must be trivial).** This stream edits ONLY: new files under `Sources/InfinitusCore/Team/` (`PBKDF2.swift`, `TeamIdentityExport.swift`, `RecoveryKey.swift`), `Sources/InfinitusCore/Team/Base32.swift` (add `decode`), `Sources/InfinitusCLI/TeamCommand.swift` (one new `case "identity":` inserted directly BEFORE `case "publish":`, plus the usage text), `site/public/.well-known/apple-app-site-association` (new), `site/public/_headers`, `Infinitus.entitlements` (new), the codesign block of `make-app.sh` (never its Info.plist heredoc — the pane stream edits that), `Sources/Infinitus/PasskeyIdentity.swift` (new; no other app file), tests, CHANGELOG. Never `TeamClient.swift`, `TeamReader.swift`, `TeamDocs.swift`, `TeamKinds.swift`, `ControlProtocol.swift`, `e2e.sh`.
- No cswap anywhere; never read engine internals; never `~/.aws/login` or `~/.aws/sso`.
- **Secrets:** passphrases and recovery keys are read from stdin, never argv; the identity secret is never printed except as the recovery key on an explicit `identity recovery --show`; exported files are written 0600; nothing is logged.
- Every InfinitusCore/InfinitusCLI file compiles on Linux: `import Crypto` (never CryptoKit) in core; `Crypto.SHA256` fully qualified (an internal `SHA256` enum shadows it); no Darwin imports outside `#if canImport(Darwin)`; `Process` fenced like `TeamGit.run`.
- `PasskeyIdentity.swift` is `#if canImport(AuthenticationServices)` + `@available(macOS 15, *)` guarded, compiles in `swift build --product Infinitus`, and is called by nothing this round. It cannot be exercised here (no provisioning profile in the dev loop); Infinitus tests it on a signed build later.
- `make-app.sh` without `PROVISIONING_PROFILE` in the environment must produce byte-for-byte the same signing commands as today; `sh -n make-app.sh` after editing.
- Verification is `swift test` in this worktree (plus `swift build --product Infinitus` for Task 5); never `tools/e2e.sh`; one `--product` per `swift build`.
- Implementers spawn no subagents.
- CHANGELOG: one feature, one line, under a `### Team (preview)` heading in **`## 0.4.4 (unreleased)`** (0.4.3 shipped; add the heading directly before `## 0.4.3` if it is not there yet).

---

## File structure

| file | responsibility |
|---|---|
| `Sources/InfinitusCore/Team/PBKDF2.swift` (new) | `PBKDF2.sha256(password:salt:rounds:length:)` — RFC 8018 over `HMAC<SHA256>` |
| `Sources/InfinitusCore/Team/TeamIdentityExport.swift` (new) | the sealed export file: `export(secret:passphrase:rounds:)`, `import(_:passphrase:)`, `File` |
| `Sources/InfinitusCore/Team/RecoveryKey.swift` (new) | `RecoveryKey.encode(_:)` / `decode(_:)` — base32 in 8 dashed groups |
| `Sources/InfinitusCore/Team/Base32.swift` (modify) | `Base32.decode(_:) -> Data?` |
| `Sources/InfinitusCLI/TeamCommand.swift` (modify) | `team identity show|recovery|export|import` |
| `site/public/.well-known/apple-app-site-association` (new), `site/public/_headers` (modify) | the passkey relying party's static file, served as JSON |
| `Infinitus.entitlements` (new), `make-app.sh` (modify, codesign block) | associated-domains entitlement, applied only with a provisioning profile |
| `Sources/Infinitus/PasskeyIdentity.swift` (new) | PRF-based secret derivation scaffold (register / assert), `isEntitled` |
| `Tests/InfinitusCoreTests/PBKDF2Tests.swift`, `TeamIdentityExportTests.swift`, `RecoveryKeyTests.swift` (new) | tests |
| `CHANGELOG.md` | two lines |

---

### Task 1: PBKDF2-HMAC-SHA256

**Files:**
- Create: `Sources/InfinitusCore/Team/PBKDF2.swift`
- Test: `Tests/InfinitusCoreTests/PBKDF2Tests.swift`

**Interfaces:**
- Produces: `PBKDF2.sha256(password: Data, salt: Data, rounds: Int, length: Int) -> Data`.

- [ ] **Step 1: Failing test (RFC 7914 §11 and the Josefsson vectors)**

Create `Tests/InfinitusCoreTests/PBKDF2Tests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class PBKDF2Tests: XCTestCase {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testRFC7914Vector() {
        // RFC 7914 §11: P="passwd", S="salt", c=1, dkLen=64
        let dk = PBKDF2.sha256(password: Data("passwd".utf8), salt: Data("salt".utf8), rounds: 1, length: 64)
        XCTAssertEqual(hex(dk), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    func testSHA256VectorsAcrossRoundsAndLengths() {
        // draft-josefsson-pbkdf2-test-vectors (SHA-256)
        XCTAssertEqual(hex(PBKDF2.sha256(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 1, length: 32)),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(hex(PBKDF2.sha256(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 4096, length: 32)),
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(hex(PBKDF2.sha256(password: Data("passwordPASSWORDpassword".utf8), salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8), rounds: 4096, length: 40)),
                       "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
    }

    func testLengthNotAMultipleOfTheBlock() {
        XCTAssertEqual(PBKDF2.sha256(password: Data("p".utf8), salt: Data("s".utf8), rounds: 2, length: 33).count, 33)
        XCTAssertEqual(PBKDF2.sha256(password: Data("p".utf8), salt: Data("s".utf8), rounds: 2, length: 33).prefix(32),
                       PBKDF2.sha256(password: Data("p".utf8), salt: Data("s".utf8), rounds: 2, length: 32))
    }
}
```

Run: `cd /Users/deathemperor/death/limitless-t-identity && swift test --filter PBKDF2Tests 2>&1 | tail -3` — expected: compile failure (`PBKDF2` unknown).

- [ ] **Step 2: Implement**

Create `Sources/InfinitusCore/Team/PBKDF2.swift`:

```swift
import Foundation
import Crypto

/// PBKDF2-HMAC-SHA256 (RFC 8018 §5.2) over swift-crypto's HMAC, so the
/// identity export (spec §2.1) derives the same key on macOS, Linux and
/// Windows. Blocks are XORed as byte arrays: 600k rounds × 32 bytes
/// through `Data` subscripts would take seconds.
public enum PBKDF2 {
    public static func sha256(password: Data, salt: Data, rounds: Int, length: Int) -> Data {
        precondition(rounds >= 1 && length >= 1)
        let key = SymmetricKey(data: password)
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var block: UInt32 = 1
        while out.count < length {
            var u = [UInt8](HMAC<Crypto.SHA256>.authenticationCode(for: salt + block.bigEndianBytes, using: key))
            var t = u
            for _ in 1..<rounds {
                u = [UInt8](HMAC<Crypto.SHA256>.authenticationCode(for: u, using: key))
                for i in 0..<t.count { t[i] ^= u[i] }
            }
            out += t
            block += 1
        }
        return Data(out.prefix(length))
    }
}

private extension UInt32 {
    var bigEndianBytes: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
```

- [ ] **Step 3: Run**

Run: `swift test --filter PBKDF2Tests 2>&1 | tail -3` — expected: 3 tests pass (the 4096-round vectors take well under a second in debug).

- [ ] **Step 4: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-identity && git add Sources/InfinitusCore/Team/PBKDF2.swift Tests/InfinitusCoreTests/PBKDF2Tests.swift && \
git commit -m "team: PBKDF2-HMAC-SHA256 over swift-crypto (RFC 7914 / Josefsson vectors)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The sealed export and the recovery key

**Files:**
- Create: `Sources/InfinitusCore/Team/TeamIdentityExport.swift`, `Sources/InfinitusCore/Team/RecoveryKey.swift`
- Modify: `Sources/InfinitusCore/Team/Base32.swift` (`decode`)
- Test: `Tests/InfinitusCoreTests/TeamIdentityExportTests.swift`, `Tests/InfinitusCoreTests/RecoveryKeyTests.swift`

**Interfaces:**
- Consumes: `PBKDF2.sha256`, `ChaChaPoly`, `CanonicalJSON`, `Base32.encode`, `TeamIdentity(secret:)`.
- Produces: `TeamIdentityExport.File`, `TeamIdentityExport.defaultRounds = 600_000`, `TeamIdentityExport.export(secret:passphrase:rounds:) throws -> Data`, `TeamIdentityExport.import(_:passphrase:) throws -> Data`, `TeamIdentityExport.ExportError`, `RecoveryKey.encode(_:) -> String`, `RecoveryKey.decode(_:) -> Data?`, `Base32.decode(_:) -> Data?`.

- [ ] **Step 1: Failing tests**

Create `Tests/InfinitusCoreTests/RecoveryKeyTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class RecoveryKeyTests: XCTestCase {
    func testBase32DecodeInvertsEncode() {
        for s in ["", "f", "fo", "foo", "foob", "fooba", "foobar"] {
            XCTAssertEqual(Base32.decode(Base32.encode(Data(s.utf8))), Data(s.utf8), s)
        }
        XCTAssertEqual(Base32.decode("MZXW6"), Data("foo".utf8), "case-insensitive")
        XCTAssertNil(Base32.decode("mzxw6!"), "bad alphabet")
        XCTAssertNil(Base32.decode("m"), "a lone char carries no whole byte")
    }

    func testRecoveryKeyIsEightGroupsAndRoundTrips() throws {
        let secret = Data((0..<32).map { UInt8($0 &* 7) })
        let key = RecoveryKey.encode(secret)
        let groups = key.split(separator: "-")
        XCTAssertEqual(groups.count, 8)
        XCTAssertEqual(groups.map(\.count), [7, 7, 7, 7, 6, 6, 6, 6])
        XCTAssertEqual(key.count, 52 + 7)
        XCTAssertEqual(RecoveryKey.decode(key), secret)
        XCTAssertEqual(RecoveryKey.decode(key.uppercased().replacingOccurrences(of: "-", with: " ")), secret, "dashes/spaces/case are cosmetic")
        XCTAssertNil(RecoveryKey.decode(String(key.dropLast(2))), "wrong length")
        XCTAssertNil(RecoveryKey.decode("not a key"))
        let identity = try TeamIdentity(secret: secret)
        XCTAssertEqual(try TeamIdentity(secret: RecoveryKey.decode(key)!).kid, identity.kid)
    }
}
```

Create `Tests/InfinitusCoreTests/TeamIdentityExportTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class TeamIdentityExportTests: XCTestCase {
    let secret = Data((0..<32).map { UInt8($0) })

    func testRoundTripAndWrongPassphrase() throws {
        let file = try TeamIdentityExport.export(secret: secret, passphrase: "correct horse", rounds: 1_000)
        XCTAssertEqual(try TeamIdentityExport.import(file, passphrase: "correct horse"), secret)
        XCTAssertThrowsError(try TeamIdentityExport.import(file, passphrase: "wrong")) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .badPassphrase)
        }
        let decoded = try JSONDecoder().decode(TeamIdentityExport.File.self, from: file)
        XCTAssertEqual(decoded.v, 1); XCTAssertEqual(decoded.kdf, "pbkdf2-hmac-sha256"); XCTAssertEqual(decoded.rounds, 1_000)
        XCTAssertEqual(Data(base64Encoded: decoded.salt)?.count, 16)
        XCTAssertEqual(Data(base64Encoded: decoded.nonce)?.count, 12)
        XCTAssertEqual(TeamIdentityExport.defaultRounds, 600_000)
    }

    func testTwoExportsDiffer() throws {
        XCTAssertNotEqual(try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000),
                          try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000), "fresh salt and nonce")
    }

    func testHeaderIsAuthenticated() throws {
        let file = try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000)
        var doc = try JSONDecoder().decode(TeamIdentityExport.File.self, from: file)
        doc.rounds = 999   // an attacker lowering the work factor
        let tampered = try JSONEncoder().encode(doc)
        XCTAssertThrowsError(try TeamIdentityExport.import(tampered, passphrase: "p"))
    }

    func testRejectsMalformedAndAbsurdRounds() throws {
        XCTAssertThrowsError(try TeamIdentityExport.import(Data("{}".utf8), passphrase: "p")) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .malformed)
        }
        var doc = try JSONDecoder().decode(TeamIdentityExport.File.self, from: try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000))
        doc.rounds = 50_000_000
        XCTAssertThrowsError(try TeamIdentityExport.import(try JSONEncoder().encode(doc), passphrase: "p")) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .malformed)
        }
        XCTAssertThrowsError(try TeamIdentityExport.export(secret: Data([1, 2]), passphrase: "p", rounds: 1_000)) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .badSecret)
        }
    }
}
```

Run: `swift test --filter 'RecoveryKeyTests|TeamIdentityExportTests' 2>&1 | tail -3` — expected: compile failure.

- [ ] **Step 2: `Base32.decode`**

In `Sources/InfinitusCore/Team/Base32.swift`, add to the enum (read the existing `encode` first and use the same alphabet constant):

```swift
    /// RFC 4648 base32, case-insensitive, no padding (the inverse of
    /// `encode`). nil on a character outside the alphabet or a length
    /// that carries no whole byte (1, 3 or 6 chars mod 8).
    public static func decode(_ text: String) -> Data? {
        let lower = text.lowercased()
        guard ![1, 3, 6].contains(lower.count % 8) else { return nil }
        var out = Data(), buffer: UInt32 = 0, bits = 0
        for ch in lower {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(alphabet.distance(from: alphabet.startIndex, to: idx))
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return out
    }
```

(`alphabet` is whatever `encode` uses — `"abcdefghijklmnopqrstuvwxyz234567"`; if it is a `[Character]` or `Array`, adapt the index lookup; a `[Character: UInt32]` map built once is fine.)

- [ ] **Step 3: `RecoveryKey`**

Create `Sources/InfinitusCore/Team/RecoveryKey.swift`:

```swift
import Foundation

/// Spec §2.1 local path: the 32-byte identity secret as base32 in 8
/// dashed groups (52 chars → 7,7,7,7,6,6,6,6), shown once with "keep
/// this offline" and re-showable after unlock. Typing it back yields the
/// same identity (same kid) on any machine.
public enum RecoveryKey {
    static let groups = [7, 7, 7, 7, 6, 6, 6, 6]

    public static func encode(_ secret: Data) -> String {
        precondition(secret.count == 32)
        var rest = Substring(Base32.encode(secret))
        var out: [String] = []
        for n in groups {
            out.append(String(rest.prefix(n)))
            rest = rest.dropFirst(n)
        }
        return out.joined(separator: "-")
    }

    /// Dashes, spaces and case are cosmetic. nil unless exactly 32 bytes come back.
    public static func decode(_ text: String) -> Data? {
        let compact = text.filter { !$0.isWhitespace && $0 != "-" }
        guard compact.count == 52, let data = Base32.decode(compact), data.count == 32 else { return nil }
        return data
    }
}
```

- [ ] **Step 4: `TeamIdentityExport`**

Create `Sources/InfinitusCore/Team/TeamIdentityExport.swift`:

```swift
import Foundation
import Crypto

/// Spec §2.1: the identity secret sealed with a passphrase — PBKDF2-HMAC-
/// SHA256 (600k rounds by default) → ChaChaPoly, the header (version,
/// kdf, rounds, salt, nonce) authenticated as associated data so no field
/// can be lowered or swapped. Same bytes on every platform.
public enum TeamIdentityExport {
    public struct File: Codable, Equatable, Sendable {
        public var v: Int
        public var kdf: String
        public var rounds: Int
        /// base64, 16 bytes
        public var salt: String
        /// base64, 12 bytes
        public var nonce: String
        /// base64, ciphertext ‖ tag (empty while the header is authenticated)
        public var box: String
    }

    public enum ExportError: Error, Equatable { case badSecret, badPassphrase, malformed }

    public static let defaultRounds = 600_000
    public static let kdf = "pbkdf2-hmac-sha256"
    static let minRounds = 1_000
    static let maxRounds = 10_000_000

    public static func export(secret: Data, passphrase: String, rounds: Int = defaultRounds) throws -> Data {
        guard secret.count == 32 else { throw ExportError.badSecret }
        guard (minRounds...maxRounds).contains(rounds) else { throw ExportError.malformed }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let nonce = ChaChaPoly.Nonce()
        var file = File(v: 1, kdf: kdf, rounds: rounds, salt: salt.base64EncodedString(),
                        nonce: Data(nonce).base64EncodedString(), box: "")
        let key = SymmetricKey(data: PBKDF2.sha256(password: Data(passphrase.utf8), salt: salt, rounds: rounds, length: 32))
        let sealed = try ChaChaPoly.seal(secret, using: key, nonce: nonce, authenticating: try CanonicalJSON.encode(file))
        file.box = (sealed.ciphertext + sealed.tag).base64EncodedString()
        return try CanonicalJSON.encode(file)
    }

    public static func `import`(_ data: Data, passphrase: String) throws -> Data {
        guard var file = try? CanonicalJSON.decode(File.self, from: data), file.v == 1, file.kdf == kdf,
              (minRounds...maxRounds).contains(file.rounds),
              let salt = Data(base64Encoded: file.salt), salt.count == 16,
              let nonceData = Data(base64Encoded: file.nonce), nonceData.count == 12,
              let box = Data(base64Encoded: file.box), box.count == 32 + 16 else { throw ExportError.malformed }
        file.box = ""
        let key = SymmetricKey(data: PBKDF2.sha256(password: Data(passphrase.utf8), salt: salt, rounds: file.rounds, length: 32))
        let sealed = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceData), ciphertext: box.prefix(32), tag: box.suffix(16))
        do {
            return try ChaChaPoly.open(sealed, using: key, authenticating: try CanonicalJSON.encode(file))
        } catch {
            throw ExportError.badPassphrase
        }
    }
}
```

`testHeaderIsAuthenticated` re-encodes with `JSONEncoder` (unsorted keys): `import` decodes and re-canonicalises before the AAD check, so the tamper (rounds 999) fails on `minRounds` — that is `.malformed`, still a throw; keep the test's `XCTAssertThrowsError` without an equality on the case.

- [ ] **Step 5: Run**

Run: `swift test --filter 'RecoveryKeyTests|TeamIdentityExportTests|TeamIdentityTests' 2>&1 | tail -3` — expected: pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-identity && git add Sources/InfinitusCore/Team/TeamIdentityExport.swift Sources/InfinitusCore/Team/RecoveryKey.swift Sources/InfinitusCore/Team/Base32.swift Tests/InfinitusCoreTests/TeamIdentityExportTests.swift Tests/InfinitusCoreTests/RecoveryKeyTests.swift && \
git commit -m "team: passphrase-sealed identity export/import (PBKDF2 600k + ChaChaPoly, authenticated header) and the 8-group recovery key

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `infinitusctl team identity show|recovery|export|import`

**Files:**
- Modify: `Sources/InfinitusCLI/TeamCommand.swift` (one `case "identity":` directly BEFORE `case "publish":`; the gate list; the usage text)

**Interfaces:**
- Consumes: `TeamClient.identity(paths:secrets:)`, `TeamClient.identitySecretName`, `FileSecrets`, `TeamIdentityExport`, `RecoveryKey`, `TeamGate`.
- Produces: `team identity` → `{kid}`; `team identity recovery --show` → `{kid, recoveryKey}`; `team identity export [--out <file>]` (passphrase = first stdin line, ≥ 8 chars) → writes the file 0600 and prints `{kid, out}`, or prints the JSON when no `--out`; `team identity import <file>|--recovery [--replace]` (passphrase or key from stdin) → `{kid}`.

- [ ] **Step 1: The gate**

`recovery` and `export` reveal the secret: extend the gated list so that `sub == "identity" && ["recovery", "export"].contains(positional.first ?? "")` also requires the lock (same `TeamGate.check` line; keep `create/request/approve` as they are).

- [ ] **Step 2: The case**

Directly before `case "publish":` insert:

```swift
        case "identity":
            // Spec §2.1: the local identity's kid, its recovery key, and a
            // passphrase-sealed export/import. Passphrases and keys come on
            // stdin (never argv); the secret is printed only as the
            // recovery key, on an explicit --show.
            let what = positional.first ?? "show"
            func stdinLine() -> String {
                String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            switch what {
            case "show":
                emit(["kid": try TeamClient.identity(paths: paths, secrets: secrets).kid])
            case "recovery":
                guard flags.contains("show") else { return fail("team identity recovery --show prints the key: keep it offline", code: 2) }
                let me = try TeamClient.identity(paths: paths, secrets: secrets)
                emit(["kid": me.kid, "recoveryKey": RecoveryKey.encode(me.secret)])
            case "export":
                let passphrase = stdinLine()
                guard passphrase.count >= 8 else { return fail("passphrase on stdin, at least 8 characters", code: 2) }
                let me = try TeamClient.identity(paths: paths, secrets: secrets)
                let file = try TeamIdentityExport.export(secret: me.secret, passphrase: passphrase)
                if let out = options["out"] {
                    let url = URL(fileURLWithPath: out)
                    try file.write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    emit(["kid": me.kid, "out": url.path])
                } else {
                    print(String(decoding: file, as: UTF8.self))
                }
            case "import":
                if secrets.read(TeamClient.identitySecretName) != nil, !flags.contains("replace") {
                    return fail("an identity exists; pass --replace to overwrite it (teams that approved the old kid must re-approve)", code: 2)
                }
                let secret: Data
                if flags.contains("recovery") {
                    guard let s = RecoveryKey.decode(stdinLine()) else { return fail("that is not a recovery key", code: 2) }
                    secret = s
                } else {
                    guard positional.count >= 2 else { return fail(teamUsage(), code: 2) }
                    let file = try Data(contentsOf: URL(fileURLWithPath: positional[1]))
                    secret = try TeamIdentityExport.import(file, passphrase: stdinLine())
                }
                try secrets.write(TeamClient.identitySecretName, secret)
                emit(["kid": try TeamIdentity(secret: secret).kid])
            default:
                return fail(teamUsage(), code: 2)
            }
```

`flags` is the existing parsed set of `--x` switches without values (the `exclude --off` code uses it); if the parser treats `--show`/`--replace`/`--recovery` as options with values, use `options["show"] != nil` etc. consistently. `positional.first` for `identity` is the verb, so `positional[1]` is the file.

Add to `teamUsage()`:

```
  identity [show]                    this machine's identity kid
  identity recovery --show           the recovery key (base32, 8 groups) — keep it offline
  identity export [--out <file>]     passphrase on stdin (≥ 8 chars); the sealed file to --out (0600) or stdout
  identity import <file> | --recovery [--replace]   passphrase or recovery key on stdin
```

- [ ] **Step 3: Smoke it against a temp dir**

Run (macOS; the gate is opened for the smoke):

```bash
cd /Users/deathemperor/death/limitless-t-identity && swift build --product infinitusctl 2>&1 | tail -1 && \
T=$(mktemp -d) && export INFINITUS_TEAM_DIR="$T" INFINITUS_LOCK_GATE=open && CTL=.build/debug/infinitusctl && \
K1=$($CTL team identity | python3 -c 'import json,sys; print(json.load(sys.stdin)["kid"])') && \
printf 'correct horse battery\n' | $CTL team identity export --out "$T/id.json" >/dev/null && stat -f %Lp "$T/id.json" && \
RK=$($CTL team identity recovery --show | python3 -c 'import json,sys; print(json.load(sys.stdin)["recoveryKey"])') && \
rm -rf "$T/secrets" && printf 'correct horse battery\n' | $CTL team identity import "$T/id.json" | grep -q "$K1" && echo "import: same kid" && \
rm -rf "$T/secrets" && printf '%s\n' "$RK" | $CTL team identity import --recovery | grep -q "$K1" && echo "recovery: same kid" && \
printf 'wrong\n' | $CTL team identity import "$T/id.json" --replace; echo "exit=$? (expected non-zero)"; rm -rf "$T"
```

Expected: `600`, `import: same kid`, `recovery: same kid`, non-zero exit on the wrong passphrase. (The 600k-round export takes ~1–3 s in a debug build.)

- [ ] **Step 4: Full test run and commit**

Run: `swift test 2>&1 | grep -E "Executed|error:" | tail -2`

```bash
cd /Users/deathemperor/death/limitless-t-identity && git add Sources/InfinitusCLI/TeamCommand.swift && \
git commit -m "cli: team identity show|recovery|export|import — passphrase and recovery key on stdin, the export written 0600

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: AASA on the site, the entitlement, and the gated signing step

**Files:**
- Create: `site/public/.well-known/apple-app-site-association`
- Modify: `site/public/_headers`
- Create: `Infinitus.entitlements`
- Modify: `make-app.sh` (the codesign block only)

**Interfaces:**
- Produces: `https://infinitus.run/.well-known/apple-app-site-association` (JSON, `webcredentials` for `Q783W6B4FA.run.infinitus` and `Q783W6B4FA.run.infinitus.mobile`); `PROVISIONING_PROFILE=<path>` in `make-app.sh`'s environment embeds the profile and signs with the entitlements.

- [ ] **Step 1: The site file**

Create `site/public/.well-known/apple-app-site-association` (no extension, exactly this content):

```json
{
  "webcredentials": {
    "apps": ["Q783W6B4FA.run.infinitus", "Q783W6B4FA.run.infinitus.mobile"]
  }
}
```

Append to `site/public/_headers`:

```
/.well-known/apple-app-site-association
  Content-Type: application/json
```

Check: `python3 -m json.tool site/public/.well-known/apple-app-site-association >/dev/null && echo "aasa ok"`. (Cloudflare serves `public/` as static assets — no worker route needed; `robots.txt` and `sitemap.xml` stay as they are.)

- [ ] **Step 2: The entitlements file**

Create `Infinitus.entitlements` at the repo root:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Passkey identity (spec §2.1): relying party infinitus.run. Applied
         by make-app.sh only when a provisioning profile is supplied. -->
    <key>com.apple.developer.associated-domains</key>
    <array><string>webcredentials:infinitus.run</string></array>
</dict>
</plist>
```

Check: `plutil -lint Infinitus.entitlements`.

- [ ] **Step 3: `make-app.sh`**

Directly before the `case "$IDENTITY" in` line insert:

```sh
# Passkeys (spec §2.1) need the associated-domains entitlement, which only
# a provisioning profile can carry: PROVISIONING_PROFILE=<path to a
# .provisionprofile for run.infinitus> embeds it and signs the bundle with
# Infinitus.entitlements. Without it (the dev loop, CI) nothing changes —
# a dev-signed build has no passkey path, and the local identity is the
# default anyway.
ENTITLEMENTS=""
if [ -n "${PROVISIONING_PROFILE:-}" ]; then
    [ -f "$PROVISIONING_PROFILE" ] || { echo "PROVISIONING_PROFILE not found: $PROVISIONING_PROFILE"; exit 2; }
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS="--entitlements Infinitus.entitlements"
fi
```

Then add ` $ENTITLEMENTS` (unquoted, so an empty value expands to nothing) to the two codesign lines that sign `"$APP"` (the Developer ID one and the fallback one) — NOT the `infinitusctl` lines.

Check: `sh -n make-app.sh && grep -c 'ENTITLEMENTS' make-app.sh` (expect 4+). Do not run `make-app.sh` here.

- [ ] **Step 4: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-identity && git add site/public/.well-known/apple-app-site-association site/public/_headers Infinitus.entitlements make-app.sh && \
git commit -m "site + packaging: apple-app-site-association for infinitus.run; make-app.sh signs with the associated-domains entitlement when PROVISIONING_PROFILE is given

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `PasskeyIdentity` — the PRF scaffold

**Files:**
- Create: `Sources/Infinitus/PasskeyIdentity.swift`

**Interfaces:**
- Produces: `PasskeyIdentity.isEntitled: Bool`, `PasskeyIdentity.relyingParty = "infinitus.run"`, `PasskeyIdentity.salt`, `func deriveSecret(register: Bool) async throws -> Data` (32 bytes), `PasskeyIdentity.PasskeyError`. Called by nothing this round.

- [ ] **Step 1: Confirm the spellings**

Run: `grep -nE "prf|PRF|saltInput1|checkForSupport" "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/AuthenticationServices.framework/Modules/AuthenticationServices.swiftmodule/arm64e-apple-macos.swiftinterface" | head -40`

Known from that file: `ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest.prf: ASAuthorizationPublicKeyCredentialPRFRegistrationInput?` with `.inputValues(.saltInput1(_:saltInput2:))`; the assertion request's `prf: ASAuthorizationPublicKeyCredentialPRFAssertionInput?` with `.inputValues(.saltInput1(_:), perCredentialInputValues: nil)`; `ASAuthorizationPlatformPublicKeyCredentialAssertion.prf?.first: SymmetricKey`; the registration credential's `prf?.first: SymmetricKey?` and `isSupported`.

- [ ] **Step 2: The file**

Create `Sources/Infinitus/PasskeyIdentity.swift`:

```swift
import Foundation
import AppKit
import CryptoKit
#if canImport(AuthenticationServices)
import AuthenticationServices

/// Spec §2.1 passkey path: the identity secret is the PRF output of a
/// passkey for relying party `infinitus.run` under a fixed salt — nobody
/// verifies an assertion; the passkey is a synced secret-derivation
/// device, so the same passkey on the phone or a replacement Mac yields
/// the same identity. Runtime-optional: the associated-domains
/// entitlement rides a provisioning profile (make-app.sh), so
/// `isEntitled` is false in dev-signed builds and the local identity
/// stays the default. Nothing calls this yet — TeamModel wires it in
/// the next round (an "Use a passkey" choice when the identity is made,
/// and the once-per-launch unlock that fills the working-key cache).
@available(macOS 15, *)
@MainActor
final class PasskeyIdentity: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let relyingParty = "infinitus.run"
    static let salt = Data("infinitus-team-identity-v1".utf8)
    static let userName = "Infinitus identity"

    enum PasskeyError: Error { case notEntitled, unsupported, cancelled, noOutput }

    /// The signed bundle carries `com.apple.developer.associated-domains`.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.associated-domains" as CFString, nil) else { return false }
        return (value as? [String])?.contains("webcredentials:\(relyingParty)") ?? false
    }

    private var continuation: CheckedContinuation<Data, Error>?

    /// `register: true` creates the passkey (first time on this Apple
    /// account), `false` asserts the existing one; both return the
    /// 32-byte PRF output for `salt`.
    func deriveSecret(register: Bool) async throws -> Data {
        guard Self.isEntitled else { throw PasskeyError.notEntitled }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        var challenge = Data(count: 32)
        _ = challenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let request: ASAuthorizationRequest
        if register {
            let r = provider.createCredentialRegistrationRequest(challenge: challenge, name: Self.userName, userID: Data(Self.userName.utf8))
            r.prf = .inputValues(.saltInput1(Self.salt))
            request = r
        } else {
            let r = provider.createCredentialAssertionRequest(challenge: challenge)
            r.prf = .inputValues(.saltInput1(Self.salt), perCredentialInputValues: nil)
            request = r
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let key: SymmetricKey?
        if let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            key = registration.prf?.first
        } else if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            key = assertion.prf?.first
        } else {
            key = nil
        }
        guard let key else { continuation?.resume(throwing: PasskeyError.noOutput); continuation = nil; return }
        continuation?.resume(returning: key.withUnsafeBytes { Data($0) })
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let asError = error as? ASAuthorizationError
        continuation?.resume(throwing: asError?.code == .canceled ? PasskeyError.cancelled : error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
#endif
```

Adjust member names only where the interface file disagrees (e.g. if the registration credential's PRF output is reached differently); keep the contract above. `Security` is imported transitively via AppKit — add `import Security` if `SecTaskCreateFromSelf` is unresolved.

- [ ] **Step 3: Build**

Run: `cd /Users/deathemperor/death/limitless-t-identity && swift build --product Infinitus 2>&1 | grep -E "error|Build complete" | tail -5`
Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
cd /Users/deathemperor/death/limitless-t-identity && git add Sources/Infinitus/PasskeyIdentity.swift && \
git commit -m "app: PasskeyIdentity scaffold — PRF-derived identity secret for infinitus.run, inert without the associated-domains entitlement

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Release lines

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: The lines**

Under `## 0.4.4 (unreleased)`, directly before `## 0.4.3` (create `### Team (preview)` there if the other streams have not), add:

```markdown
- `infinitusctl team identity export|import` seals your identity with a passphrase (PBKDF2 600k + ChaChaPoly, the same file on every platform), `identity recovery --show` prints the 8-group recovery key, and either restores the same kid on a new machine.
- The site serves the passkey relying-party file for infinitus.run, and a release built with a provisioning profile carries the associated-domains entitlement the passkey identity needs.
```

- [ ] **Step 2: Full suite and commit**

Run: `swift test 2>&1 | grep -E "Executed|error:" | tail -2`

```bash
cd /Users/deathemperor/death/limitless-t-identity && git add CHANGELOG.md && \
git commit -m "changelog: identity export/import + recovery key; AASA + entitlement

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage.** §2.1 export (PBKDF2-HMAC-SHA256 600k over swift-crypto + ChaChaPoly): T1–T3. Recovery key (base32, 8 groups, re-showable): T2–T3 (the pane's "shown once" moment is the pane stream's follow-up, logged on #55). AASA + `webcredentials:infinitus.run` entitlement via provisioning profile: T4. Passkey PRF with the fixed salt `infinitus-team-identity-v1`: T5 scaffold (unverifiable without a signed build — manual test by Infinitus later; the local path stays default per §2.1/§12). Working-key cache and "deleting the passkey deletes the identity" copy: next round with the pane wiring. Windows Hello: phase 3 by the spec.
- **Placeholders.** None; T5's "adjust names where the interface disagrees" is bounded by the spellings listed from the SDK interface.
- **Type consistency.** `PBKDF2.sha256(password:salt:rounds:length:)` used identically in T1 tests, T2; `TeamIdentityExport.export(secret:passphrase:rounds:)` / `import(_:passphrase:)` in T2 tests and T3; `RecoveryKey.encode/decode` in T2 tests and T3; `Base32.decode` returns `Data?`.
