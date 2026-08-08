import Foundation
import Network
import ReadBoardContract

public enum ReadBoardAPI {
    public static let version = ReadBoardRemoteAPI.version
    public static let versionHeader = "x-readboard-api-version"
    public static let maximumRequestBytes = 2 * 1_024 * 1_024
}

public struct ReadBoardHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

public struct ReadBoardHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method; self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

private struct APIErrorBody: Codable { let error: String; let message: String }
/// 与 socket 无关的可测试路由器。所有错误都被转换为稳定 JSON，不把数据库或平台异常堆栈暴露给客户端。
public struct ReadBoardHTTPRouter: Sendable {
    private let services: ReadBoardServices
    private let authorizeToken: @Sendable (String) async -> [RemoteAccessScope]?
    private let redeemPairing: (@Sendable (RemotePairingRequest) async throws -> RemotePairingCredential)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(services: ReadBoardServices, bearerToken: String) {
        self.services = services
        self.authorizeToken = { token in
            !bearerToken.isEmpty && token == bearerToken ? RemoteAccessScope.fullControl : nil
        }
        self.redeemPairing = nil
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    init(services: ReadBoardServices, deviceStore: RemoteDeviceStore,
         pairingService: RemotePairingService) {
        self.services = services
        self.authorizeToken = { token in await deviceStore.authorization(token: token) }
        self.redeemPairing = { request in try await pairingService.redeem(request) }
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func handle(_ request: ReadBoardHTTPRequest) async -> ReadBoardHTTPResponse {
        if request.path == "/health" {
            return json(["status": "ok", "apiVersion": ReadBoardAPI.version])
        }
        guard request.path.hasPrefix("/api/v1/") else { return failure(404, "not_found", "接口不存在") }
        guard request.headers[ReadBoardAPI.versionHeader] == ReadBoardAPI.version else {
            return failure(426, "version_mismatch", "客户端与服务端 API 版本不兼容")
        }
        guard request.body.count <= ReadBoardAPI.maximumRequestBytes else {
            return failure(413, "request_too_large", "请求体超过限制")
        }

        if request.method.uppercased() == "POST", request.path == "/api/v1/pair" {
            guard let redeemPairing else {
                return failure(403, "pairing_unavailable", "服务端未开启设备配对")
            }
            do {
                let credential = try await redeemPairing(
                    try decode(RemotePairingRequest.self, request.body))
                return json(credential, status: 201)
            } catch let error as RemotePairingError {
                let status: Int = switch error {
                case .invalidCode: 403
                case .tooManyAttempts: 429
                case .expired, .noActiveChallenge: 410
                case .serviceUnavailable: 503
                }
                return failure(status, "pairing_failed", error.localizedDescription)
            } catch {
                return failure(400, "pairing_failed", error.localizedDescription)
            }
        }

        let authorization = request.headers["authorization"] ?? ""
        let token = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : ""
        guard let grantedScopes = await authorizeToken(token) else {
            return failure(401, "unauthorized", "设备令牌无效或已撤销")
        }
        if let requiredScope = requiredScope(for: request), !grantedScopes.contains(requiredScope) {
            return failure(403, "insufficient_scope", "设备没有执行此操作的权限")
        }

        do {
            switch (request.method.uppercased(), request.path) {
            case ("GET", "/api/v1/server/profile"):
                let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? "ReadBoard"
                return json(RemoteServerProfile(apiVersion: ReadBoardAPI.version,
                    serverName: name, capabilities: services.remoteCapabilities,
                    grantedScopes: grantedScopes, transportSecurity: "none"))
            case ("POST", "/api/v1/library/page"):
                return json(try await services.library.page(try decode(ContentQuery.self, request.body)))
            case ("GET", "/api/v1/library/snapshot"):
                return json(try await services.library.snapshot())
            case ("POST", "/api/v1/library/read"):
                let value = try decode(RemoteContentStateRequest.self, request.body)
                return json(try await services.library.setRead(contentID: value.contentID, isRead: value.value))
            case ("POST", "/api/v1/library/star"):
                let value = try decode(RemoteContentStateRequest.self, request.body)
                return json(try await services.library.setStarred(contentID: value.contentID, isStarred: value.value))
            case ("POST", "/api/v1/library/mark-read"):
                return json(try await services.library.markRead(filter: try decode(ContentFilter.self, request.body)))
            case ("POST", "/api/v1/content/detail"):
                let value = try decode(RemoteContentIDRequest.self, request.body)
                return json(try await services.contentDetail.detail(contentID: value.contentID))

            case ("GET", "/api/v1/processing/capabilities"):
                return json(await services.processing.capabilities())
            case ("GET", "/api/v1/sources/catalog"):
                return json(try await services.sourceCatalog.snapshot())
            case ("POST", "/api/v1/runtime/snapshot"):
                let value = try decode(RemoteRuntimeSnapshotRequest.self, request.body)
                return json(await services.runtimeStatus.snapshot(refreshCounts: value.refreshCounts))
            case ("POST", "/api/v1/runtime/scan"):
                await services.runtimeStatus.runProcessingScan()
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/processing/submit"):
                return json(try await services.processing.submit(try decode(ProcessingCommand.self, request.body)))
            case ("POST", "/api/v1/processing/status"):
                let value = try decode(RemoteProcessingStatusRequest.self, request.body)
                return json(try await services.processing.status(requestID: value.requestID))

            case ("GET", "/api/v1/sources/sync-settings"):
                return json(await services.sourceManagement.syncSettings())
            case ("POST", "/api/v1/sources/sync-settings"):
                try await services.sourceManagement.updateSyncSettings(
                    try decode(SourceSyncSettings.self, request.body))
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/folder/create"):
                let value = try decode(RemoteNameRequest.self, request.body)
                return json(try await services.sourceManagement.createFolder(name: value.name))
            case ("POST", "/api/v1/sources/sync-all"):
                return json(try await services.sourceManagement.syncAll())
            case ("POST", "/api/v1/sources/rename"):
                let value = try decode(RemoteSourceRenameRequest.self, request.body)
                return json(try await services.sourceManagement.rename(scope: value.scope, name: value.name))
            case ("POST", "/api/v1/sources/remove"):
                return json(try await services.sourceManagement.remove(
                    scope: try decode(SourceScope.self, request.body)))
            case ("POST", "/api/v1/sources/assign"):
                let value = try decode(RemoteSourceAssignmentRequest.self, request.body)
                try await services.sourceManagement.assignSource(
                    sourceID: value.sourceID, folderID: value.folderID)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/sync"):
                return json(try await services.sourceManagement.sync(
                    scope: try decode(SourceScope.self, request.body)))
            case ("POST", "/api/v1/sources/policy"):
                let value = try decode(RemoteSourcePolicyRequest.self, request.body)
                try await services.sourceManagement.setPolicy(
                    scope: value.scope, key: value.key, enabled: value.enabled)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/backfill"):
                let value = try decode(RemoteSourceBackfillRequest.self, request.body)
                return json(try await services.sourceManagement.backfillProcessing(
                    scope: value.scope, key: value.key))
            case ("POST", "/api/v1/sources/fetch-mode"):
                let value = try decode(RemoteSourceFetchModeRequest.self, request.body)
                try await services.sourceManagement.setFetchMode(scope: value.scope, mode: value.mode)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/redetect-fetch-mode"):
                try await services.sourceManagement.redetectFetchMode(
                    scope: try decode(SourceScope.self, request.body))
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/fetch-interval"):
                let value = try decode(RemoteSourceIntervalRequest.self, request.body)
                try await services.sourceManagement.setFetchInterval(
                    scope: value.scope, minutes: value.minutes)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/enabled"):
                let value = try decode(RemoteSourceEnabledRequest.self, request.body)
                try await services.sourceManagement.setEnabled(
                    sourceID: value.sourceID, enabled: value.enabled)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/retention"):
                let value = try decode(RemoteSourceRetentionRequest.self, request.body)
                try await services.sourceManagement.setMaximumRetainedContent(
                    sourceID: value.sourceID, count: value.count)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/sources/refetch-fulltext"):
                let value = try decode(RemoteSourceRefetchRequest.self, request.body)
                return json(try await services.sourceManagement.refetchFulltext(
                    scope: value.scope, fullHistory: value.fullHistory))
            case ("POST", "/api/v1/sources/retry-fulltext"):
                let value = try decode(RemoteContentIDRequest.self, request.body)
                return json(try await services.sourceManagement.retryFulltext(contentID: value.contentID))

            case ("GET", "/api/v1/onboarding/types"):
                return json(await services.sourceOnboarding.supportedSourceTypes())
            case ("POST", "/api/v1/onboarding/discover"):
                let value = try decode(RemoteSourceDiscoveryRequest.self, request.body)
                return json(try await services.sourceOnboarding.discover(
                    identifier: value.identifier, suggestedType: value.suggestedType))
            case ("POST", "/api/v1/onboarding/create"):
                return json(try await services.sourceOnboarding.create(
                    request: try decode(SourceCreationRequest.self, request.body)))
            case ("POST", "/api/v1/onboarding/import"):
                let value = try decode(RemoteSourceImportRequest.self, request.body)
                return json(try await services.sourceOnboarding.importSources(
                    items: value.items, refreshAfterCreation: value.refreshAfterCreation))
            case ("POST", "/api/v1/onboarding/subscriptions"):
                let value = try decode(RemotePlatformRequest.self, request.body)
                return json(try await services.sourceOnboarding.platformSubscriptions(
                    platform: value.platformID))
            case ("GET", "/api/v1/onboarding/export-opml"):
                return json(RemoteStringValue(await services.sourceOnboarding.exportOPML()))

            case ("GET", "/api/v1/exports/rules"):
                return json(try await services.export.rules())
            case ("POST", "/api/v1/exports/save"):
                return json(try await services.export.save(rule: try decode(ExportRuleDTO.self, request.body)))
            case ("POST", "/api/v1/exports/delete"):
                let value = try decode(RemoteExportRuleIDRequest.self, request.body)
                try await services.export.delete(ruleID: value.ruleID)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/exports/stats"):
                let value = try decode(RemoteExportRuleIDRequest.self, request.body)
                return json(try await services.export.stats(ruleID: value.ruleID))
            case ("POST", "/api/v1/exports/preview"):
                return json(try await services.export.preview(rule: try decode(ExportRuleDTO.self, request.body)))
            case ("POST", "/api/v1/exports/run"):
                let value = try decode(RemoteExportRuleIDRequest.self, request.body)
                return json(try await services.export.run(ruleID: value.ruleID))
            case ("POST", "/api/v1/exports/force"):
                let value = try decode(RemoteContentIDRequest.self, request.body)
                return json(try await services.export.forceExport(contentID: value.contentID))

            case ("GET", "/api/v1/admin/dashboard"):
                return json(await services.administration.dashboardStatistics())
            case ("GET", "/api/v1/admin/filter-rules"):
                return json(await services.administration.filterRules())
            case ("POST", "/api/v1/admin/filter-rules/create"):
                return json(RemoteBoolValue(await services.administration.createFilterRule(
                    try decode(FilterRuleRecord.self, request.body))))
            case ("POST", "/api/v1/admin/filter-rules/update"):
                await services.administration.updateFilterRule(
                    try decode(FilterRuleRecord.self, request.body))
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/admin/filter-rules/delete"):
                let value = try decode(RemoteFilterRuleIDRequest.self, request.body)
                await services.administration.deleteFilterRule(id: value.id)
                return json(RemoteAcknowledgement())
            case ("GET", "/api/v1/admin/processing-failures"):
                return json(await services.administration.processingFailures())
            case ("POST", "/api/v1/admin/processing-failures/retry"):
                let value = try decode(RemoteInt64IDRequest.self, request.body)
                return json(RemoteBoolValue(await services.administration.retryProcessingFailure(id: value.id)))
            case ("POST", "/api/v1/admin/processing-failures/ignore"):
                let value = try decode(RemoteInt64IDRequest.self, request.body)
                return json(RemoteBoolValue(await services.administration.ignoreProcessingFailure(id: value.id)))
            case ("POST", "/api/v1/admin/fulltext-failures"):
                let value = try decode(RemoteLimitRequest.self, request.body)
                return json(await services.administration.fullTextFailures(limit: value.limit))
            case ("GET", "/api/v1/admin/problems"):
                return json(await services.administration.operationalProblemCounts())

            case ("GET", "/api/v1/auth/status"):
                return json(await services.authentication.statuses())
            case ("POST", "/api/v1/auth/begin"):
                let value = try decode(RemotePlatformRequest.self, request.body)
                return json(try await services.authentication.beginAuthentication(
                    platformID: value.platformID))
            case ("POST", "/api/v1/auth/poll"):
                let value = try decode(RemoteAuthenticationPollRequest.self, request.body)
                return json(try await services.authentication.pollAuthentication(
                    platformID: value.platformID, challengeID: value.challengeID))
            case ("POST", "/api/v1/auth/sign-out"):
                let value = try decode(RemotePlatformRequest.self, request.body)
                try await services.authentication.signOut(platformID: value.platformID)
                return json(RemoteAcknowledgement())

            case ("GET", "/api/v1/configuration"):
                return json(await services.configuration.snapshot())
            case ("POST", "/api/v1/configuration/proxy"):
                await services.configuration.setProxyURL(
                    try decode(RemoteStringValue.self, request.body).value)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/feature-flag"):
                let value = try decode(RemoteConfigurationFlagRequest.self, request.body)
                await services.configuration.setFeatureFlag(value.id, enabled: value.enabled)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/pipeline-flag"):
                let value = try decode(RemoteConfigurationFlagRequest.self, request.body)
                await services.configuration.setPipelineFlag(value.id, enabled: value.enabled)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/service-flag"):
                let value = try decode(RemoteConfigurationFlagRequest.self, request.body)
                await services.configuration.setServiceFlag(value.id, enabled: value.enabled)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/source-type-flag"):
                let value = try decode(RemoteConfigurationFlagRequest.self, request.body)
                await services.configuration.setSourceTypeFlag(value.id, enabled: value.enabled)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/llm/save"):
                return json(RemoteBoolValue(await services.configuration.saveLLMProfile(
                    try decode(LLMProfileUpdate.self, request.body))))
            case ("POST", "/api/v1/configuration/llm/add"):
                await services.configuration.addLLMProfile()
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/llm/remove"):
                let value = try decode(RemoteIntIDRequest.self, request.body)
                await services.configuration.removeLLMProfile(id: value.id)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/llm/move"):
                let value = try decode(RemoteMoveRequest.self, request.body)
                await services.configuration.moveLLMProfile(from: value.from, to: value.to)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/llm/test"):
                return json(await services.configuration.testLLMProfile(
                    try decode(LLMProfileUpdate.self, request.body)))
            case ("POST", "/api/v1/configuration/llm/models"):
                let value = try decode(RemoteLLMModelsRequest.self, request.body)
                return json(try await services.configuration.fetchLLMModels(
                    profileID: value.profileID, endpoint: value.endpoint, apiKey: value.apiKey))
            case ("POST", "/api/v1/configuration/dependency-path"):
                let value = try decode(RemoteDependencyPathRequest.self, request.body)
                await services.configuration.setDependencyPath(id: value.id, path: value.path)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/export-platforms"):
                await services.configuration.updateExportPlatforms(
                    try decode(ExportPlatformConfiguration.self, request.body))
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/configuration/ai-prompts"):
                await services.configuration.updateAIPrompts(
                    try decode(AIPromptConfiguration.self, request.body))
                return json(RemoteAcknowledgement())

            case ("GET", "/api/v1/maintenance"):
                return json(await services.maintenance.snapshot())
            case ("POST", "/api/v1/maintenance/policy"):
                await services.maintenance.updatePolicy(try decode(CleanupPolicy.self, request.body))
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/maintenance/cleanup"):
                return json(RemoteStringValue(await services.maintenance.runCleanup()))
            case ("POST", "/api/v1/maintenance/backup"):
                return json(await services.maintenance.createBackup())
            case ("POST", "/api/v1/maintenance/backup/restore"):
                let value = try decode(RemoteStringIDRequest.self, request.body)
                try await services.maintenance.restoreBackup(id: value.id)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/maintenance/trash/restore"):
                let value = try decode(RemoteStringIDRequest.self, request.body)
                return json(await services.maintenance.restoreTrash(id: value.id))
            case ("POST", "/api/v1/maintenance/trash/delete"):
                let value = try decode(RemoteStringIDRequest.self, request.body)
                await services.maintenance.deleteTrash(id: value.id)
                return json(RemoteAcknowledgement())
            case ("POST", "/api/v1/maintenance/trash/clear"):
                await services.maintenance.clearTrash()
                return json(RemoteAcknowledgement())
            default:
                return failure(404, "not_found", "接口不存在")
            }
        } catch let error as DecodingError {
            return failure(400, "invalid_request", String(describing: error))
        } catch {
            return failure(500, "operation_failed", error.localizedDescription)
        }
    }

    private func requiredScope(for request: ReadBoardHTTPRequest) -> RemoteAccessScope? {
        let path = request.path
        if path == "/api/v1/server/profile" { return nil }
        if path.hasPrefix("/api/v1/library/") || path.hasPrefix("/api/v1/content/") {
            return ["/api/v1/library/read", "/api/v1/library/star", "/api/v1/library/mark-read"]
                .contains(path) ? .updateReadingState : .readLibrary
        }
        if path.hasPrefix("/api/v1/processing/") {
            return path == "/api/v1/processing/capabilities" ? .manageOperations : .runProcessing
        }
        if path.hasPrefix("/api/v1/runtime/") || path.hasPrefix("/api/v1/admin/") {
            return path == "/api/v1/runtime/scan" ? .runProcessing : .manageOperations
        }
        if path.hasPrefix("/api/v1/sources/") || path.hasPrefix("/api/v1/onboarding/") {
            return .manageSources
        }
        if path.hasPrefix("/api/v1/auth/") { return .manageAuthentication }
        if path.hasPrefix("/api/v1/exports/") { return .manageExports }
        if path.hasPrefix("/api/v1/configuration") { return .manageConfiguration }
        if path.hasPrefix("/api/v1/maintenance") { return .manageMaintenance }
        return nil
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    private func json<T: Encodable>(_ value: T, status: Int = 200) -> ReadBoardHTTPResponse {
        do {
            return ReadBoardHTTPResponse(status: status,
                headers: ["content-type": "application/json; charset=utf-8",
                          ReadBoardAPI.versionHeader: ReadBoardAPI.version],
                body: try encoder.encode(value))
        } catch { return failure(500, "encoding_failed", "服务响应编码失败") }
    }

    private func failure(_ status: Int, _ code: String, _ message: String) -> ReadBoardHTTPResponse {
        let body = (try? encoder.encode(APIErrorBody(error: code, message: message))) ?? Data()
        return ReadBoardHTTPResponse(status: status,
            headers: ["content-type": "application/json; charset=utf-8",
                      ReadBoardAPI.versionHeader: ReadBoardAPI.version], body: body)
    }
}

public enum ReadBoardHTTPServerState: Sendable {
    case starting
    case ready
    case waiting(String)
    case failed(String)
    case stopped
}

/// 小型 HTTP/1.1 服务。默认绑定所有 IPv4 网卡；可在远程访问设置中切回仅本机。
public final class ReadBoardHTTPServer: @unchecked Sendable {
    private let router: ReadBoardHTTPRouter
    private let port: NWEndpoint.Port
    private let allowLAN: Bool
    private let stateHandler: @Sendable (ReadBoardHTTPServerState) -> Void
    private let queue = DispatchQueue(label: "readboard.http.server", qos: .utility)
    private var listener: NWListener?
    private let lock = NSLock()

    public init(services: ReadBoardServices, token: String, port: UInt16 = 7331,
                allowLAN: Bool = true,
                stateHandler: @escaping @Sendable (ReadBoardHTTPServerState) -> Void = { _ in }) {
        self.router = ReadBoardHTTPRouter(services: services, bearerToken: token)
        self.port = NWEndpoint.Port(rawValue: port) ?? 7331
        self.allowLAN = allowLAN
        self.stateHandler = stateHandler
    }

    init(services: ReadBoardServices, deviceStore: RemoteDeviceStore,
         pairingService: RemotePairingService, port: UInt16, allowLAN: Bool,
         stateHandler: @escaping @Sendable (ReadBoardHTTPServerState) -> Void) {
        self.router = ReadBoardHTTPRouter(services: services, deviceStore: deviceStore,
                                          pairingService: pairingService)
        self.port = NWEndpoint.Port(rawValue: port) ?? 7331
        self.allowLAN = allowLAN
        self.stateHandler = stateHandler
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        let host: NWEndpoint.Host = allowLAN ? "0.0.0.0" : "127.0.0.1"
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let value = try NWListener(using: parameters)
        value.newConnectionHandler = { [weak self] in self?.accept($0) }
        value.stateUpdateHandler = { [stateHandler] state in
            switch state {
            case .setup: stateHandler(.starting)
            case .ready: stateHandler(.ready)
            case .waiting(let error): stateHandler(.waiting(error.localizedDescription))
            case .failed(let error): stateHandler(.failed(error.localizedDescription))
            case .cancelled: stateHandler(.stopped)
            @unknown default: stateHandler(.waiting("未知网络状态"))
            }
        }
        value.start(queue: queue)
        listener = value
    }

    public func stop() {
        lock.lock(); let value = listener; listener = nil; lock.unlock()
        value?.cancel()
        stateHandler(.stopped)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > ReadBoardAPI.maximumRequestBytes + 16 * 1_024 {
                self.send(.init(status: 413), on: connection); return
            }
            if let request = self.parse(buffer) {
                Task { self.send(await self.router.handle(request), on: connection) }
            } else if complete || error != nil {
                self.send(.init(status: 400), on: connection)
            } else {
                self.receive(connection, accumulated: buffer)
            }
        }
    }

    private func parse(_ data: Data) -> ReadBoardHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestLine = first.split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return ReadBoardHTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
            headers: headers, body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func send(_ response: ReadBoardHTTPResponse, on connection: NWConnection) {
        let reason: String = switch response.status {
        case 200: "OK"; case 201: "Created"; case 400: "Bad Request"
        case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 410: "Gone"; case 413: "Payload Too Large"; case 426: "Upgrade Required"
        case 429: "Too Many Requests"; case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
        var headers = response.headers
        headers["content-length"] = String(response.body.count)
        headers["connection"] = "close"
        let text = "HTTP/1.1 \(response.status) \(reason)\r\n"
            + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        var bytes = Data(text.utf8); bytes.append(response.body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
