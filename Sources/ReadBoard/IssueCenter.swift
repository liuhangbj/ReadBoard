import Foundation
import SwiftUI
import ReadBoardContract

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
    private init() {}

    func snapshot(
        sourceCatalog: SourceCatalogSnapshot,
        runtimeStatus: RuntimeStatusSnapshot,
        problemCounts: OperationalProblemCounts
    ) -> LocalIssueSnapshot {
        var issues: [AppIssue] = []
        let enabledSources = sourceCatalog.sources.filter(\.enabled)
        let sourceTypes = Set(enabledSources.map(\.sourceType))
        var sourceFailures: [String: [(error: String, lastFetchedAt: String?)]] = [:]
        var staleWithoutError: [String: Int] = [:]
        let now = Date()
        let isSourceRepairing = sourceCatalog.isSyncing || sourceCatalog.isExternalSyncing

        for source in enabledSources {
            let type = source.sourceType
            let error = source.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !error.isEmpty {
                sourceFailures[type, default: []].append((error, source.lastFetchedAt))
            } else if isStale(source.lastFetchedAt, now: now) {
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

        if runtimeStatus.pausedFailureCount > 0 {
            issues.append(AppIssue(
                id: "processing.deadletters",
                category: .processing,
                severity: .needsAttention,
                title: "自动内容处理已暂停",
                detail: "连续失败三次的目标需要重试或永久忽略。",
                affectedCount: runtimeStatus.pausedFailureCount,
                actionTitle: "查看处理项",
                action: .contentFailures))
        }

        let externalFailures = problemCounts.fullTextFailures
        let persistentFailures = problemCounts.persistentFullTextFailures
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

        let exportFailures = problemCounts.exportFailures
        let exportRules = problemCounts.affectedExportRules
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
    private let sourceCatalog: any SourceCatalogGateway
    private let runtimeStatus: any RuntimeStatusGateway
    private let administration: any AdministrationGateway
    private let authentication: any AuthenticationGateway
    private let configuration: any ConfigurationGateway

    init(
        sourceCatalog: any SourceCatalogGateway = LocalSourceCatalogGateway(),
        runtimeStatus: any RuntimeStatusGateway = LocalRuntimeStatusGateway(),
        administration: any AdministrationGateway = LocalAdministrationGateway(),
        authentication: any AuthenticationGateway = LocalAuthenticationGateway(),
        configuration: any ConfigurationGateway = LocalConfigurationGateway()
    ) {
        self.sourceCatalog = sourceCatalog
        self.runtimeStatus = runtimeStatus
        self.administration = administration
        self.authentication = authentication
        self.configuration = configuration
    }

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
        async let catalogValue = try? sourceCatalog.snapshot()
        async let runtimeValue = runtimeStatus.snapshot(refreshCounts: false)
        async let problemValue = administration.operationalProblemCounts()
        async let authenticationValue = authentication.statuses()
        async let configurationValue = configuration.snapshot()
        let catalog = await catalogValue ?? SourceCatalogSnapshot()
        let runtime = await runtimeValue
        let problems = await problemValue
        let authStatuses = await authenticationValue
        let serviceConfiguration = await configurationValue
        let local = await Task.detached(priority: .utility) {
            IssueHealthService.shared.snapshot(
                sourceCatalog: catalog,
                runtimeStatus: runtime,
                problemCounts: problems)
        }.value
        var combined = local.issues

        for status in authStatuses where local.sourceTypes.contains(status.platformID) {
            switch status.phase {
            case .notRequired:
                break
            case .authenticated:
                // 重新扫码或自动续期成功后，库中尚未逐源重抓清掉的旧 499
                // 不再代表当前授权状态；若下一次请求仍失败，连接器会转为 needsAttention。
                combined.removeAll { $0.id == "authorization.\(status.platformID).499" }
            case .repairing:
                combined.removeAll { $0.id == "authorization.\(status.platformID).499" }
                combined.append(authenticationIssue(status: status, severity: .repairing,
                    title: "正在修复\(status.displayName)授权"))
            case .needsAttention, .signedOut, .expired:
                combined.removeAll { $0.id == "authorization.\(status.platformID).499" }
                combined.append(authenticationIssue(status: status, severity: .needsAttention,
                    title: "\(status.displayName)需要重新授权"))
            case .waitingForScan, .waitingForConfirmation:
                break
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

        let pending = runtime.queue
        if pending.score + pending.translate + pending.summarize > 0,
           !serviceConfiguration.llmProfiles.contains(where: { $0.hasAPIKey && !$0.model.isEmpty }) {
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
        let transcribeDependencyIDs = Set(["whisperCLI", "ffmpeg", "ytdlp", "whisperModel"])
        if pending.transcribe > 0,
           serviceConfiguration.dependencies.contains(where: {
               transcribeDependencyIDs.contains($0.id) && !$0.installed
           }) {
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
        status: PlatformAuthenticationStatus,
        severity: AppIssueSeverity,
        title: String
    ) -> AppIssue {
        let route = status.settingsModuleIdentifier.map { SettingsRoute.module($0) }
            ?? .page(.sources)
        return AppIssue(
            id: "authorization.\(status.platformID)",
            category: .authorization,
            severity: severity,
            title: title,
            detail: status.message ?? "平台授权不可用。",
            affectedCount: 1,
            actionTitle: severity == .needsAttention ? "打开设置" : nil,
            action: severity == .needsAttention ? .settings(route) : nil)
    }
}

struct IssueCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: IssueCenterStore
    let sourceCatalog: any SourceCatalogGateway
    let sourceManagement: any SourceManagementGateway
    let runtimeStatus: any RuntimeStatusGateway
    let administration: any AdministrationGateway
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
        .sheet(isPresented: $showSourceFailures) {
            SourceFailureListSheet(
                sourceCatalog: sourceCatalog,
                sourceManagement: sourceManagement)
        }
        .sheet(isPresented: $showContentFailures) {
            ContentFailureListSheet(runtimeStatus: runtimeStatus, administration: administration)
        }
        .sheet(isPresented: $showFulltextFailures) {
            ExternalFullTextFailureListSheet(sourceManagement: sourceManagement,
                                             administration: administration)
        }
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
