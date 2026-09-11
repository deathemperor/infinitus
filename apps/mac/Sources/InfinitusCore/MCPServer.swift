import Foundation

/// A minimal MCP server over stdio (#79): JSON-RPC 2.0, one message per
/// line, the `tools` capability only. The tools themselves are supplied
/// by the caller (the CLI wires them to the control socket), so this
/// stays testable without an app.
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let call: @Sendable ([String: JSONValue]) -> Result<String, MCPServer.ToolError>

    public init(name: String, description: String, inputSchema: JSONValue,
                call: @escaping @Sendable ([String: JSONValue]) -> Result<String, MCPServer.ToolError>) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.call = call
    }
}

public struct MCPServer: Sendable {
    public struct ToolError: Error, Sendable { public let message: String; public init(_ m: String) { message = m } }
    public static let protocolVersion = "2025-06-18"
    public static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    public let name: String
    public let version: String
    public let tools: [MCPTool]

    public init(name: String, version: String, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.tools = tools
    }

    /// One request in, one reply out; nil for notifications (no id) and
    /// for lines that are not JSON-RPC at all.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data)),
              case .object(let message) = object else { return nil }
        let id = message["id"]
        guard case .string(let method)? = message["method"] else {
            return id.map { reply(id: $0, error: (-32600, "not a request")) }
        }
        let params: [String: JSONValue]
        if case .object(let p)? = message["params"] { params = p } else { params = [:] }
        guard let id, id != .null else { return nil }   // notification

        switch method {
        case "initialize":
            var requested = Self.protocolVersion
            if case .string(let v)? = params["protocolVersion"], Self.supportedVersions.contains(v) { requested = v }
            return reply(id: id, result: .object([
                "protocolVersion": .string(requested),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(name), "version": .string(version)]),
            ]))
        case "ping":
            return reply(id: id, result: .object([:]))
        case "tools/list":
            return reply(id: id, result: .object(["tools": .array(tools.map { t in
                .object(["name": .string(t.name), "description": .string(t.description),
                         "inputSchema": t.inputSchema])
            })]))
        case "tools/call":
            guard case .string(let toolName)? = params["name"],
                  let tool = tools.first(where: { $0.name == toolName }) else {
                return reply(id: id, error: (-32602, "unknown tool"))
            }
            let arguments: [String: JSONValue]
            if case .object(let a)? = params["arguments"] { arguments = a } else { arguments = [:] }
            switch tool.call(arguments) {
            case .success(let text):
                return reply(id: id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])]))
            case .failure(let error):
                return reply(id: id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string(error.message)])]),
                                                      "isError": .bool(true)]))
            }
        default:
            return reply(id: id, error: (-32601, "method not found: \(method)"))
        }
    }

    /// Reads stdin line by line until EOF, answering on stdout.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        while let line = readLine(strippingNewline: true) {
            guard let answer = handle(line: line) else { continue }
            output.write(Data((answer + "\n").utf8))
        }
    }

    private func reply(id: JSONValue, result: JSONValue) -> String {
        encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func reply(id: JSONValue, error: (Int, String)) -> String {
        encode(.object(["jsonrpc": .string("2.0"), "id": id,
                        "error": .object(["code": .number(Double(error.0)), "message": .string(error.1)])]))
    }

    private func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
