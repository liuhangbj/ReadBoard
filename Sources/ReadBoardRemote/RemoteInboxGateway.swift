import ReadBoardContract

public struct RemoteInboxGateway: InboxGateway {
    private let client: ReadBoardHTTPClient

    public init(client: ReadBoardHTTPClient) {
        self.client = client
    }

    public func configuration() async throws -> InboxConfiguration {
        try await client.get("api/v1/inbox/configuration", as: InboxConfiguration.self)
    }

    public func updateConfiguration(_ configuration: InboxConfiguration) async throws {
        let _: RemoteAcknowledgement = try await client.post(
            "api/v1/inbox/configuration", body: configuration,
            as: RemoteAcknowledgement.self)
    }

    public func importURL(_ request: InboxImportRequest) async throws -> InboxImportResult {
        try await client.post(
            "api/v1/inbox/import", body: request, as: InboxImportResult.self)
    }

    public func applyCurrentTargetsToExistingItems() async throws -> InboxRetargetResult {
        try await client.post(
            "api/v1/inbox/retarget", body: RemoteAcknowledgement(),
            as: InboxRetargetResult.self)
    }
}
