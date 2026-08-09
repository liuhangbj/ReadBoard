import Foundation
import Observation
import ReadBoardContract

@MainActor
@Observable
public final class ReadBoardOperationsFeatureModel {
    public private(set) var runtime = RuntimeStatusSnapshot()
    public private(set) var authentications: [PlatformAuthenticationStatus] = []
    public private(set) var problemCounts = OperationalProblemCounts()
    public private(set) var processingFailures: [ContentProcessingFailure] = []
    public private(set) var fullTextFailures: [FullTextFailure] = []
    public private(set) var isLoading = false
    public private(set) var activeOperations: Set<String> = []
    public private(set) var authenticationChallenge: PlatformAuthenticationChallenge?
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?

    private let environment: ReadBoardFeatureEnvironment

    public init(environment: ReadBoardFeatureEnvironment) {
        self.environment = environment
    }

    public var permissions: ReadBoardFeaturePermissions { environment.permissions }

    public func clearStatus() { statusMessage = nil }
    public func clearError() { errorMessage = nil }
    public func dismissAuthentication() { authenticationChallenge = nil }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        async let runtime = environment.runtimeStatus.snapshot(refreshCounts: true)
        async let auth = environment.authentication.statuses()
        async let counts = environment.administration.operationalProblemCounts()
        async let failures = environment.administration.processingFailures()
        async let fulltext = environment.administration.fullTextFailures(limit: 100)
        self.runtime = await runtime
        authentications = await auth
        problemCounts = await counts
        processingFailures = await failures
        fullTextFailures = await fulltext
    }

    public func runProcessingScan() async {
        guard begin("scan") else { return }
        defer { finish("scan") }
        await environment.runtimeStatus.runProcessingScan()
        statusMessage = "已开始扫描处理目标"
        await load()
    }

    public func retryProcessingFailure(id: Int64) async {
        guard begin("retry:\(id)") else { return }
        defer { finish("retry:\(id)") }
        if await environment.administration.retryProcessingFailure(id: id) {
            statusMessage = "失败任务已重新加入队列"
            await load()
        } else {
            errorMessage = "任务重试失败"
        }
    }

    public func ignoreProcessingFailure(id: Int64) async {
        guard begin("ignore:\(id)") else { return }
        defer { finish("ignore:\(id)") }
        if await environment.administration.ignoreProcessingFailure(id: id) {
            statusMessage = "已忽略；以后不再进入目标检查"
            await load()
        } else {
            errorMessage = "无法忽略这个任务"
        }
    }

    public func retryFullText(contentID: Int64) async {
        guard begin("fulltext:\(contentID)") else { return }
        defer { finish("fulltext:\(contentID)") }
        do {
            let result = try await environment.sourceManagement.retryFulltext(contentID: contentID)
            statusMessage = result.message
            await load()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func beginAuthentication(platformID: String) async {
        guard begin("auth:\(platformID)") else { return }
        defer { finish("auth:\(platformID)") }
        do {
            authenticationChallenge = try await environment.authentication
                .beginAuthentication(platformID: platformID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func pollAuthentication() async -> Bool {
        guard let challenge = authenticationChallenge else { return false }
        do {
            let result = try await environment.authentication.pollAuthentication(
                platformID: challenge.platformID,
                challengeID: challenge.challengeID)
            if result.completed {
                authenticationChallenge = nil
                statusMessage = "\(result.status.displayName)登录状态已更新"
                await load()
            }
            return result.completed
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func signOut(platformID: String) async {
        guard begin("signout:\(platformID)") else { return }
        defer { finish("signout:\(platformID)") }
        do {
            try await environment.authentication.signOut(platformID: platformID)
            statusMessage = "已退出平台登录"
            await load()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func begin(_ key: String) -> Bool {
        guard !activeOperations.contains(key) else { return false }
        activeOperations.insert(key)
        errorMessage = nil
        return true
    }

    private func finish(_ key: String) { activeOperations.remove(key) }
}

public enum ReadBoardServiceHealthPhase: Equatable, Sendable {
    case healthy
    case repairing
    case needsAttention
}

public struct ReadBoardServiceHealthSummary: Equatable, Sendable {
    public let phase: ReadBoardServiceHealthPhase
    public let issueCount: Int
    public let message: String

    public init(
        runtime: RuntimeStatusSnapshot,
        authentications: [PlatformAuthenticationStatus],
        problems: OperationalProblemCounts,
        sourceIssues: Int = 0
    ) {
        let manualAuth = authentications.filter {
            [.needsAttention, .signedOut, .expired].contains($0.phase)
        }.count
        let repairingAuth = authentications.filter {
            [.waitingForScan, .waitingForConfirmation, .repairing].contains($0.phase)
        }.count
        let manualProblems = problems.persistentFullTextFailures
            + problems.exportFailures
            + runtime.pausedFailureCount
            + manualAuth
            + sourceIssues
        if manualProblems > 0 {
            phase = .needsAttention
            issueCount = manualProblems
            message = "有 \(manualProblems) 项需要手动处理"
        } else if runtime.isRunning || repairingAuth > 0 || problems.fullTextFailures > 0 {
            phase = .repairing
            issueCount = repairingAuth + problems.fullTextFailures
            message = "系统正在自动处理问题"
        } else {
            phase = .healthy
            issueCount = 0
            message = "所有服务运行正常"
        }
    }
}

@MainActor
@Observable
public final class ReadBoardServiceHealthMonitorModel {
    public private(set) var summary = ReadBoardServiceHealthSummary(
        runtime: RuntimeStatusSnapshot(),
        authentications: [],
        problems: OperationalProblemCounts())

    private let environment: ReadBoardFeatureEnvironment

    public init(environment: ReadBoardFeatureEnvironment) {
        self.environment = environment
    }

    public func load() async {
        async let runtime = environment.runtimeStatus.snapshot(refreshCounts: false)
        async let auth = environment.authentication.statuses()
        async let problems = environment.administration.operationalProblemCounts()
        async let catalog = try? environment.sourceCatalog.snapshot()
        let sourceIssues = await catalog?.sources.filter { $0.hasError || $0.isStale }.count ?? 0
        summary = await ReadBoardServiceHealthSummary(
            runtime: runtime,
            authentications: auth,
            problems: problems,
            sourceIssues: sourceIssues)
    }
}
