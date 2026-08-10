import XCTest
@testable import ReadBoard
import ReadBoardContract

final class HTTPTransportTests: XCTestCase {
    func testHealthDoesNotExposeConfigurationOrRequireToken() async throws {
        let router = ReadBoardHTTPRouter(services: .live, bearerToken: "secret")
        let response = await router.handle(.init(method: "GET", path: "/health", headers: [:]))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("apiVersion"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("database"))
    }

    func testProtectedRouteRejectsMissingBearerToken() async throws {
        let router = ReadBoardHTTPRouter(services: .live, bearerToken: "secret")
        let response = await router.handle(.init(method: "GET", path: "/api/v1/configuration",
            headers: ["X-ReadBoard-API-Version": "1"]))
        XCTAssertEqual(response.status, 401)
    }

    func testProtectedRouteRejectsVersionMismatchBeforeDispatch() async throws {
        let router = ReadBoardHTTPRouter(services: .live, bearerToken: "secret")
        let response = await router.handle(.init(method: "GET", path: "/api/v1/configuration",
            headers: ["Authorization": "Bearer secret", "X-ReadBoard-API-Version": "2"]))
        XCTAssertEqual(response.status, 426)
        XCTAssertEqual(response.headers[ReadBoardAPI.versionHeader], ReadBoardAPI.version)
    }

    func testEveryServiceBoardHasASuccessfulHTTPRoundTrip() async throws {
        let router = ReadBoardHTTPRouter(services: stubServices(), bearerToken: "secret")
        let routes: [(String, String, Data)] = [
            ("POST", "/api/v1/library/page", try body(ContentQuery())),
            ("GET", "/api/v1/revisions", Data()),
            ("GET", "/api/v1/processing/capabilities", Data()),
            ("GET", "/api/v1/sources/catalog", Data()),
            ("GET", "/api/v1/exports/rules", Data()),
            ("GET", "/api/v1/admin/problems", Data()),
            ("GET", "/api/v1/auth/status", Data()),
            ("GET", "/api/v1/configuration", Data()),
            ("GET", "/api/v1/maintenance", Data()),
            ("GET", "/api/v1/dependencies", Data()),
        ]
        for (method, path, requestBody) in routes {
            let response = await router.handle(.init(
                method: method, path: path, headers: authorizedHeaders, body: requestBody))
            XCTAssertEqual(response.status, 200, "round trip failed: \(path)")
            XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8")
            XCTAssertFalse(response.body.isEmpty)
        }
    }

    func testDependencySubmitUsesAcceptedTaskResponse() async throws {
        let router = ReadBoardHTTPRouter(services: stubServices(), bearerToken: "secret")
        let response = await router.handle(.init(
            method: "POST", path: "/api/v1/dependencies/submit",
            headers: authorizedHeaders,
            body: try body(DependencyTaskRequest(dependencyID: "ffmpeg", operation: .install))))
        XCTAssertEqual(response.status, 202)
        let task = try JSONDecoder().decode(DependencyTaskSnapshot.self, from: response.body)
        XCTAssertEqual(task.dependencyID, "ffmpeg")
        XCTAssertEqual(task.phase, .queued)
    }

    func testMalformedJSONBecomesStableInvalidRequest() async {
        let router = ReadBoardHTTPRouter(services: stubServices(), bearerToken: "secret")
        let response = await router.handle(.init(
            method: "POST", path: "/api/v1/library/page",
            headers: authorizedHeaders, body: Data("{".utf8)))
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("invalid_request"))
    }

    func testGatewayFailureBecomesStableOperationFailure() async throws {
        let router = ReadBoardHTTPRouter(
            services: stubServices(library: FailingLibraryGateway()), bearerToken: "secret")
        let response = await router.handle(.init(
            method: "POST", path: "/api/v1/library/page",
            headers: authorizedHeaders, body: try body(ContentQuery())))
        XCTAssertEqual(response.status, 500)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("operation_failed"))
        XCTAssertFalse(text.contains("fatalError"))
    }

    private var authorizedHeaders: [String: String] {
        ["Authorization": "Bearer secret", ReadBoardAPI.versionHeader: ReadBoardAPI.version]
    }

    private func body<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    private func stubServices(
        library: any LibraryGateway = StubLibraryGateway()
    ) -> ReadBoardServices {
        let base = ReadBoardServices.live
        return ReadBoardServices(
            library: library,
            contentDetail: base.contentDetail,
            mediaPlayback: base.mediaPlayback,
            processing: StubProcessingGateway(),
            sourceManagement: base.sourceManagement,
            sourceCatalog: StubSourceCatalogGateway(),
            sourceOnboarding: base.sourceOnboarding,
            runtimeStatus: base.runtimeStatus,
            export: StubExportGateway(),
            administration: StubAdministrationGateway(),
            configuration: StubConfigurationGateway(),
            authentication: StubAuthenticationGateway(),
            maintenance: StubMaintenanceGateway(),
            dependencyManagement: StubDependencyManagementGateway(),
            remoteAccess: nil)
    }
}

private struct StubLibraryGateway: LibraryGateway {
    func page(_ query: ContentQuery) async throws -> ContentPage { ContentPage(items: [], nextCursor: nil) }
    func snapshot() async throws -> LibrarySnapshot { fatalError("unused") }
    func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState { fatalError("unused") }
    func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState { fatalError("unused") }
    func markRead(filter: ContentFilter) async throws -> MutationSummary { fatalError("unused") }
}

private struct FailingLibraryGateway: LibraryGateway {
    func page(_ query: ContentQuery) async throws -> ContentPage { throw LibraryGatewayError.storageUnavailable }
    func snapshot() async throws -> LibrarySnapshot { fatalError("unused") }
    func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState { fatalError("unused") }
    func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState { fatalError("unused") }
    func markRead(filter: ContentFilter) async throws -> MutationSummary { fatalError("unused") }
}

private struct StubProcessingGateway: ProcessingGateway {
    func capabilities() async -> ProcessingCapabilities {
        ProcessingCapabilities(llmAvailable: true, transcriptionAvailable: true, fulltextAvailable: true)
    }
    func submit(_ command: ProcessingCommand) async throws -> ProcessingCommandSnapshot { fatalError("unused") }
    func status(requestID: String) async throws -> ProcessingCommandSnapshot { fatalError("unused") }
}

private struct StubSourceCatalogGateway: SourceCatalogGateway {
    func snapshot() async throws -> SourceCatalogSnapshot { SourceCatalogSnapshot() }
}

private struct StubExportGateway: ExportGateway {
    func rules() async throws -> [ExportRuleDTO] { [] }
    func save(rule: ExportRuleDTO) async throws -> ExportRuleDTO { fatalError("unused") }
    func delete(ruleID: Int64) async throws { fatalError("unused") }
    func stats(ruleID: Int64) async throws -> ExportRuleStatsDTO { fatalError("unused") }
    func preview(rule: ExportRuleDTO) async throws -> ExportRulePreviewDTO { fatalError("unused") }
    func run(ruleID: Int64) async throws -> ExportExecutionResult { fatalError("unused") }
    func forceExport(contentID: Int64) async throws -> ExportExecutionResult { fatalError("unused") }
}

private struct StubAdministrationGateway: AdministrationGateway {
    func dashboardStatistics() async -> DashboardStatistics { fatalError("unused") }
    func filterRules() async -> [FilterRuleRecord] { [] }
    func createFilterRule(_ rule: FilterRuleRecord) async -> Bool { false }
    func updateFilterRule(_ rule: FilterRuleRecord) async {}
    func deleteFilterRule(id: Int64) async {}
    func processingFailures() async -> [ContentProcessingFailure] { [] }
    func retryProcessingFailure(id: Int64) async -> Bool { false }
    func ignoreProcessingFailure(id: Int64) async -> Bool { false }
    func fullTextFailures(limit: Int) async -> [FullTextFailure] { [] }
    func operationalProblemCounts() async -> OperationalProblemCounts { OperationalProblemCounts() }
}

private struct StubAuthenticationGateway: AuthenticationGateway {
    func statuses() async -> [PlatformAuthenticationStatus] { [] }
    func beginAuthentication(platformID: String) async throws -> PlatformAuthenticationChallenge { fatalError("unused") }
    func pollAuthentication(platformID: String, challengeID: String) async throws -> PlatformAuthenticationPoll { fatalError("unused") }
    func signOut(platformID: String) async throws {}
}

private struct StubConfigurationGateway: ConfigurationGateway {
    func snapshot() async -> ServiceConfigurationSnapshot { ServiceConfigurationSnapshot() }
    func setProxyURL(_ value: String) async {}
    func setFeatureFlag(_ id: String, enabled: Bool) async {}
    func setPipelineFlag(_ id: String, enabled: Bool) async {}
    func setServiceFlag(_ id: String, enabled: Bool) async {}
    func setSourceTypeFlag(_ id: String, enabled: Bool) async {}
    func saveLLMProfile(_ update: LLMProfileUpdate) async -> Bool { false }
    func addLLMProfile() async {}
    func removeLLMProfile(id: Int) async {}
    func moveLLMProfile(from: Int, to: Int) async {}
    func testLLMProfile(_ update: LLMProfileUpdate) async -> ConnectionTestResult { fatalError("unused") }
    func fetchLLMModels(profileID: Int, endpoint: String, apiKey: String?) async throws -> [String] { [] }
    func setDependencyPath(id: String, path: String) async {}
    func updateExportPlatforms(_ configuration: ExportPlatformConfiguration) async {}
    func updateAIPrompts(_ configuration: AIPromptConfiguration) async {}
}

private struct StubMaintenanceGateway: MaintenanceGateway {
    func snapshot() async -> MaintenanceSnapshot {
        MaintenanceSnapshot(policy: CleanupPolicy(), usage: StorageUsage(), backups: [], trash: [])
    }
    func updatePolicy(_ policy: CleanupPolicy) async {}
    func runCleanup() async -> String { "" }
    func createBackup() async -> MaintenanceSnapshot { await snapshot() }
    func restoreBackup(id: String) async throws {}
    func restoreTrash(id: String) async -> TrashRestoreResult { TrashRestoreResult(restored: 0, skipped: 0) }
    func deleteTrash(id: String) async {}
    func clearTrash() async {}
}

private struct StubDependencyManagementGateway: DependencyManagementGateway {
    func snapshot() async -> DependencyManagementSnapshot { DependencyManagementSnapshot() }
    func submit(_ request: DependencyTaskRequest) async throws -> DependencyTaskSnapshot {
        DependencyTaskSnapshot(id: "task", dependencyID: request.dependencyID,
            operation: request.operation, phase: .queued, message: "queued")
    }
    func cancel(taskID: String) async {}
}
