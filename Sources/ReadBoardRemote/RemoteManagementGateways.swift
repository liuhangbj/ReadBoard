import Foundation
import ReadBoardContract

public struct RemoteExportGateway: ExportGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func rules() async throws -> [ExportRuleDTO] {
        try await client.get("api/v1/exports/rules", as: [ExportRuleDTO].self)
    }
    public func save(rule: ExportRuleDTO) async throws -> ExportRuleDTO {
        try await client.post("api/v1/exports/save", body: rule, as: ExportRuleDTO.self)
    }
    public func delete(ruleID: Int64) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/exports/delete",
            body: RemoteExportRuleIDRequest(ruleID: ruleID), as: RemoteAcknowledgement.self)
    }
    public func stats(ruleID: Int64) async throws -> ExportRuleStatsDTO {
        try await client.post("api/v1/exports/stats",
            body: RemoteExportRuleIDRequest(ruleID: ruleID), as: ExportRuleStatsDTO.self)
    }
    public func preview(rule: ExportRuleDTO) async throws -> ExportRulePreviewDTO {
        try await client.post("api/v1/exports/preview", body: rule,
                              as: ExportRulePreviewDTO.self)
    }
    public func run(ruleID: Int64) async throws -> ExportExecutionResult {
        try await client.post("api/v1/exports/run",
            body: RemoteExportRuleIDRequest(ruleID: ruleID), as: ExportExecutionResult.self)
    }
    public func forceExport(contentID: Int64) async throws -> ExportExecutionResult {
        try await client.post("api/v1/exports/force",
            body: RemoteContentIDRequest(contentID: contentID), as: ExportExecutionResult.self)
    }
}

public struct RemoteAdministrationGateway: AdministrationGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func dashboardStatistics() async throws -> DashboardStatistics {
        try await client.get("api/v1/admin/dashboard", as: DashboardStatistics.self)
    }
    public func filterRules() async throws -> [FilterRuleRecord] {
        try await client.get("api/v1/admin/filter-rules", as: [FilterRuleRecord].self)
    }
    public func createFilterRule(_ rule: FilterRuleRecord) async -> Bool {
        (try? await client.post("api/v1/admin/filter-rules/create", body: rule,
                               as: RemoteBoolValue.self).value) ?? false
    }
    public func updateFilterRule(_ rule: FilterRuleRecord) async {
        let _: RemoteAcknowledgement? = try? await client.post(
            "api/v1/admin/filter-rules/update", body: rule, as: RemoteAcknowledgement.self)
    }
    public func deleteFilterRule(id: Int64) async {
        let _: RemoteAcknowledgement? = try? await client.post(
            "api/v1/admin/filter-rules/delete", body: RemoteFilterRuleIDRequest(id: id),
            as: RemoteAcknowledgement.self)
    }
    public func processingFailures() async throws -> [ContentProcessingFailure] {
        try await client.get("api/v1/admin/processing-failures",
                             as: [ContentProcessingFailure].self)
    }
    public func retryProcessingFailure(id: Int64) async -> Bool {
        (try? await client.post("api/v1/admin/processing-failures/retry",
            body: RemoteInt64IDRequest(id: id), as: RemoteBoolValue.self).value) ?? false
    }
    public func ignoreProcessingFailure(id: Int64) async -> Bool {
        (try? await client.post("api/v1/admin/processing-failures/ignore",
            body: RemoteInt64IDRequest(id: id), as: RemoteBoolValue.self).value) ?? false
    }
    public func fullTextFailures(limit: Int) async throws -> [FullTextFailure] {
        try await client.post("api/v1/admin/fulltext-failures",
            body: RemoteLimitRequest(limit: limit), as: [FullTextFailure].self)
    }
    public func operationalProblemCounts() async throws -> OperationalProblemCounts {
        try await client.get("api/v1/admin/problems", as: OperationalProblemCounts.self)
    }
}

public struct RemoteAuthenticationGateway: AuthenticationGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func statuses() async throws -> [PlatformAuthenticationStatus] {
        try await client.get("api/v1/auth/status", as: [PlatformAuthenticationStatus].self)
    }
    public func beginAuthentication(platformID: String) async throws -> PlatformAuthenticationChallenge {
        try await client.post("api/v1/auth/begin",
            body: RemotePlatformRequest(platformID: platformID),
            as: PlatformAuthenticationChallenge.self)
    }
    public func pollAuthentication(platformID: String,
                                   challengeID: String) async throws -> PlatformAuthenticationPoll {
        try await client.post("api/v1/auth/poll",
            body: RemoteAuthenticationPollRequest(platformID: platformID,
                                                  challengeID: challengeID),
            as: PlatformAuthenticationPoll.self)
    }
    public func signOut(platformID: String) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/auth/sign-out",
            body: RemotePlatformRequest(platformID: platformID),
            as: RemoteAcknowledgement.self)
    }
}

public struct RemoteConfigurationGateway: ConfigurationGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func snapshot() async throws -> ServiceConfigurationSnapshot {
        try await client.get("api/v1/configuration", as: ServiceConfigurationSnapshot.self)
    }
    public func setProxyURL(_ value: String) async {
        await acknowledge("api/v1/configuration/proxy", RemoteStringValue(value))
    }
    public func setFeatureFlag(_ id: String, enabled: Bool) async {
        await acknowledge("api/v1/configuration/feature-flag",
                          RemoteConfigurationFlagRequest(id: id, enabled: enabled))
    }
    public func setPipelineFlag(_ id: String, enabled: Bool) async {
        await acknowledge("api/v1/configuration/pipeline-flag",
                          RemoteConfigurationFlagRequest(id: id, enabled: enabled))
    }
    public func setServiceFlag(_ id: String, enabled: Bool) async {
        await acknowledge("api/v1/configuration/service-flag",
                          RemoteConfigurationFlagRequest(id: id, enabled: enabled))
    }
    public func setSourceTypeFlag(_ id: String, enabled: Bool) async {
        await acknowledge("api/v1/configuration/source-type-flag",
                          RemoteConfigurationFlagRequest(id: id, enabled: enabled))
    }
    public func saveLLMProfile(_ update: LLMProfileUpdate) async -> Bool {
        (try? await client.post("api/v1/configuration/llm/save", body: update,
                               as: RemoteBoolValue.self).value) ?? false
    }
    public func addLLMProfile() async {
        await acknowledge("api/v1/configuration/llm/add", RemoteAcknowledgement())
    }
    public func removeLLMProfile(id: Int) async {
        await acknowledge("api/v1/configuration/llm/remove", RemoteIntIDRequest(id: id))
    }
    public func moveLLMProfile(from: Int, to: Int) async {
        await acknowledge("api/v1/configuration/llm/move", RemoteMoveRequest(from: from, to: to))
    }
    public func llmAPIKey(profileID: Int) async throws -> String? {
        let value = try await client.post(
            "api/v1/configuration/llm/api-key",
            body: RemoteIntIDRequest(id: profileID),
            as: RemoteStringValue.self).value
        return value.isEmpty ? nil : value
    }
    public func testLLMProfile(_ update: LLMProfileUpdate) async -> ConnectionTestResult {
        (try? await client.post("api/v1/configuration/llm/test", body: update,
                               as: ConnectionTestResult.self))
            ?? ConnectionTestResult(succeeded: false, message: "无法连接 ReadBoard 服务")
    }
    public func fetchLLMModels(profileID: Int, endpoint: String,
                               apiKey: String?) async throws -> [String] {
        try await client.post("api/v1/configuration/llm/models",
            body: RemoteLLMModelsRequest(profileID: profileID, endpoint: endpoint, apiKey: apiKey),
            as: [String].self)
    }
    public func setDependencyPath(id: String, path: String) async {
        await acknowledge("api/v1/configuration/dependency-path",
                          RemoteDependencyPathRequest(id: id, path: path))
    }
    public func updateExportPlatforms(_ configuration: ExportPlatformConfiguration) async {
        await acknowledge("api/v1/configuration/export-platforms", configuration)
    }
    public func updateAIPrompts(_ configuration: AIPromptConfiguration) async {
        await acknowledge("api/v1/configuration/ai-prompts", configuration)
    }

    private func acknowledge<Request: Encodable>(_ path: String, _ body: Request) async {
        let _: RemoteAcknowledgement? = try? await client.post(
            path, body: body, as: RemoteAcknowledgement.self)
    }
}

public struct RemoteMaintenanceGateway: MaintenanceGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func snapshot() async throws -> MaintenanceSnapshot {
        try await client.get("api/v1/maintenance", as: MaintenanceSnapshot.self)
    }
    public func updatePolicy(_ policy: CleanupPolicy) async {
        let _: RemoteAcknowledgement? = try? await client.post("api/v1/maintenance/policy",
            body: policy, as: RemoteAcknowledgement.self)
    }
    public func runCleanup() async -> String {
        (try? await client.post("api/v1/maintenance/cleanup", body: RemoteAcknowledgement(),
                               as: RemoteStringValue.self).value) ?? "清理操作失败"
    }
    public func createBackup() async -> MaintenanceSnapshot {
        if let value = try? await client.post("api/v1/maintenance/backup",
                                              body: RemoteAcknowledgement(),
                                              as: MaintenanceSnapshot.self) {
            return value
        }
        return (try? await snapshot())
            ?? MaintenanceSnapshot(policy: CleanupPolicy(), usage: StorageUsage(),
                                   backups: [], trash: [])
    }
    public func restoreBackup(id: String) async throws {
        let _: RemoteAcknowledgement = try await client.post("api/v1/maintenance/backup/restore",
            body: RemoteStringIDRequest(id: id), as: RemoteAcknowledgement.self)
    }
    public func restoreTrash(id: String) async -> TrashRestoreResult {
        (try? await client.post("api/v1/maintenance/trash/restore",
            body: RemoteStringIDRequest(id: id), as: TrashRestoreResult.self))
            ?? TrashRestoreResult(restored: 0, skipped: 0)
    }
    public func deleteTrash(id: String) async {
        let _: RemoteAcknowledgement? = try? await client.post("api/v1/maintenance/trash/delete",
            body: RemoteStringIDRequest(id: id), as: RemoteAcknowledgement.self)
    }
    public func clearTrash() async {
        let _: RemoteAcknowledgement? = try? await client.post("api/v1/maintenance/trash/clear",
            body: RemoteAcknowledgement(), as: RemoteAcknowledgement.self)
    }
}

public struct RemoteDependencyManagementGateway: DependencyManagementGateway {
    private let client: ReadBoardHTTPClient
    public init(client: ReadBoardHTTPClient) { self.client = client }

    public func snapshot() async throws -> DependencyManagementSnapshot {
        try await client.get(
            "api/v1/dependencies",
            as: DependencyManagementSnapshot.self)
    }

    public func submit(_ request: DependencyTaskRequest) async throws -> DependencyTaskSnapshot {
        try await client.post(
            "api/v1/dependencies/submit",
            body: request,
            as: DependencyTaskSnapshot.self)
    }

    public func cancel(taskID: String) async {
        let _: RemoteAcknowledgement? = try? await client.post(
            "api/v1/dependencies/cancel",
            body: RemoteStringIDRequest(id: taskID),
            as: RemoteAcknowledgement.self)
    }
}
