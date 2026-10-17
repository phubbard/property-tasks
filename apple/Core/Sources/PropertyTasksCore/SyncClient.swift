import Foundation

/// The Worker's JSON API (DESIGN.md §11). Ephemeral session, one host, no
/// third-party calls, as in Serpentine. Authentication is a bearer token
/// once real sessions exist; today the dev stub accepts `X-Dev-User`.
public actor SyncClient {
    public struct PushResult: Decodable, Sendable {
        public var ok: Bool
        public var seqs: [String: Int]?
        public var error: String?
        public var eventId: String?
    }
    public struct PullResult: Decodable, Sendable {
        public var events: [Event]
        public var nextSeq: Int
        public var hasMore: Bool
    }
    public struct Snapshot: Decodable, Sendable {
        public var spaceId: String
        public var seq: Int
        public var nodes: [Node]
        public var labels: [String: [String]]
        public var attachments: [Attachment]
        public var members: [Member]
    }
    public struct SpaceSummary: Decodable, Sendable, Identifiable {
        public var id: String
        public var role: Role
        public var title: String
        public var joinedAt: Millis
    }
    public enum Auth: Sendable {
        case bearer(String)
        case devUser(String)
    }
    public struct HTTPError: Error, Sendable { public let status: Int; public let body: String }

    private let baseURL: URL
    private let auth: Auth
    private let session: URLSession

    public init(baseURL: URL, auth: Auth) {
        self.baseURL = baseURL
        self.auth = auth
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.httpBody = body
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        switch auth {
        case .bearer(let t): req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        case .devUser(let u): req.setValue(u, forHTTPHeaderField: "X-Dev-User")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) || (http.statusCode == 409 && T.self == PushResult.self) else {
            throw HTTPError(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func listSpaces() async throws -> [SpaceSummary] {
        struct R: Decodable { var spaces: [SpaceSummary] }
        return try await send(request("GET", "api/spaces"), as: R.self).spaces
    }

    public func createSpace(title: String) async throws -> String {
        struct R: Decodable { var id: String }
        let body = try JSONEncoder().encode(["title": title])
        return try await send(request("POST", "api/spaces", body: body, contentType: "application/json"), as: R.self).id
    }

    public func push(spaceId: String, events: [Event]) async throws -> PushResult {
        struct B: Encodable { var events: [Event] }
        let body = try JSONEncoder().encode(B(events: events))
        return try await send(request("POST", "api/spaces/\(spaceId)/events", body: body, contentType: "application/json"), as: PushResult.self)
    }

    public func pull(spaceId: String, since: Int, limit: Int = 500) async throws -> PullResult {
        try await send(request("GET", "api/spaces/\(spaceId)/events",
                               query: [.init(name: "since", value: String(since)), .init(name: "limit", value: String(limit))]), as: PullResult.self)
    }

    public func snapshot(spaceId: String) async throws -> Snapshot {
        try await send(request("GET", "api/spaces/\(spaceId)/snapshot"), as: Snapshot.self)
    }

    public func putBlob(spaceId: String, sha256: String, variant: String? = nil, data: Data, mime: String) async throws {
        let path = variant.map { "api/spaces/\(spaceId)/blobs/\(sha256)/\($0)" } ?? "api/spaces/\(spaceId)/blobs/\(sha256)"
        struct R: Decodable { var key: String }
        _ = try await send(request("PUT", path, body: data, contentType: mime), as: R.self)
    }

    public func blobURL(spaceId: String, sha256: String, variant: String? = nil) -> URL {
        let path = variant.map { "api/spaces/\(spaceId)/blobs/\(sha256)/\($0)" } ?? "api/spaces/\(spaceId)/blobs/\(sha256)"
        return baseURL.appending(path: path)
    }

    public func getBlob(spaceId: String, sha256: String, variant: String? = nil) async throws -> Data {
        let (data, resp) = try await session.data(for: request("GET", "api/spaces/\(spaceId)/blobs/\(sha256)" + (variant.map { "/\($0)" } ?? "")))
        let http = resp as! HTTPURLResponse
        guard http.statusCode == 200 else { throw HTTPError(status: http.statusCode, body: "") }
        return data
    }
}
