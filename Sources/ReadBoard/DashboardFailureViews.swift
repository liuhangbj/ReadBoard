import SwiftUI
import AppKit
import ReadBoardContract

// MARK: - 源更新问题列表

struct SourceFailureListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog: SourceCatalogStore
    private let sourceManagement: any SourceManagementGateway
    @State private var items: [SourceCatalogItem] = []
    @State private var loading = true
    @State private var retryingSourceID: Int64?
    @State private var retryingAll = false
    @State private var statusMessage = ""
    @State private var statusIsSuccess = true

    init(
        sourceCatalog: any SourceCatalogGateway,
        sourceManagement: any SourceManagementGateway
    ) {
        _catalog = StateObject(
            wrappedValue: SourceCatalogStore(gateway: sourceCatalog))
        self.sourceManagement = sourceManagement
    }

    var body: some View {
        VStack(spacing: 0) {
            FailureListHeader(
                title: "源更新失败",
                subtitle: "更新失败或超过 48 小时未更新的订阅源",
                icon: "dot.radiowaves.left.and.right",
                count: items.count,
                onClose: { dismiss() }
            )

            Hairline()

            Group {
                if loading {
                    ProgressView("正在检查订阅源…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "没有源更新失败",
                        systemImage: "checkmark.seal",
                        description: Text("所有启用的订阅源均正常")
                    )
                } else {
                    List(items) { source in
                        sourceRow(source)
                            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    }
                    .listStyle(.inset)
                }
            }

            Hairline()

            HStack(spacing: 10) {
                if !statusMessage.isEmpty {
                    Image(systemName: statusIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(statusIsSuccess ? Color.rbScoreHigh : Color.rbScoreLow)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsSuccess ? Color.rbScoreHigh : Color.rbScoreLow)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    retryAll()
                } label: {
                    if retryingAll {
                        Label("正在全部重试…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("全部重试", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.primaryCapsule)
                .disabled(items.isEmpty || retryingAll || retryingSourceID != nil || catalog.isSyncing)
            }
            .padding(14)
        }
        .frame(width: 760, height: 540)
        .task { await reload(showLoading: true) }
    }

    private func sourceRow(_ source: SourceCatalogItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.hasError
                  ? "exclamationmark.triangle.fill"
                  : "clock.badge.exclamationmark")
                .font(.system(size: 14))
                .foregroundStyle(source.hasError ? Color.rbScoreLow : Color.rbScoreMid)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                    .lineLimit(1)
                Text(source.identifier)
                    .font(.caption2)
                    .foregroundStyle(Color.rbText3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = source.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.rbScoreLow)
                        .lineLimit(2)
                } else {
                    Text(staleDescription(source))
                        .font(.caption)
                        .foregroundStyle(Color.rbScoreMid)
                }
            }

            Spacer(minLength: 12)

            Button {
                retry(source)
            } label: {
                if retryingSourceID == source.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("重试")
                }
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .disabled(retryingAll || retryingSourceID != nil || catalog.isSyncing)
        }
    }

    private func staleDescription(_ source: SourceCatalogItem) -> String {
        if let hours = source.hoursSinceFetch {
            return "上次成功更新于 \(Int(hours)) 小时前 · 已入库 \(source.contentCount) 条"
        }
        return "尚未完成首次更新 · 已入库 \(source.contentCount) 条"
    }

    private func retry(_ source: SourceCatalogItem) {
        retryingSourceID = source.id
        statusMessage = ""
        Task {
            do {
                let result = try await sourceManagement.sync(
                    scope: SourceScope(kind: .source, id: source.id))
                statusIsSuccess = true
                statusMessage = result.message
            } catch {
                statusIsSuccess = false
                statusMessage = error.localizedDescription
            }
            retryingSourceID = nil
            await reload(showLoading: false)
        }
    }

    private func retryAll() {
        let sourceIDs = items.map(\.id)
        retryingAll = true
        statusMessage = ""
        Task {
            var succeeded = 0
            var failed = 0
            for (index, id) in sourceIDs.enumerated() {
                statusMessage = "正在重试 \(index + 1)/\(sourceIDs.count)…"
                do {
                    _ = try await sourceManagement.sync(
                        scope: SourceScope(kind: .source, id: id))
                    succeeded += 1
                } catch {
                    failed += 1
                }
            }
            statusIsSuccess = failed == 0
            statusMessage = "重试完成：成功 \(succeeded)，失败 \(failed)"
            retryingAll = false
            await reload(showLoading: false)
        }
    }

    @MainActor
    private func reload(showLoading: Bool) async {
        if showLoading { loading = true }
        await catalog.refresh()
        items = catalog.sources.filter { $0.enabled && ($0.hasError || $0.isStale) }
        loading = false
    }
}

// MARK: - 内容处理失败列表

struct ContentFailureListSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let runtimeStatus: any RuntimeStatusGateway
    private let administration: any AdministrationGateway
    @State private var items: [ContentProcessingFailure] = []
    @State private var loading = true
    @State private var retryingJobID: Int64?
    @State private var retryingAll = false
    @State private var statusMessage = ""
    @State private var statusIsSuccess = true

    init(runtimeStatus: any RuntimeStatusGateway,
         administration: any AdministrationGateway = ReadBoardServices.live.administration) {
        self.runtimeStatus = runtimeStatus
        self.administration = administration
    }

    var body: some View {
        VStack(spacing: 0) {
            FailureListHeader(
                title: "内容处理失败",
                subtitle: "连续失败 3 次后暂停的任务",
                icon: "exclamationmark.triangle",
                count: items.count,
                onClose: { dismiss() }
            )

            Hairline()

            Group {
                if loading {
                    ProgressView("正在读取失败任务…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "没有失败任务",
                        systemImage: "checkmark.circle",
                        description: Text("内容处理引擎运行正常")
                    )
                } else {
                    List(items) { failure in
                        failureRow(failure)
                            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    }
                    .listStyle(.inset)
                }
            }

            Hairline()

            HStack(spacing: 10) {
                if !statusMessage.isEmpty {
                    Image(systemName: statusIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(statusIsSuccess ? Color.rbScoreHigh : Color.rbScoreLow)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsSuccess ? Color.rbScoreHigh : Color.rbScoreLow)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    retryAll()
                } label: {
                    if retryingAll {
                        Label("正在全部重试…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("全部重试", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.primaryCapsule)
                .disabled(items.isEmpty || retryingAll || retryingJobID != nil)
            }
            .padding(14)
        }
        .frame(width: 780, height: 560)
        .task { await reload(showLoading: true) }
    }

    private func failureRow(_ failure: ContentProcessingFailure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: taskIcon(failure.jobType))
                .font(.system(size: 14))
                .foregroundStyle(Color.rbScoreLow)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(failure.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.rbText)
                        .lineLimit(1)
                    FailureTypeBadge(text: taskLabel(failure.jobType))
                    Text("连续失败 \(failure.consecutiveFailures) 次")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.rbScoreLow)
                }
                Text(failure.sourceName)
                    .font(.caption2)
                    .foregroundStyle(Color.rbText3)
                if let error = failure.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.rbText3)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Button("忽略") {
                ignore(failure)
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .help("永久忽略该内容的此项自动处理目标；仍可手动处理")
            .disabled(retryingAll || retryingJobID != nil)

            Button {
                retry(failure)
            } label: {
                if retryingJobID == failure.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("重试")
                }
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .disabled(retryingAll || retryingJobID != nil)
        }
    }

    private func ignore(_ failure: ContentProcessingFailure) {
        Task {
            statusIsSuccess = await administration.ignoreProcessingFailure(id: failure.id)
            statusMessage = statusIsSuccess
                ? "已忽略“\(failure.title)”的\(taskLabel(failure.jobType))目标" : "忽略失败"
            _ = await runtimeStatus.snapshot(refreshCounts: true)
            await reload(showLoading: false)
        }
    }

    private func retry(_ failure: ContentProcessingFailure) {
        retryingJobID = failure.id
        statusMessage = ""
        Task {
            let success = await administration.retryProcessingFailure(id: failure.id)
            statusIsSuccess = success
            statusMessage = success ? "“\(failure.title)”重试成功" : "“\(failure.title)”重试失败"
            retryingJobID = nil
            _ = await runtimeStatus.snapshot(refreshCounts: true)
            await reload(showLoading: false)
        }
    }

    private func retryAll() {
        let failures = items
        retryingAll = true
        statusMessage = ""
        Task {
            var succeeded = 0
            var failed = 0
            for (index, failure) in failures.enumerated() {
                statusMessage = "正在重试 \(index + 1)/\(failures.count)…"
                if await administration.retryProcessingFailure(id: failure.id) {
                    succeeded += 1
                } else {
                    failed += 1
                }
            }
            statusIsSuccess = failed == 0
            statusMessage = "重试完成：成功 \(succeeded)，失败 \(failed)"
            retryingAll = false
            _ = await runtimeStatus.snapshot(refreshCounts: true)
            await reload(showLoading: false)
        }
    }

    @MainActor
    private func reload(showLoading: Bool) async {
        if showLoading { loading = true }
        items = await administration.processingFailures()
        loading = false
    }

    private func taskLabel(_ type: String) -> String {
        switch type {
        case "score": "AI 评分"
        case "translate": "AI 翻译"
        case "summarize": "AI 摘要"
        case "transcribe": "AI 转录"
        default: type
        }
    }

    private func taskIcon(_ type: String) -> String {
        switch type {
        case "score": "number"
        case "translate": "globe"
        case "summarize": "text.alignleft"
        case "transcribe": "waveform"
        default: "gearshape.2"
        }
    }
}

// MARK: - 外部平台正文提取失败列表

struct ExternalFullTextFailureListSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let sourceManagement: any SourceManagementGateway
    private let administration: any AdministrationGateway
    @State private var items: [FullTextFailure] = []
    @State private var loading = true
    @State private var retryingID: Int64?
    @State private var retryingAll = false
    @State private var statusMessage = ""
    @State private var statusIsSuccess = true

    init(sourceManagement: any SourceManagementGateway,
         administration: any AdministrationGateway = ReadBoardServices.live.administration) {
        self.sourceManagement = sourceManagement
        self.administration = administration
    }

    var body: some View {
        VStack(spacing: 0) {
            FailureListHeader(
                title: "正文提取失败",
                subtitle: "源列表已更新成功，仅这些内容的正文需要补抓",
                icon: "doc.text.magnifyingglass",
                count: items.count,
                onClose: { dismiss() })
            Hairline()
            Group {
                if loading {
                    ProgressView("正在读取正文失败记录…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "没有正文提取失败", systemImage: "checkmark.circle",
                        description: Text("外部平台正文提取正常"))
                } else {
                    List(items) { failure in
                        failureRow(failure)
                            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    }
                    .listStyle(.inset)
                }
            }
            Hairline()
            HStack(spacing: 10) {
                if !statusMessage.isEmpty {
                    Image(systemName: statusIsSuccess
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(statusIsSuccess ? Color.rbScoreHigh : Color.rbScoreLow)
                    Text(statusMessage).font(.caption).lineLimit(1)
                }
                Spacer()
                Button {
                    retryAll()
                } label: {
                    Label(retryingAll ? "正在全部重试…" : "全部重试",
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(.primaryCapsule)
                .disabled(items.isEmpty || retryingAll || retryingID != nil)
            }
            .padding(14)
        }
        .frame(width: 800, height: 560)
        .task { await reload(showLoading: true) }
    }

    private func failureRow(_ failure: FullTextFailure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Color.rbScoreMid)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(failure.sourceName) · \(failure.sourceType)")
                    .font(.caption2).foregroundStyle(Color.rbText3)
                Text(failure.error)
                    .font(.caption).foregroundStyle(Color.rbText3).lineLimit(2)
            }
            Spacer(minLength: 12)
            if let url = URL(string: failure.url), ["http", "https"].contains(url.scheme ?? "") {
                Button("打开原文") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.quiet).controlSize(.small)
            }
            Button {
                retry(failure)
            } label: {
                if retryingID == failure.id { ProgressView().controlSize(.mini) }
                else { Text("重试") }
            }
            .buttonStyle(.quiet).controlSize(.small)
            .disabled(retryingAll || retryingID != nil)
        }
    }

    private func retry(_ failure: FullTextFailure) {
        retryingID = failure.id
        statusMessage = ""
        Task {
            do {
                _ = try await sourceManagement.retryFulltext(contentID: failure.id)
                statusIsSuccess = true
                statusMessage = "“\(failure.title)”正文补抓成功"
            } catch {
                statusIsSuccess = false
                statusMessage = "“\(failure.title)”仍无法提取"
            }
            retryingID = nil
            await reload(showLoading: false)
        }
    }

    private func retryAll() {
        let failures = items
        retryingAll = true
        statusMessage = ""
        Task {
            var succeeded = 0
            var failed = 0
            for (index, failure) in failures.enumerated() {
                statusMessage = "正在重试 \(index + 1)/\(failures.count)…"
                if (try? await sourceManagement.retryFulltext(contentID: failure.id)) != nil {
                    succeeded += 1
                } else {
                    failed += 1
                }
            }
            statusIsSuccess = failed == 0
            statusMessage = "重试完成：成功 \(succeeded)，失败 \(failed)"
            retryingAll = false
            await reload(showLoading: false)
        }
    }

    @MainActor
    private func reload(showLoading: Bool) async {
        if showLoading { loading = true }
        items = await administration.fullTextFailures(limit: 200)
        loading = false
    }
}

// MARK: - 共享列表样式

private struct FailureListHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let count: Int
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.rbAccent)
                .frame(width: 26, height: 26)
                .background(Color.rbAccent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.rbText)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.rbText3)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
            }
            Spacer()
            Button("关闭", action: onClose)
                .buttonStyle(.quiet)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }
}

private struct FailureTypeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.rbScoreLow)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.rbScoreLow.opacity(0.10))
            .clipShape(Capsule())
    }
}
