import XCTest
@testable import InfinitusCore

final class MCPServerTests: XCTestCase {
    private let server = MCPServer(name: "infinitus", version: "1", tools: [
        MCPTool(name: "echo", description: "echoes", inputSchema: .object(["type": .string("object")]),
                call: { args in
                    if case .string(let s)? = args["text"] { return .success("echo: \(s)") }
                    return .failure(.init("text missing"))
                }),
    ])

    private func object(_ line: String?) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(line).utf8))
        guard case .object(let o) = value else { XCTFail("not an object"); return [:] }
        return o
    }

    func testInitializeEchoesASupportedVersionAndAdvertisesTools() throws {
        let reply = try object(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        guard case .object(let result)? = reply["result"] else { return XCTFail() }
        XCTAssertEqual(result["protocolVersion"], .string("2025-03-26"))
        XCTAssertEqual(result["capabilities"], .object(["tools": .object([:])]))
        let unknown = try object(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        guard case .object(let r2)? = unknown["result"] else { return XCTFail() }
        XCTAssertEqual(r2["protocolVersion"], .string(MCPServer.protocolVersion))
    }

    func testNotificationsAndGarbageGetNoReply() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handle(line: "not json"))
    }

    func testToolsListAndCall() throws {
        let list = try object(server.handle(line: #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        guard case .object(let result)? = list["result"], case .array(let tools)? = result["tools"] else { return XCTFail() }
        XCTAssertEqual(tools.count, 1)
        let call = try object(server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#))
        XCTAssertEqual(call["result"], .object(["content": .array([.object(["type": .string("text"), "text": .string("echo: hi")])])]))
        let failed = try object(server.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#))
        guard case .object(let r)? = failed["result"] else { return XCTFail() }
        XCTAssertEqual(r["isError"], .bool(true))
        let missing = try object(server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#))
        guard case .object(let err)? = missing["error"] else { return XCTFail() }
        XCTAssertEqual(err["code"], .number(-32602))
    }

    func testUnknownMethodIsAnError() throws {
        let reply = try object(server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#))
        guard case .object(let err)? = reply["error"] else { return XCTFail() }
        XCTAssertEqual(err["code"], .number(-32601))
    }
}
