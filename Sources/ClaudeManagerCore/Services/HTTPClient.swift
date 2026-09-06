import Foundation

/// A minimal HTTP response — status, body, and headers.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// Case-insensitive header lookup — scans keys rather than assuming a lower-cased map, so a
    /// value holds regardless of the producer's casing (e.g. a mock injecting `Retry-After`).
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Just enough HTTP for the OAuth usage/profile calls. Behind a protocol so the client is
/// tested against canned responses — the first (and only) networking in the core.
public protocol HTTPClient: Sendable {
    /// A GET that throws only on transport failure (offline, timeout, DNS); any HTTP status
    /// — including 4xx/5xx — comes back as a normal `HTTPResponse` for the caller to map.
    func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse
}

/// The real client, backed by `URLSession.shared`. Holds no state (timeouts are per-request),
/// so it stays trivially `Sendable`; tests inject a mock `HTTPClient` instead of a session.
public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // Never from a cache. Both callers ask questions whose whole value is freshness — which
        // build is current, what an account's limits are right now — and the update feed's is
        // load-bearing at the moment of a press: a cached response would answer the pre-install
        // re-check with the payload that offered the build being installed, `supersedes` would
        // say false, and the superseded build would go in anyway, indistinguishable in the log
        // from a genuine "still the newest".
        //
        // Two halves, because they reach different caches. The policy governs this process's own
        // `URLCache` and nothing else; a shared or intercepting proxy answers from its own store
        // whatever this process thinks, and only the header asks it to revalidate. Set before the
        // caller's headers so an explicit one still wins.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let stringValue = value as? String {
                headerMap[name.lowercased()] = stringValue
            }
        }
        return HTTPResponse(status: http.statusCode, body: data, headers: headerMap)
    }
}
