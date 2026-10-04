import Foundation

/// Scripts HTTP responses for the SDK's foreground session, so the upload, token-refresh
/// and cancellation paths can be driven without a server.
///
/// Register it on a session configuration's `protocolClasses`. `URLSession` converts
/// `httpBody` to a stream before a protocol sees the request, so the recorded `body`
/// is read from that stream (or `httpBody` when a test builds the request itself).
final class StubURLProtocol: URLProtocol {

    struct Reply {
        let status: Int
        let body: Data
        let error: Error?

        static func status(_ code: Int, _ json: String = "{}") -> Reply {
            Reply(status: code, body: Data(json.utf8), error: nil)
        }

        static func failure(_ error: Error) -> Reply {
            Reply(status: 0, body: Data(), error: error)
        }

        /// Never responds, leaving the task in flight until something cancels it.
        static let hang = Reply(status: hangStatus, body: Data(), error: nil)
    }

    private static let hangStatus = -1

    struct Recorded {
        let request: URLRequest
        let body: Data

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    private static var replyProvider: ((URLRequest) -> Reply)?
    private static var seen: [Recorded] = []

    // MARK: - Scripting

    static func install(_ reply: @escaping (URLRequest) -> Reply) {
        lock.lock()
        replyProvider = reply
        seen = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        replyProvider = nil
        seen = []
        lock.unlock()
    }

    static var recorded: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static var requests: [URLRequest] {
        recorded.map(\.request)
    }

    static func requests(matching pathFragment: String) -> [URLRequest] {
        requests.filter { $0.url?.path.contains(pathFragment) == true }
    }

    static func recorded(matching pathFragment: String) -> [Recorded] {
        recorded.filter { $0.request.url?.path.contains(pathFragment) == true }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // The provider is read under the lock but called outside it, so a test closure
        // is free to inspect `requests` without deadlocking.
        let body = Self.readBody(from: request)
        StubURLProtocol.lock.lock()
        StubURLProtocol.seen.append(Recorded(request: request, body: body))
        let provider = StubURLProtocol.replyProvider
        StubURLProtocol.lock.unlock()

        guard let reply = provider?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        if reply.status == StubURLProtocol.hangStatus { return }

        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` turns `httpBody` into a stream before the protocol sees the request.
    private static func readBody(from request: URLRequest) -> Data {
        if let httpBody = request.httpBody { return httpBody }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
