import ReadBoardContract

public struct RemoteDataRevisionGateway: DataRevisionGateway, Sendable {
    private let client: ReadBoardHTTPClient

    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func snapshot() async throws -> DataRevisionSnapshot {
        try await client.get("api/v1/revisions", as: DataRevisionSnapshot.self)
    }
}
