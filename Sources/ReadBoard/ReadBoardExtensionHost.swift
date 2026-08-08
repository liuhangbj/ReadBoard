import Foundation
import ReadBoardContract

public enum ReadBoardConnectorAuthenticationState: Sendable, Equatable {
    case notRequired
    case authenticated
    case repairing(String)
    case needsAttention(String)
}

/// 付费模块和后续平台适配器向公开核心交付统一内容的最小协议。
/// 平台登录态、请求签名、反爬和正文提取均由适配器自己负责。
public protocol ReadBoardSourceConnector: Sendable {
    var sourceType: String { get }

    var displayName: String { get }
    var requiresEntitlement: Bool { get }

    var proHintTitle: String { get }
    var proHintMessage: String { get }
    var fulltextMode: FetchMode { get }
    var fulltextDisplayName: String { get }
    /// 问题中心用于定位 Pro 模块设置页；nil 表示没有独立设置页。
    var settingsModuleIdentifier: String? { get }
    /// 批量同步同一平台多个源时的最小请求间隔，避免触发平台风控。
    var minimumFetchSpacing: TimeInterval { get }

    func resolveSourceIdentifier(_ input: String) async throws -> String?
    func previewSource(identifier: String) async throws -> ParsedFeed

    func fetch(
        identifier: String,
        configuration: String
    ) async throws -> ParsedFeed

    /// 仅对核心尚未入库的新条目调用。适配器可在这里解析最终链接并提取正文，
    /// 避免每轮同步重复下载已经存在的历史文章。
    func prepareForImport(_ entry: ParsedEntry) async throws -> ParsedEntry

    /// 仅在公开核心确认条目是首次入库后调用，避免同步时反复下载历史全文。
    func contentMarkdown(for entry: ParsedEntry) async throws -> String?

    /// 只做轻量本地状态判断，不应为了刷新问题中心频繁访问平台接口。
    func authenticationState() async -> ReadBoardConnectorAuthenticationState

    /// 可选的统一扫码授权入口。适配器内部持有平台临时凭证；中间层只传递不透明 challengeID。
    func beginAuthentication() async throws -> PlatformAuthenticationChallenge
    func pollAuthentication(challengeID: String) async throws -> PlatformAuthenticationPoll
    func signOut() async throws

    /// 某错误意味着继续抓同平台其余源只会制造重复失败时，暂停本轮该平台。
    func shouldPauseBatch(after error: Error) -> Bool
}

public extension ReadBoardSourceConnector {
    var displayName: String { sourceType }
    var requiresEntitlement: Bool { true }
    var proHintTitle: String { "Pro 功能" }
    var proHintMessage: String { "请升级 Pro 版本后使用 \(displayName)。" }
    var fulltextMode: FetchMode { .externalFulltext }
    var fulltextDisplayName: String { fulltextMode.displayName }
    var settingsModuleIdentifier: String? { nil }
    var minimumFetchSpacing: TimeInterval { 0 }

    func resolveSourceIdentifier(_ input: String) async throws -> String? { nil }

    func previewSource(identifier: String) async throws -> ParsedFeed {
        try await fetch(identifier: identifier, configuration: "{}")
    }

    func prepareForImport(_ entry: ParsedEntry) async throws -> ParsedEntry { entry }

    func contentMarkdown(for entry: ParsedEntry) async throws -> String? {
        entry.contentMarkdown
    }

    func authenticationState() async -> ReadBoardConnectorAuthenticationState { .notRequired }
    func beginAuthentication() async throws -> PlatformAuthenticationChallenge {
        throw ReadBoardConnectorError.authenticationNotSupported
    }
    func pollAuthentication(challengeID: String) async throws -> PlatformAuthenticationPoll {
        throw ReadBoardConnectorError.authenticationNotSupported
    }
    func signOut() async throws { throw ReadBoardConnectorError.authenticationNotSupported }
    func shouldPauseBatch(after error: Error) -> Bool { false }
}

public enum ReadBoardConnectorError: LocalizedError {
    case authenticationNotSupported

    public var errorDescription: String? { "此平台不支持统一授权操作" }
}

/// 运行期适配器注册表。限制在 MainActor，避免同步任务与模块生命周期之间出现竞态。
@MainActor
public final class ReadBoardSourceConnectorRegistry {
    public static let shared = ReadBoardSourceConnectorRegistry()

    private var connectors: [String: any ReadBoardSourceConnector] = [:]

    private init() {}

    public func register(_ connector: any ReadBoardSourceConnector) {
        connectors[connector.sourceType] = connector
    }

    public func unregister(sourceType: String) {
        connectors.removeValue(forKey: sourceType)
    }

    public func connector(for sourceType: String) -> (any ReadBoardSourceConnector)? {
        connectors[sourceType]
    }

    public func connectorsSupportingAddSource() -> [any ReadBoardSourceConnector] {
        connectors.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// Pro 模块可调用的窄宿主接口。它有意不暴露 Database 或 SourceStore，
/// 从而让私有模块只增加能力，不复制也不穿透公开版的内部数据层。
@MainActor
public enum ReadBoardExtensionHost {
    public static func register(_ connector: any ReadBoardSourceConnector) {
        ReadBoardSourceConnectorRegistry.shared.register(connector)
        SourceStore.shared.repairExternalFetchModes()
    }

    public static func unregister(sourceType: String) {
        ReadBoardSourceConnectorRegistry.shared.unregister(sourceType: sourceType)
    }

    public static func sourceExists(identifier: String) -> Bool {
        SourceStore.shared.existsByIdentifier(identifier)
    }

    @discardableResult
    public static func addSource(
        sourceType: String,
        name: String,
        identifier: String,
        autoScore: Bool = false,
        autoTranslate: Bool = false,
        autoSummarize: Bool = false,
        autoTranscribe: Bool = false,
        refreshImmediately: Bool = true
    ) async throws -> Int64 {
        let policy = PipelinePolicy(
            autoScore: autoScore,
            autoTranslate: autoTranslate,
            autoTranscribe: autoTranscribe,
            autoSummarize: autoSummarize
        )
        guard let sourceID = await SourceStore.shared.addSource(
            stype: sourceType,
            name: name,
            identifier: identifier,
            pipeline: policy,
            fetchMode: ReadBoardSourceConnectorRegistry.shared.connector(for: sourceType)?.fulltextMode
                ?? .summary
        ) else {
            throw ReadBoardExtensionHostError.sourceInsertFailed
        }
        if refreshImmediately {
            guard let source = SourceStore.shared.sources.first(where: { $0.id == sourceID }) else {
                throw ReadBoardExtensionHostError.sourceNotFound
            }
            _ = try await SourceStore.shared.syncOne(source)
        }
        return sourceID
    }

    @discardableResult
    public static func refreshSource(identifier: String) async throws -> Int {
        guard let source = SourceStore.shared.sources.first(where: { $0.identifier == identifier }) else {
            throw ReadBoardExtensionHostError.sourceNotFound
        }
        return try await SourceStore.shared.syncOne(source)
    }

    /// 对某个外部平台已入库的 Markdown 做一次安全修复。数据库仍由公开核心管理；
    /// 模块只提供纯文本转换函数，不直接触碰 content 表。
    /// - Returns: 实际修改的条目数。
    @discardableResult
    public static func cleanExternalContentMarkdown(
        sourceType: String,
        transform: @Sendable (String) -> String
    ) -> Int {
        let rows = Database.shared.queryRows("""
            SELECT id, content_md FROM content
            WHERE source = ? AND content_md IS NOT NULL AND TRIM(content_md) != '' AND deleted_at IS NULL
            """, params: [sourceType])
        var changed = 0
        for row in rows {
            guard let id = Int64(row["id"] ?? ""), let markdown = row["content_md"] else { continue }
            let cleaned = transform(markdown)
            guard cleaned != markdown else { continue }
            if Database.shared.execute(
                "UPDATE content SET content_md = ?, updated_at = datetime('now') WHERE id = ?",
                params: [cleaned, id]
            ) {
                changed += 1
            }
        }
        if changed > 0 {
            NotificationCenter.default.post(name: .contentUpdated, object: nil)
        }
        return changed
    }
}

public enum ReadBoardExtensionHostError: LocalizedError, Sendable {
    case sourceInsertFailed
    case sourceNotFound

    public var errorDescription: String? {
        switch self {
        case .sourceInsertFailed: return "订阅源写入失败或已经存在"
        case .sourceNotFound: return "订阅源不存在"
        }
    }
}
