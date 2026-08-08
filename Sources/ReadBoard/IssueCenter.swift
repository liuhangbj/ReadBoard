import Foundation
import SwiftUI

enum AppIssueCategory: String, CaseIterable, Sendable {
    case sources = "源抓取"
    case authorization = "平台授权"
    case processing = "内容处理"
    case export = "导出"

    var icon: String {
        switch self {
        case .sources: "dot.radiowaves.left.and.right"
        case .authorization: "person.badge.key"
        case .processing: "gearshape.2"
        case .export: "square.and.arrow.up"
        }
    }
}

enum AppIssueSeverity: Int, Comparable, Sendable {
    case repairing = 1
    case needsAttention = 2

    static func < (lhs: AppIssueSeverity, rhs: AppIssueSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum AppIssueAction: Sendable, Equatable {
    case sourceFailures
    case contentFailures
    case fulltextFailures
    case dashboard
    case settings(SettingsRoute)
}

struct AppIssue: Identifiable, Sendable, Equatable {
    let id: String
    let category: AppIssueCategory
    let severity: AppIssueSeverity
    let title: String
    let detail: String
    let affectedCount: Int
    let actionTitle: String?
    let action: AppIssueAction?
}

enum AppHealthStatus: Sendable, Equatable {
    case healthy
    case repairing
    case needsAttention
}

private struct LocalIssueSnapshot: Sendable {
    let issues: [AppIssue]
    let sourceTypes: Set<String>
}

private final class IssueHealthService: @unchecked Sendable {
    static let shared = IssueHealthService()
    private let db = Database.shared
    private init() {}

    func snapshot(isSourceRepairing: Bool) -> LocalIssueSnapshot {
        _ = db.open()
        var issues: [AppIssue] = []
        let sourceRows = db.queryRows("""
            SELECT stype, error, last_fetched_at
            FROM content_source
            WHERE enabled=1;
            """)
        let sourceTypes = Set(sourceRows.compactMap { $0["stype"] })
        var sourceFailures: [String: [(error: String, lastFetchedAt: String?)]] = [:]
        var staleWithoutError: [String: Int] = [:]
        let now = Date()

        for row in sourceRows {
            let type = row["stype"] ?? "rss"
            let error = row["error"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !error.isEmpty {
                sourceFailures[type, default: []].append((error, row["last_fetched_at"]))
            } else if isStale(row["last_fetched_at"], now: now) {
                staleWithoutError[type, default: 0] += 1
            }
        }

        // 微信 499 在当前接口中代表公众号授权/访问凭据失效。按根因合并，避免 145 条重复提示。
        if let failures = sourceFailures["wechat"] {
            let authenticationFailures = failures.filter { $0.error.contains("499") }
            if !authenticationFailures.isEmpty {
                issues.append(AppIssue(
                    id: "authorization.wechat.499",
                    category: .authorization,
                    severity: isSourceRepairing ? .repairing : .needsAttention,
                    title: isSourceRepairing ? "正在修复微信授权" : "微信授权已失效",
                    detail: isSourceRepairing
                        ? "正在自动续期并重试受影响的公众号。"
                        : "自动续期未能恢复公众号访问，需要重新扫码登录。",
                    affectedCount: authenticationFailures.count,
                    actionTitle: isSourceRepairing ? nil : "打开微信设置",
                    action: isSourceRepairing ? nil : .settings(.module("com.liuhangbj.readboard.pro.wechat"))))
                sourceFailures["wechat"] = failures.filter { !$0.error.contains("499") }
            }
        }

        for (type, failures) in sourceFailures where !failures.isEmpty {
            let needsAttention = failures.contains { isStale($0.lastFetchedAt, now: now) }
            let severity: AppIssueSeverity = (isSourceRepairing || !needsAttention)
                ? .repairing : .needsAttention
            issues.append(AppIssue(
                id: "sources.\(type).failed",
                category: .sources,
                severity: severity,
                title: "\(platformName(type))抓取异常",
                detail: severity == .repairing
                    ? "系统将在下一轮自动重试。最近错误：\(failures[0].error)"
                    : "持续未能成功更新。最近错误：\(failures[0].error)",
                affectedCount: failures.count,
                actionTitle: "查看并重试",
                action: .sourceFailures))
        }

        for (type, count) in staleWithoutError where count > 0 {
            issues.append(AppIssue(
                id: "sources.\(type).stale",
                category: .sources,
                severity: isSourceRepairing ? .repairing : .needsAttention,
                title: "\(platformName(type))长期未更新",
                detail: "超过 48 小时没有成功抓取记录。",
                affectedCount: count,
                actionTitle: "查看并重试",
                action: .sourceFailures))
        }

        let paused = FailedJobService.shared.pausedFailures()
        if !paused.isEmpty {
            issues.append(AppIssue(
                id: "processing.deadletters",
                category: .processing,
                severity: .needsAttention,
                title: "自动内容处理已暂停",
                detail: "连续失败三次的目标需要重试或永久忽略。",
                affectedCount: paused.count,
                actionTitle: "查看处理项",
                action: .contentFailures))
        }

        let externalFulltext = db.queryRows("""
            SELECT COUNT(*) AS failures,
                   SUM(CASE WHEN c.updated_at <= datetime('now', '-24 hours') THEN 1 ELSE 0 END) AS persistent
            FROM content c
            WHERE c.fetch_status=3
              AND c.deleted_at IS NULL
              AND c.is_duplicate=0
              AND c.fetch_engine LIKE '%_connector';
            """).first
        let externalFailures = Int(externalFulltext?["failures"] ?? "0") ?? 0
        let persistentFailures = Int(externalFulltext?["persistent"] ?? "0") ?? 0
        if externalFailures > 0 {
            issues.append(AppIssue(
                id: "processing.external-fulltext",
                category: .processing,
                severity: persistentFailures > 0 ? .needsAttention : .repairing,
                title: "正文提取失败",
                detail: persistentFailures > 0
                    ? "源列表已更新成功；部分单篇正文持续无法获取。"
                    : "源列表已更新成功，系统稍后自动补抓这些单篇正文。",
                affectedCount: externalFailures,
                actionTitle: "查看并重试",
                action: .fulltextFailures))
        }

        let exportFailure = db.queryRows("""
            SELECT COUNT(*) AS failures, COUNT(DISTINCT er.rule_id) AS rules
            FROM export_record er
            JOIN export_rule r ON r.id=er.rule_id AND r.revision=er.revision
            WHERE r.enabled=1 AND er.status='failed';
            """).first
        let exportFailures = Int(exportFailure?["failures"] ?? "0") ?? 0
        let exportRules = Int(exportFailure?["rules"] ?? "0") ?? 0
        if exportFailures > 0 {
            issues.append(AppIssue(
                id: "export.failed",
                category: .export,
                severity: .needsAttention,
                title: "导出任务失败",
                detail: "\(exportRules) 条启用规则存在失败记录，请检查目标配置或权限。",
                affectedCount: exportFailures,
                actionTitle: "打开导出规则",
                action: .settings(.page(.pipeline))))
        }

        return LocalIssueSnapshot(issues: issues, sourceTypes: sourceTypes)
    }

    private func isStale(_ raw: String?, now: Date) -> Bool {
        guard let raw, !raw.isEmpty else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: raw) else { return true }
        return now.timeIntervalSince(date) > 48 * 3600
    }

    private func platformName(_ type: String) -> String {
        switch type {
        case "wechat": "微信公众号"
        case "bilibili": "B站"
        case "youtube": "YouTube"
        case "podcast": "播客"
        case "rss": "RSS"
        default: type
        }
    }
}

@MainActor
final class IssueCenterStore: ObservableObject {
    @Published private(set) var issues: [AppIssue] = []
    @Published private(set) var isRefreshing = false

    var status: AppHealthStatus {
        if issues.contains(where: { $0.severity == .needsAttention }) { return .needsAttention }
        if issues.contains(where: { $0.severity == .repairing }) { return .repairing }
        return .healthy
    }

    var statusText: String {
        switch status {
        case .healthy: "运行正常"
        case .repairing: "正在自动修复"
        case .needsAttention: "需要处理"
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let sourceRepairing = SourceStore.shared.isSyncing || SourceStore.shared.isExternalSyncing
        let local = await Task.detached(priority: .utility) {
            IssueHealthService.shared.snapshot(isSourceRepairing: sourceRepairing)
        }.value
        var combined = local.issues

        for connector in ReadBoardSourceConnectorRegistry.shared.connectorsSupportingAddSource()
        where local.sourceTypes.contains(connector.sourceType) {
            switch await connector.authenticationState() {
            case .notRequired:
                break
            case .authenticated:
                // 重新扫码或自动续期成功后，库中尚未逐源重抓清掉的旧 499
                // 不再代表当前授权状态；若下一次请求仍失败，连接器会转为 needsAttention。
                combined.removeAll { $0.id == "authorization.\(connector.sourceType).499" }
            case .repairing(let message):
                combined.removeAll { $0.id == "authorization.\(connector.sourceType).499" }
                combined.append(authenticationIssue(
                    connector: connector, severity: .repairing,
                    title: "正在修复\(connector.displayName)授权", message: message))
            case .needsAttention(let message):
                combined.removeAll { $0.id == "authorization.\(connector.sourceType).499" }
                combined.append(authenticationIssue(
                    connector: connector, severity: .needsAttention,
                    title: "\(connector.displayName)需要重新授权", message: message))
            }
        }

        let manualFailures = ContentProcessingStateStore.shared.dashboardEntries.filter {
            $0.phase == .failed
        }
        if !manualFailures.isEmpty {
            combined.append(AppIssue(
                id: "processing.manual",
                category: .processing,
                severity: .needsAttention,
                title: "手动内容处理失败",
                detail: "可在数据看板查看失败原因后重新执行。",
                affectedCount: manualFailures.count,
                actionTitle: "打开数据看板",
                action: .dashboard))
        }

        let pending = PipelineWorker.shared.pendingBreakdown
        if pending.score + pending.translate + pending.summarize > 0,
           !LLMPipeline().isAvailable {
            combined.append(AppIssue(
                id: "processing.llm.missing",
                category: .processing,
                severity: .needsAttention,
                title: "LLM 尚未配置",
                detail: "存在等待评分、摘要或翻译的内容，但没有可用的模型配置。",
                affectedCount: pending.score + pending.translate + pending.summarize,
                actionTitle: "打开 LLM 设置",
                action: .settings(.page(.llm))))
        }
        if pending.transcribe > 0, !DependencyChecker.shared.transcribeReady {
            combined.append(AppIssue(
                id: "processing.transcription.dependencies",
                category: .processing,
                severity: .needsAttention,
                title: "转录依赖不完整",
                detail: "Whisper、ffmpeg、yt-dlp 或模型文件缺失。",
                affectedCount: pending.transcribe,
                actionTitle: "打开依赖设置",
                action: .settings(.page(.deps))))
        }

        issues = combined.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.category != $1.category {
                return AppIssueCategory.allCases.firstIndex(of: $0.category)!
                    < AppIssueCategory.allCases.firstIndex(of: $1.category)!
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        isRefreshing = false
    }

    private func authenticationIssue(
        connector: any ReadBoardSourceConnector,
        severity: AppIssueSeverity,
        title: String,
        message: String
    ) -> AppIssue {
        let route = connector.settingsModuleIdentifier.map { SettingsRoute.module($0) }
            ?? .page(.sources)
        return AppIssue(
            id: "authorization.\(connector.sourceType)",
            category: .authorization,
            severity: severity,
            title: title,
            detail: message,
            affectedCount: 1,
            actionTitle: severity == .needsAttention ? "打开设置" : nil,
            action: severity == .needsAttention ? .settings(route) : nil)
    }
}

struct IssueCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: IssueCenterStore
    let onOpenSettings: (SettingsRoute) -> Void
    let onOpenDashboard: () -> Void
    @State private var showSourceFailures = false
    @State private var showContentFailures = false
    @State private var showFulltextFailures = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("问题中心").font(.headline)
                    Text(store.statusText).font(.caption).foregroundStyle(Color.rbText3)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.quiet)
                Button("关闭") { dismiss() }.buttonStyle(.quiet)
            }
            .padding(16)

            Hairline()

            if store.issues.isEmpty {
                ContentUnavailableView(
                    "全部正常", systemImage: "checkmark.circle.fill",
                    description: Text("源抓取、平台授权、内容处理和导出均未发现问题。"))
                    .foregroundStyle(Color.rbScoreHigh)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(AppIssueCategory.allCases, id: \.self) { category in
                        let sectionIssues = store.issues.filter { $0.category == category }
                        if !sectionIssues.isEmpty {
                            Section {
                                ForEach(sectionIssues) { issue in issueRow(issue) }
                            } header: {
                                Label(category.rawValue, systemImage: category.icon)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 760, height: 560)
        .task { await store.refresh() }
        .sheet(isPresented: $showSourceFailures) { SourceFailureListSheet() }
        .sheet(isPresented: $showContentFailures) { ContentFailureListSheet() }
        .sheet(isPresented: $showFulltextFailures) { ExternalFullTextFailureListSheet() }
    }

    private func issueRow(_ issue: AppIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.severity == .needsAttention
                  ? "exclamationmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(issueColor(issue))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(issue.title).font(.system(size: 13, weight: .semibold))
                    if issue.affectedCount > 1 {
                        Text("\(issue.affectedCount) 项")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(issueColor(issue).opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                    .lineLimit(3)
            }
            Spacer(minLength: 12)
            if let title = issue.actionTitle, issue.action != nil {
                Button(title) { perform(issue.action) }
                    .buttonStyle(.quiet).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func perform(_ action: AppIssueAction?) {
        switch action {
        case .sourceFailures: showSourceFailures = true
        case .contentFailures: showContentFailures = true
        case .fulltextFailures: showFulltextFailures = true
        case .dashboard: dismiss(); onOpenDashboard()
        case .settings(let route): dismiss(); onOpenSettings(route)
        case nil: break
        }
    }

    private var statusColor: Color {
        switch store.status {
        case .healthy: .rbScoreHigh
        case .repairing: .rbScoreMid
        case .needsAttention: .rbScoreLow
        }
    }

    private func issueColor(_ issue: AppIssue) -> Color {
        issue.severity == .needsAttention ? .rbScoreLow : .rbScoreMid
    }
}
