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
