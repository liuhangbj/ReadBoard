import Observation
import ReadBoardContract
import ReadBoardUI
import SwiftUI

public enum ReadBoardIssueCategory: String, CaseIterable, Sendable {
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

public enum ReadBoardIssueSeverity: Int, Comparable, Sendable {
    case repairing = 1
    case needsAttention = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ReadBoardIssueAction: Equatable, Sendable {
    case openSources
    case openOperations
    case openSettings(ReadBoardSettingsRoute)
}

public struct ReadBoardIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: ReadBoardIssueCategory
    public let severity: ReadBoardIssueSeverity
    public let title: String
    public let detail: String
    public let affectedCount: Int
    public let actionTitle: String?
    public let action: ReadBoardIssueAction?
}

@MainActor
@Observable
public final class ReadBoardIssueCenterModel {
    public private(set) var issues: [ReadBoardIssue] = []
    public private(set) var isRefreshing = false
    private let environment: ReadBoardFeatureEnvironment

    public init(environment: ReadBoardFeatureEnvironment) { self.environment = environment }

    public var status: ReadBoardServiceHealthPhase {
        if issues.contains(where: { $0.severity == .needsAttention }) { return .needsAttention }
        if issues.contains(where: { $0.severity == .repairing }) { return .repairing }
        return .healthy
    }

    public var statusText: String {
        switch status {
        case .healthy: "运行正常"
        case .repairing: "正在自动修复"
        case .needsAttention: "需要处理"
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let catalogValue = try? environment.sourceCatalog.snapshot()
        async let runtimeValue = try? environment.runtimeStatus.snapshot(refreshCounts: false)
        async let problemValue = try? environment.administration.operationalProblemCounts()
        async let authenticationValue = try? environment.authentication.statuses()
        async let configurationValue = try? environment.configuration.snapshot()
        let values = await (catalogValue, runtimeValue, problemValue,
                            authenticationValue, configurationValue)
        guard let catalog = values.0, let runtime = values.1, let problems = values.2,
              let authentications = values.3, let configuration = values.4 else {
            issues = [ReadBoardIssue(
                id: "service.unavailable", category: .sources, severity: .needsAttention,
                title: "无法获取服务状态", detail: "当前无法连接 ReadBoard 服务端，请检查网络或连接设置。",
                affectedCount: 1, actionTitle: nil, action: nil)]
            return
        }

        var result: [ReadBoardIssue] = []
        let sources = catalog.sources.filter(\.enabled)
        let activeTypes = Set(sources.map(\.sourceType))
        let repairing = catalog.isSyncing || catalog.isExternalSyncing

        for group in Dictionary(grouping: sources.filter { $0.hasError || $0.isStale }, by: \.sourceType) {
            let failures = group.value
            result.append(ReadBoardIssue(
                id: "sources.\(group.key)", category: .sources,
                severity: repairing ? .repairing : .needsAttention,
                title: "\(platformName(group.key))抓取异常",
                detail: repairing ? "系统正在自动重试。" : (failures.first?.error ?? "超过 48 小时没有成功更新记录。"),
                affectedCount: failures.count,
                actionTitle: "查看订阅源", action: .openSources))
        }

        for auth in authentications where activeTypes.contains(auth.platformID) {
            let severity: ReadBoardIssueSeverity?
            switch auth.phase {
            case .repairing: severity = .repairing
            case .needsAttention, .signedOut, .expired: severity = .needsAttention
            default: severity = nil
            }
            guard let severity else { continue }
            result.append(ReadBoardIssue(
                id: "authorization.\(auth.platformID)", category: .authorization,
                severity: severity,
                title: severity == .repairing ? "正在修复\(auth.displayName)授权" : "\(auth.displayName)需要重新授权",
                detail: auth.message ?? "平台授权不可用。",
                affectedCount: 1,
                actionTitle: severity == .needsAttention ? "打开设置" : nil,
                action: severity == .needsAttention
                    ? .openSettings(auth.settingsModuleIdentifier.map { .module($0) } ?? .page(.sources))
                    : nil))
        }

        if runtime.pausedFailureCount > 0 {
            result.append(ReadBoardIssue(
                id: "processing.deadletters", category: .processing, severity: .needsAttention,
                title: "自动内容处理已暂停", detail: "连续失败三次的目标需要重试或永久忽略。",
                affectedCount: runtime.pausedFailureCount,
                actionTitle: "查看处理项", action: .openOperations))
        }
        if problems.fullTextFailures > 0 {
            result.append(ReadBoardIssue(
                id: "processing.fulltext", category: .processing,
                severity: problems.persistentFullTextFailures > 0 ? .needsAttention : .repairing,
                title: "正文提取失败",
                detail: problems.persistentFullTextFailures > 0
                    ? "源列表已更新成功；部分单篇正文持续无法获取。"
                    : "源列表已更新成功，系统稍后自动补抓这些单篇正文。",
                affectedCount: problems.fullTextFailures,
                actionTitle: "查看并重试", action: .openOperations))
        }
        if problems.exportFailures > 0 {
            result.append(ReadBoardIssue(
                id: "export.failed", category: .export, severity: .needsAttention,
                title: "导出任务失败",
                detail: "\(problems.affectedExportRules) 条启用规则存在失败记录，请检查目标配置或权限。",
                affectedCount: problems.exportFailures,
                actionTitle: "打开导出规则", action: .openSettings(.page(.pipeline))))
        }
        let pendingAI = runtime.queue.score + runtime.queue.translate + runtime.queue.summarize
        if pendingAI > 0, !configuration.llmProfiles.contains(where: { $0.hasAPIKey && !$0.model.isEmpty }) {
            result.append(ReadBoardIssue(
                id: "processing.llm.missing", category: .processing, severity: .needsAttention,
                title: "LLM 尚未配置", detail: "存在等待处理的内容，但没有可用的模型配置。",
                affectedCount: pendingAI,
                actionTitle: "打开 LLM 设置", action: .openSettings(.page(.llm))))
        }
        let transcriptionIDs = Set(["whisperCLI", "ffmpeg", "ytdlp", "whisperModel"])
        if runtime.queue.transcribe > 0,
           configuration.dependencies.contains(where: { transcriptionIDs.contains($0.id) && !$0.installed }) {
            result.append(ReadBoardIssue(
                id: "processing.transcription.dependencies", category: .processing, severity: .needsAttention,
                title: "转录依赖不完整", detail: "Whisper、ffmpeg、yt-dlp 或模型文件缺失。",
                affectedCount: runtime.queue.transcribe,
                actionTitle: "打开依赖设置", action: .openSettings(.page(.deps))))
        }
        issues = result.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    private func platformName(_ id: String) -> String {
        switch id {
        case "wechat": "微信公众号"
        case "bilibili": "B站"
        case "youtube": "YouTube"
        case "podcast": "播客"
        case "rss": "RSS"
        default: id
        }
    }
}

public struct ReadBoardIssueCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReadBoardIssueCenterModel
    private let action: (ReadBoardIssueAction) -> Void

    public init(environment: ReadBoardFeatureEnvironment,
                action: @escaping (ReadBoardIssueAction) -> Void) {
        _model = State(initialValue: ReadBoardIssueCenterModel(environment: environment))
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ReadBoardHairline()
            Group {
                if model.issues.isEmpty {
                    ContentUnavailableView(
                        "全部正常", systemImage: "checkmark.circle.fill",
                        description: Text("源抓取、平台授权、内容处理和导出均未发现问题。"))
                        .foregroundStyle(ReadBoardDesign.C.scoreHigh)
                } else {
                    List {
                        ForEach(ReadBoardIssueCategory.allCases, id: \.self) { category in
                            let values = model.issues.filter { $0.category == category }
                            if !values.isEmpty {
                                Section { ForEach(values) { issueRow($0) } }
                                header: { Label(category.rawValue, systemImage: category.icon) }
                            }
                        }
                    }.listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("问题中心").font(.headline)
                Text(model.statusText).font(.caption).foregroundStyle(ReadBoardDesign.C.text3)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: {
                if model.isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.buttonStyle(ReadBoardQuietButtonStyle())
            Button("关闭") { dismiss() }.buttonStyle(ReadBoardQuietButtonStyle())
        }.padding(16)
    }

    private func issueRow(_ issue: ReadBoardIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.severity == .needsAttention
                ? "exclamationmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(issueColor(issue)).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(issue.title).font(.system(size: 13, weight: .semibold))
                    if issue.affectedCount > 1 {
                        Text("\(issue.affectedCount) 项").font(.caption2.monospacedDigit())
                    }
                }
                Text(issue.detail).font(.caption).foregroundStyle(ReadBoardDesign.C.text3).lineLimit(3)
            }
            Spacer(minLength: 12)
            if let title = issue.actionTitle, let target = issue.action {
                Button(title) { dismiss(); action(target) }
                    .buttonStyle(ReadBoardQuietButtonStyle()).controlSize(.small)
            }
        }.padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch model.status {
        case .healthy: ReadBoardDesign.C.scoreHigh
        case .repairing: ReadBoardDesign.C.scoreMid
        case .needsAttention: ReadBoardDesign.C.scoreLow
        }
    }
    private func issueColor(_ issue: ReadBoardIssue) -> Color {
        issue.severity == .needsAttention ? ReadBoardDesign.C.scoreLow : ReadBoardDesign.C.scoreMid
    }
}
