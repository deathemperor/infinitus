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
