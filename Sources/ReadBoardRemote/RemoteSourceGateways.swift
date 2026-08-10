import Foundation
import ReadBoardContract

public struct RemoteProcessingGateway: ProcessingGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func capabilities() async -> ProcessingCapabilities {
        (try? await client.get("api/v1/processing/capabilities",
            as: ProcessingCapabilities.self))
            ?? ProcessingCapabilities(llmAvailable: false, transcriptionAvailable: false,
                                      fulltextAvailable: false)
    }

    public func submit(_ command: ProcessingCommand) async throws -> ProcessingCommandSnapshot {
        try await client.post("api/v1/processing/submit", body: command,
                              as: ProcessingCommandSnapshot.self)
    }

    public func status(requestID: String) async throws -> ProcessingCommandSnapshot {
        try await client.post("api/v1/processing/status",
            body: RemoteProcessingStatusRequest(requestID: requestID),
            as: ProcessingCommandSnapshot.self)
    }

    public func recent(limit: Int) async -> [ProcessingActivity] {
        (try? await client.post("api/v1/processing/recent",
            body: RemoteLimitRequest(limit: limit),
            as: [ProcessingActivity].self)) ?? []
    }
}

public struct RemoteSourceManagementGateway: SourceManagementGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func syncSettings() async -> SourceSyncSettings {
        (try? await client.get("api/v1/sources/sync-settings", as: SourceSyncSettings.self))
            ?? SourceSyncSettings(enabled: false, intervalMinutes: 15)
    }

    public func updateSyncSettings(_ settings: SourceSyncSettings) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/sync-settings",
            body: settings, as: RemoteAcknowledgement.self)
    }

    public func createFolder(name: String) async throws -> SourceMaintenanceResult {
        try await client.post("api/v1/sources/folder/create",
            body: RemoteNameRequest(name: name), as: SourceMaintenanceResult.self)
    }

    public func syncAll() async throws -> SourceMaintenanceResult {
        try await client.post("api/v1/sources/sync-all", body: RemoteAcknowledgement(),
                              as: SourceMaintenanceResult.self)
    }

    public func rename(scope: SourceScope, name: String) async throws -> SourceMaintenanceResult {
        try await client.post("api/v1/sources/rename",
            body: RemoteSourceRenameRequest(scope: scope, name: name),
            as: SourceMaintenanceResult.self)
    }

    public func remove(scope: SourceScope) async throws -> SourceMaintenanceResult {
        try await client.post("api/v1/sources/remove", body: scope,
                              as: SourceMaintenanceResult.self)
    }

    public func assignSource(sourceID: Int64, folderID: Int64?) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/assign",
            body: RemoteSourceAssignmentRequest(sourceID: sourceID, folderID: folderID),
            as: RemoteAcknowledgement.self)
    }

    public func sync(scope: SourceScope) async throws -> SourceMaintenanceResult {
        try await client.post("api/v1/sources/sync", body: scope,
                              as: SourceMaintenanceResult.self)
    }

    public func setPolicy(scope: SourceScope, key: SourcePolicyKey, enabled: Bool) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/policy",
            body: RemoteSourcePolicyRequest(scope: scope, key: key, enabled: enabled),
            as: RemoteAcknowledgement.self)
    }

    public func backfillProcessing(scope: SourceScope,
                                   key: SourcePolicyKey?) async throws -> SourceMaintenanceResult {
        let job = try await submitBackfillProcessing(scope: scope, key: key)
        return SourceMaintenanceResult(message: job.message)
    }

    public func submitBackfillProcessing(
        scope: SourceScope,
        key: SourcePolicyKey?
    ) async throws -> SourceOperationJobSnapshot {
        try await client.post("api/v1/sources/backfill",
            body: RemoteSourceBackfillRequest(scope: scope, key: key),
            as: SourceOperationJobSnapshot.self)
    }

    public func submitSourceSync(scope: SourceScope?) async throws -> SourceOperationJobSnapshot {
        try await client.post("api/v1/sources/jobs/sync",
            body: RemoteSourceSyncJobRequest(scope: scope),
            as: SourceOperationJobSnapshot.self)
    }

    public func submitFulltextRefetch(
        scope: SourceScope,
        fullHistory: Bool
    ) async throws -> SourceOperationJobSnapshot {
        try await client.post("api/v1/sources/jobs/fulltext",
            body: RemoteSourceRefetchRequest(scope: scope, fullHistory: fullHistory),
            as: SourceOperationJobSnapshot.self)
    }

    public func sourceOperationStatus(id: String) async throws -> SourceOperationJobSnapshot {
        try await client.post("api/v1/sources/jobs/status",
            body: RemoteSourceOperationRequest(id: id),
            as: SourceOperationJobSnapshot.self)
    }

    public func cancelSourceOperation(id: String) async {
        let _: RemoteAcknowledgement? = try? await client.post(
            "api/v1/sources/jobs/cancel",
            body: RemoteSourceOperationRequest(id: id),
            as: RemoteAcknowledgement.self)
    }

    public func setFetchMode(scope: SourceScope, mode: SourceFetchMode) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/fetch-mode",
            body: RemoteSourceFetchModeRequest(scope: scope, mode: mode),
            as: RemoteAcknowledgement.self)
    }

    public func redetectFetchMode(scope: SourceScope) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/redetect-fetch-mode",
            body: scope, as: RemoteAcknowledgement.self)
    }

    public func setFetchInterval(scope: SourceScope, minutes: Int) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/fetch-interval",
            body: RemoteSourceIntervalRequest(scope: scope, minutes: minutes),
            as: RemoteAcknowledgement.self)
    }

    public func setEnabled(sourceID: Int64, enabled: Bool) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/enabled",
            body: RemoteSourceEnabledRequest(sourceID: sourceID, enabled: enabled),
            as: RemoteAcknowledgement.self)
    }

    public func setMaximumRetainedContent(sourceID: Int64, count: Int) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/sources/retention",
            body: RemoteSourceRetentionRequest(sourceID: sourceID, count: count),
            as: RemoteAcknowledgement.self)
    }

    public func refetchFulltext(scope: SourceScope,
                                fullHistory: Bool) async throws -> SourceMaintenanceResult {
        try await client.post("api/v1/sources/refetch-fulltext",
            body: RemoteSourceRefetchRequest(scope: scope, fullHistory: fullHistory),
            as: SourceMaintenanceResult.self)
    }

    public func retryFulltext(contentID: Int64) async throws -> SourceMaintenanceResult {
        try await client.post("api/v1/sources/retry-fulltext",
            body: RemoteContentIDRequest(contentID: contentID), as: SourceMaintenanceResult.self)
    }
}

public struct RemoteSourceOnboardingGateway: SourceOnboardingGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func supportedSourceTypes() async -> [SourceTypeDescriptor] {
        (try? await client.get("api/v1/onboarding/types", as: [SourceTypeDescriptor].self)) ?? []
    }

    public func discover(identifier: String,
                         suggestedType: String?) async throws -> SourceDiscoveryResult {
        try await client.post("api/v1/onboarding/discover",
            body: RemoteSourceDiscoveryRequest(identifier: identifier, suggestedType: suggestedType),
            as: SourceDiscoveryResult.self)
    }

    public func create(request: SourceCreationRequest) async throws -> SourceCreationResult {
        try await client.post("api/v1/onboarding/create", body: request,
                              as: SourceCreationResult.self)
    }

    public func importSources(items: [SourceBatchImportItem],
                              refreshAfterCreation: Bool) async throws -> SourceBatchImportResult {
        try await client.post("api/v1/onboarding/import",
            body: RemoteSourceImportRequest(items: items,
                                            refreshAfterCreation: refreshAfterCreation),
            as: SourceBatchImportResult.self)
    }

    public func platformSubscriptions(
        platform: String
    ) async throws -> [PlatformSubscriptionCandidate] {
        try await client.post("api/v1/onboarding/subscriptions",
            body: RemotePlatformRequest(platformID: platform),
            as: [PlatformSubscriptionCandidate].self)
    }

    public func exportOPML() async -> String {
        (try? await client.get("api/v1/onboarding/export-opml", as: RemoteStringValue.self).value)
            ?? ""
    }
}
