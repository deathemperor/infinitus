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
