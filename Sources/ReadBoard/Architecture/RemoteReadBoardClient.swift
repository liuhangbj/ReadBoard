import Foundation
import ReadBoardContract

public struct ReadBoardHTTPClient: Sendable {
    public let baseURL: URL
    private let bearerToken: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.bearerToken = bearerToken; self.session = session
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func get<Response: Decodable>(_ path: String, as type: Response.Type) async throws -> Response {
        try await send(method: "GET", path: path, body: Optional<Data>.none, as: type)
    }

    public func post<Request: Encodable, Response: Decodable>(
        _ path: String, body: Request, as type: Response.Type
    ) async throws -> Response {
        try await send(method: "POST", path: path, body: try encoder.encode(body), as: type)
    }

    private func send<Response: Decodable>(method: String, path: String, body: Data?,
                                            as type: Response.Type) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw RemoteClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(ReadBoardAPI.version, forHTTPHeaderField: "X-ReadBoard-API-Version")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteClientError.invalidResponse }
        guard http.value(forHTTPHeaderField: "X-ReadBoard-API-Version") == ReadBoardAPI.version else {
            throw RemoteClientError.versionMismatch
        }
        guard (200..<300).contains(http.statusCode) else {
            let value = try? decoder.decode(RemoteErrorBody.self, from: data)
            throw RemoteClientError.server(status: http.statusCode, message: value?.message ?? "服务请求失败")
        }
        return try decoder.decode(type, from: data)
    }
}

public struct RemoteLibraryGateway: LibraryGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }
    public func page(_ query: ContentQuery) async throws -> ContentPage {
        try await client.post("api/v1/library/page", body: query, as: ContentPage.self)
    }
    public func snapshot() async throws -> LibrarySnapshot {
        try await client.get("api/v1/library/snapshot", as: LibrarySnapshot.self)
    }
    public func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState {
        try await client.post("api/v1/library/read", body: RemoteContentStateRequest(contentID: contentID, value: isRead), as: ContentState.self)
    }
    public func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState {
        try await client.post("api/v1/library/star", body: RemoteContentStateRequest(contentID: contentID, value: isStarred), as: ContentState.self)
    }
    public func markRead(filter: ContentFilter) async throws -> MutationSummary {
        try await client.post("api/v1/library/mark-read", body: filter, as: MutationSummary.self)
    }
}

public struct RemoteContentDetailGateway: ContentDetailGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }
    public func detail(contentID: Int64) async throws -> ContentDetail {
        try await client.post("api/v1/content/detail", body: RemoteContentIDRequest(contentID: contentID), as: ContentDetail.self)
    }
}

public struct RemoteSourceCatalogGateway: SourceCatalogGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }
    public func snapshot() async throws -> SourceCatalogSnapshot {
        try await client.get("api/v1/sources/catalog", as: SourceCatalogSnapshot.self)
    }
}

public struct RemoteRuntimeStatusGateway: RuntimeStatusGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }
    public func snapshot(refreshCounts: Bool) async -> RuntimeStatusSnapshot {
        (try? await client.post("api/v1/runtime/snapshot",
            body: RemoteRuntimeSnapshotRequest(refreshCounts: refreshCounts),
            as: RuntimeStatusSnapshot.self)) ?? RuntimeStatusSnapshot()
    }
    public func runProcessingScan() async {}
}

private struct RemoteContentStateRequest: Codable { let contentID: Int64; let value: Bool }
private struct RemoteContentIDRequest: Codable { let contentID: Int64 }
private struct RemoteRuntimeSnapshotRequest: Codable { let refreshCounts: Bool }
private struct RemoteErrorBody: Codable { let error: String; let message: String }

public enum RemoteClientError: LocalizedError {
    case invalidURL, invalidResponse, versionMismatch
    case server(status: Int, message: String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "服务地址无效"
        case .invalidResponse: "服务响应无效"
        case .versionMismatch: "客户端与服务端版本不兼容"
        case .server(let status, let message): "HTTP \(status)：\(message)"
        }
    }
}
