import Foundation
import Network

enum InfinitusLoopbackError: LocalizedError {
  case port(UInt16)

  var errorDescription: String? {
    switch self {
    case .port(let port): return "Could not listen on 127.0.0.1:\(port)."
    }
  }
}

/// A one-shot HTTP listener on this phone's loopback address, for the port a CLI's
/// OAuth client redirects to. The gcloud and AWS sign-ins run desktop clients: the
/// only redirect URIs Google and AWS accept for them are `http://localhost:<port>`
/// and `http://127.0.0.1:<port>`, and the CLI bakes the same one into the token
/// exchange, so the redirect can never be pointed at the Mac. What can move is the
/// listener — the phone answers the redirect itself and hands the request's URL
/// back verbatim for the Mac to replay against the CLI's own listener.
///
/// Both loopback stacks are bound: gcloud's redirect URI spells `localhost`, which
/// resolves to ::1 first. Nothing beyond loopback ever is — a port visible on the
/// Wi-Fi would let anyone there hand the Mac an authorization code of their own.
///
/// Every mutable property is touched on `queue` alone (the listeners, their
/// connections and their handlers all run there), which is what makes the
/// unchecked conformance safe.
final class InfinitusLoopbackListener: @unchecked Sendable {
  private struct Request {
    let target: String
    let host: String?
  }

  private let queue = DispatchQueue(label: "run.infinitus.loopback-catch")
  private let port: UInt16
  private let onCatch: @Sendable (String) -> Void
  private var listeners: [NWListener] = []
  private var unbound = 0
  private var settled = false
  private var caught = false

  init(port: UInt16, onCatch: @escaping @Sendable (String) -> Void) {
    self.port = port
    self.onCatch = onCatch
  }

  /// Binds the port; `completion` runs on the main queue once one of the two
  /// addresses is listening, or with a failure when neither is — the caller must
  /// not open the sign-in page before it has answered.
  func start(completion: @escaping @Sendable (Error?) -> Void) {
    // Explicitly strong for the length of this block; the handlers it installs
    // outlive it and are weak, since a listener holds on to them and this object
    // holds the listeners.
    queue.async { [self] in
      guard let endpointPort = NWEndpoint.Port(rawValue: self.port) else {
        self.settle(InfinitusLoopbackError.port(self.port), completion)
        return
      }
      let hosts: [NWEndpoint.Host] = [.ipv4(.loopback), .ipv6(.loopback)]
      let made = hosts.compactMap { host -> NWListener? in
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: endpointPort)
        return try? NWListener(using: parameters)
      }
      guard !made.isEmpty else {
        self.settle(InfinitusLoopbackError.port(self.port), completion)
        return
      }
      self.listeners = made
      self.unbound = made.count
      for listener in made {
        listener.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .ready:
            self.settle(nil, completion)
          case .failed(let error):
            self.unbound -= 1
            if self.unbound == 0 { self.settle(error, completion) }
          default:
            break
          }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: self.queue)
      }
    }
  }

  /// Gives the port back. Safe to call twice, and after a catch.
  func cancel() {
    queue.async {
      for listener in self.listeners { listener.cancel() }
      self.listeners = []
    }
  }

  private func settle(_ error: Error?, _ completion: @escaping @Sendable (Error?) -> Void) {
    guard !settled else { return }
    settled = true
    DispatchQueue.main.async { completion(error) }
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(connection, head: Data())
  }

  private func receive(_ connection: NWConnection, head: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var buffer = head
      if let data { buffer.append(data) }
      if let request = Self.parse(buffer) {
        self.answer(connection, request)
        return
      }
      // A request head this long is not a browser following a redirect.
      guard error == nil, !isComplete, buffer.count < 64 * 1024 else {
        connection.cancel()
        return
      }
      self.receive(connection, head: buffer)
    }
  }

  /// The request line's target and the `Host` header, once the whole head is in.
  private static func parse(_ buffer: Data) -> Request? {
    guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
      let text = String(data: buffer[..<end.lowerBound], encoding: .utf8)
    else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    let fields = lines.first?.split(separator: " ") ?? []
    guard fields.count >= 2 else { return nil }
    let host = lines.dropFirst()
      .first { $0.lowercased().hasPrefix("host:") }
      .map { $0.dropFirst("host:".count).trimmingCharacters(in: .whitespaces) }
    return Request(target: String(fields[1]), host: host)
  }

  private func answer(_ connection: NWConnection, _ request: Request) {
    // The callback always carries a query (the code); a favicon fetch never does.
    guard !caught, request.target.contains("?") else {
      send(connection, status: "404 Not Found", body: Self.missPage)
      return
    }
    caught = true
    let url = "http://\(Self.authority(request.host, port: port))\(request.target)"
    send(connection, status: "200 OK", body: Self.donePage)
    let handler = onCatch
    DispatchQueue.main.async { handler(url) }
  }

  /// The authority the URL is rebuilt with. The Mac validates a gcloud callback
  /// against the name `localhost` and an AWS one against `127.0.0.1`, so the
  /// browser's own `Host` has to survive verbatim — but only when it spells this
  /// loopback on this port. Anything else is the caller's word for where it was
  /// going, and the URL travels on to the Mac.
  private static func authority(_ host: String?, port: UInt16) -> String {
    let fallback = "127.0.0.1:\(port)"
    guard let host, host.hasSuffix(":\(port)") else { return fallback }
    let name = String(host.dropLast(":\(port)".count))
    return ["localhost", "127.0.0.1"].contains(name) ? host : fallback
  }

  private func send(_ connection: NWConnection, status: String, body: String) {
    let bytes = Data(body.utf8)
    let lines = [
      "HTTP/1.1 \(status)",
      "Content-Type: text/html; charset=utf-8",
      "Content-Length: \(bytes.count)",
      "Connection: close",
      "",
      "",
    ]
    let head = lines.joined(separator: "\r\n")
    connection.send(
      content: Data(head.utf8) + bytes,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  private static let donePage = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">\
    <title>Signed in</title>\
    <body style="font:-apple-system-body;margin:3rem 1.5rem;text-align:center">\
    <h1 style="font:-apple-system-headline">Signed in</h1>\
    <p>You can close this page — Infinitus is finishing on your Mac.</p>
    """

  private static let missPage = """
    <!doctype html><title>Not found</title><body>Not found.
    """
}
