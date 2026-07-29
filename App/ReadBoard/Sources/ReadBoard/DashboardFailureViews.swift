import SwiftUI

// MARK: - 源更新问题列表

struct SourceFailureListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = SourceStore.shared
    @State private var items: [SourceHealth] = []
    @State private var loading = true
    @State private var retryingSourceID: Int64?
    @State private var retryingAll = false
    @State private var statusMessage = ""
    @State private var statusIsSuccess = true

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
                .disabled(items.isEmpty || retryingAll || retryingSourceID != nil || store.isSyncing)
            }
            .padding(14)
        }
        .frame(width: 760, height: 540)
        .task { await reload(showLoading: true) }
    }

    private func sourceRow(_ source: SourceHealth) -> some View {
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
            .disabled(retryingAll || retryingSourceID != nil || store.isSyncing)
        }
    }

    private func staleDescription(_ source: SourceHealth) -> String {
        if let hours = source.hoursSinceFetch {
            return "上次成功更新于 \(Int(hours)) 小时前 · 已入库 \(source.contentCount) 条"
        }
        return "尚未完成首次更新 · 已入库 \(source.contentCount) 条"
    }

    private func retry(_ source: SourceHealth) {
        retryingSourceID = source.id
        statusMessage = ""
        Task {
            let result = await store.retrySource(id: source.id)
            statusIsSuccess = result.success
            statusMessage = result.message
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
                let result = await store.retrySource(id: id)
                if result.success { succeeded += 1 } else { failed += 1 }
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
        let report = await Task.detached(priority: .userInitiated) {
            SourceHealthService.shared.problemSources()
        }.value
        items = report
        loading = false
    }
}

// MARK: - 内容处理失败列表

struct ContentFailureListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var worker = PipelineWorker.shared
    @State private var items: [PausedContentFailure] = []
    @State private var loading = true
    @State private var retryingJobID: Int64?
    @State private var retryingAll = false
    @State private var statusMessage = ""
    @State private var statusIsSuccess = true

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

    private func failureRow(_ failure: PausedContentFailure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: taskIcon(failure.jtype))
                .font(.system(size: 14))
                .foregroundStyle(Color.rbScoreLow)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(failure.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.rbText)
                        .lineLimit(1)
                    FailureTypeBadge(text: taskLabel(failure.jtype))
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

    private func retry(_ failure: PausedContentFailure) {
        retryingJobID = failure.id
        statusMessage = ""
        Task {
            let success = await FailedJobService.shared.retry(failure)
            statusIsSuccess = success
            statusMessage = success ? "“\(failure.title)”重试成功" : "“\(failure.title)”重试失败"
            retryingJobID = nil
            worker.requestPendingRefresh()
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
                if await FailedJobService.shared.retry(failure) {
                    succeeded += 1
                } else {
                    failed += 1
                }
            }
            statusIsSuccess = failed == 0
            statusMessage = "重试完成：成功 \(succeeded)，失败 \(failed)"
            retryingAll = false
            worker.requestPendingRefresh()
            await reload(showLoading: false)
        }
    }

    @MainActor
    private func reload(showLoading: Bool) async {
        if showLoading { loading = true }
        let failures = await Task.detached(priority: .userInitiated) {
            FailedJobService.shared.pausedFailures()
        }.value
        items = failures
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
