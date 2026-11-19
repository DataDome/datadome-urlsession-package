import Foundation

/// Canned responses for one test, served by `StubURLProtocol` to requests sent to `baseURL`.
///
/// Each server gets its own host, so tests running in parallel never share responses.
final class StubServer: @unchecked Sendable {
    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var redirectLocation: URL?

        static func ok(_ body: String) -> Response {
            Response(body: Data(body.utf8))
        }

        static func redirect(to location: URL, statusCode: Int = 302) -> Response {
            Response(statusCode: statusCode, headers: ["Location": location.absoluteString], redirectLocation: location)
        }

        static let challenge = Response(statusCode: 403,
                                        headers: ["x-dd-b": "1", "Content-Type": "application/json"],
                                        body: Data(#"{"url":"https://geo.captcha-delivery.com/captcha/"}"#.utf8))
    }

    let baseURL: URL

    // State is guarded by `lock`.
    private let lock = NSLock()
    private var pending: [Response]
    private var received: [URLRequest] = []

    init(_ responses: [Response]) {
        self.baseURL = URL(string: "https://\(UUID().uuidString.lowercased()).stub.test/resource")!
        self.pending = responses
        StubURLProtocol.register(self)
    }

    /// The requests the server received, in order. Their body, if any, is in `httpBody`.
    var requests: [URLRequest] {
        lock.withLock { received }
    }

    fileprivate func respond(to request: URLRequest) -> Response? {
        lock.withLock {
            received.append(request)
            return pending.isEmpty ? nil : pending.removeFirst()
        }
    }

    /// A session whose requests are all served by stub servers.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer) {
        lock.withLock { servers[server.baseURL.host!] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let server = Self.lock.withLock { request.url?.host.flatMap { Self.servers[$0] } }
        // URLSession hands a protocol the body as a stream.
        var received = request
        received.httpBody = request.bodyData
        guard let url = received.url, let stub = server?.respond(to: received) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        if let location = stub.redirectLocation {
            var redirected = received
            redirected.url = location
            // URLSession follows a protocol's redirect as is; apply its rules: 303, and 301 or 302 after a POST,
            // are followed with a GET without body.
            if (stub.statusCode == 303 && received.httpMethod != "HEAD")
                || ([301, 302].contains(stub.statusCode) && received.httpMethod == "POST") {
                redirected.httpMethod = "GET"
                redirected.httpBody = nil
            }
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // Followed, the redirect stops this load; refused, the task completes with the redirect response.
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            data.append(buffer, count: count)
        }
        return data
    }
}
