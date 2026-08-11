import CoreImage.CIFilterBuiltins
import ReadBoardContract
import ReadBoardUI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct ReadBoardOperationsFeatureView: View {
    @State private var model: ReadBoardOperationsFeatureModel
    @State private var signOutPlatform: PlatformAuthenticationStatus?

    public init(environment: ReadBoardFeatureEnvironment) {
        _model = State(initialValue: ReadBoardOperationsFeatureModel(environment: environment))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ReadBoardDesign.Space.xl) {
                header
                sourceHealthCard
                engineCard
                queueMetrics
                if !model.runtime.activeItems.isEmpty { activeItemsCard }
                if !model.recentProcessing.isEmpty { recentProcessingCard }
                if !model.processingFailures.isEmpty { processingFailuresCard }
                if !model.fullTextFailures.isEmpty { fullTextFailuresCard }
                if !model.authentications.isEmpty { authenticationCard }
                statisticsCard
            }
            .padding(ReadBoardDesign.Space.xl)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(ReadBoardDesign.C.bg)
        .task { await model.monitor() }
        .refreshable { await model.load() }
        .sheet(isPresented: Binding(
            get: { model.authenticationChallenge != nil },
            set: { if !$0 { model.dismissAuthentication() } }
        )) {
            ReadBoardAuthenticationChallengeView(model: model)
        }
        .alert("退出平台登录？", isPresented: Binding(
            get: { signOutPlatform != nil },
            set: { if !$0 { signOutPlatform = nil } }
        )) {
            Button("取消", role: .cancel) { signOutPlatform = nil }
            Button("退出登录", role: .destructive) {
                guard let platform = signOutPlatform else { return }
                signOutPlatform = nil
                Task { await model.signOut(platformID: platform.platformID) }
            }
        } message: {
            Text("退出后，该平台的订阅更新可能暂停，直到重新完成授权。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "请稍后重试")
        }
        .overlay(alignment: .bottom) { statusToast }
    }

    private var problemSources: [SourceCatalogItem] {
        model.sourceCatalog?.sources.filter { $0.enabled && ($0.hasError || $0.isStale) } ?? []
    }

    private var sourceHealthCard: some View {
        operationSection("订阅源健康") {
            HStack(spacing: ReadBoardDesign.Space.md) {
                let enabled = model.sourceCatalog?.sources.filter(\.enabled).count ?? 0
                ReadBoardMetricTile(title: "已启用", value: "\(enabled)",
                    icon: "dot.radiowaves.left.and.right", color: ReadBoardDesign.C.accent)
                ReadBoardMetricTile(title: "健康", value: "\(max(0, enabled - problemSources.count))",
                    icon: "checkmark.circle", color: ReadBoardDesign.C.scoreHigh)
                ReadBoardMetricTile(title: "问题", value: "\(problemSources.count)",
                    icon: "exclamationmark.triangle",
                    color: problemSources.isEmpty ? ReadBoardDesign.C.text3 : ReadBoardDesign.C.scoreLow)
                Spacer(minLength: 8)
                if model.permissions.allows(.runProcessing, capability: .sourceManagement) {
                    Button { Task { await model.syncAllSources() } } label: {
                        Label("全部更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ReadBoardSecondaryButtonStyle())
                    .disabled(model.activeOperations.contains("sources:all"))
                }
            }
            if problemSources.isEmpty {
                ReadBoardHairline()
                Label("当前没有抓取失败或长期未更新的订阅源", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(ReadBoardDesign.C.scoreHigh)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(problemSources.prefix(12).enumerated()), id: \.element.id) { index, source in
                    ReadBoardHairline()
                    HStack(spacing: ReadBoardDesign.Space.md) {
                        Image(systemName: source.hasError
                            ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                            .foregroundStyle(source.hasError
                                ? ReadBoardDesign.C.scoreLow : ReadBoardDesign.C.scoreMid)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(source.error ?? sourceHealthText(source))
                                .font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
                                .lineLimit(2)
                        }
                        Spacer()
                        if model.permissions.allows(.runProcessing, capability: .sourceManagement) {
                            Button("重试") { Task { await model.retrySource(id: source.id) } }
                                .buttonStyle(ReadBoardQuietButtonStyle())
                                .disabled(model.activeOperations.contains("source:\(source.id)"))
                        }
                    }
                    .padding(.vertical, 8)
                    if index == 11, problemSources.count > 12 {
                        Text("另有 \(problemSources.count - 12) 个问题源")
                            .font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
                    }
                }
            }
        }
    }

    private var recentProcessingCard: some View {
        operationSection("手动处理任务") {
            ForEach(Array(model.recentProcessing.enumerated()), id: \.element.id) { index, activity in
                HStack(spacing: ReadBoardDesign.Space.md) {
                    processingActivityIcon(activity.snapshot.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(jobTitle(activity.snapshot.operation.rawValue)) · \(activity.snapshot.message)")
                            .font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(Date(timeIntervalSince1970: TimeInterval(activity.snapshot.updatedAt))
                        .formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .padding(.vertical, 8)
                if index < model.recentProcessing.count - 1 { ReadBoardHairline() }
            }
        }
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.sm) {
            ReadBoardSectionLabel(text: "资料库概览")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                let value = model.dashboard.overview
                ReadBoardMetricTile(title: "内容", value: "\(value.totalContent)",
                    icon: "doc.text", color: ReadBoardDesign.C.accent)
                ReadBoardMetricTile(title: "未读", value: "\(value.unreadCount)",
                    icon: "circle.fill", color: ReadBoardDesign.C.scoreMid)
                ReadBoardMetricTile(title: "星标", value: "\(value.starredCount)",
                    icon: "star.fill", color: ReadBoardDesign.C.summary)
                ReadBoardMetricTile(title: "全文", value: "\(value.withFulltext)",
                    icon: "doc.richtext", color: ReadBoardDesign.C.scoreHigh)
                ReadBoardMetricTile(title: "已评分", value: "\(value.scored)",
                    icon: "number", color: ReadBoardDesign.C.translate)
                ReadBoardMetricTile(title: "已翻译", value: "\(value.translated)",
                    icon: "character.book.closed", color: ReadBoardDesign.C.podcast)
                ReadBoardMetricTile(title: "数据库", value: String(format: "%.1f MB", value.databaseSizeMB),
                    icon: "externaldrive", color: ReadBoardDesign.C.text2)
            }
        }
    }

    private func sourceHealthText(_ source: SourceCatalogItem) -> String {
        if let hours = source.hoursSinceFetch { return "上次抓取 \(Int(hours)) 小时前" }
        return "尚未完成首次抓取"
    }

    @ViewBuilder
    private func processingActivityIcon(_ state: ProcessingCommandState) -> some View {
        switch state {
        case .queued, .running:
            ProgressView().controlSize(.small)
        case .succeeded, .noWork:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(ReadBoardDesign.C.scoreHigh)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ReadBoardDesign.C.scoreLow)
        case .busy:
            Image(systemName: "clock.fill").foregroundStyle(ReadBoardDesign.C.scoreMid)
        }
    }

    private var header: some View {
        ReadBoardPageHeader(
            eyebrow: "服务",
            title: "运行状态",
            subtitle: model.runtime.lastSummary.isEmpty
                ? healthSummary.message
                : model.runtime.lastSummary
        ) {
            if model.permissions.allows(.runProcessing, capability: .processing) {
                Button { Task { await model.runProcessingScan() } } label: {
                    Label("立即扫描", systemImage: "play.fill")
                }
                .buttonStyle(ReadBoardSecondaryButtonStyle())
                .disabled(model.activeOperations.contains("scan"))
            }
            Button { Task { await model.load() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(ReadBoardQuietButtonStyle())
            .disabled(model.isLoading)
        }
    }

    private var engineCard: some View {
        ReadBoardPanel {
            HStack(spacing: ReadBoardDesign.Space.lg) {
                ZStack {
                    RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                        .fill(phaseColor.opacity(0.10))
                    Image(systemName: phaseIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(phaseColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    ReadBoardSectionLabel(text: "AI 内容处理")
                    Text(phaseTitle)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ReadBoardDesign.C.text)
                    Text(model.runtime.lastSummary.isEmpty
                        ? "处理引擎等待新的任务"
                        : model.runtime.lastSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(model.runtime.queue.items)")
                        .font(.system(size: 30, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ReadBoardDesign.C.text)
                    Text("队列项目")
                        .font(.system(size: 10))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
            }
        }
    }

    private var queueMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            ReadBoardMetricTile(title: "待评分", value: "\(model.runtime.queue.score)",
                icon: "number", color: ReadBoardDesign.C.accent)
            ReadBoardMetricTile(title: "待摘要", value: "\(model.runtime.queue.summarize)",
                icon: "text.alignleft", color: ReadBoardDesign.C.summary)
            ReadBoardMetricTile(title: "待翻译", value: "\(model.runtime.queue.translate)",
                icon: "character.book.closed", color: ReadBoardDesign.C.translate)
            ReadBoardMetricTile(title: "待转录", value: "\(model.runtime.queue.transcribe)",
                icon: "waveform", color: ReadBoardDesign.C.podcast)
            ReadBoardMetricTile(title: "已处理", value: "\(model.runtime.processedCount)",
                icon: "checkmark.circle", color: ReadBoardDesign.C.scoreHigh)
            ReadBoardMetricTile(title: "暂停错误", value: "\(model.runtime.pausedFailureCount)",
                icon: "exclamationmark.triangle",
                color: model.runtime.pausedFailureCount > 0
                    ? ReadBoardDesign.C.scoreLow
                    : ReadBoardDesign.C.scoreHigh)
        }
    }

    private var activeItemsCard: some View {
        operationSection("当前正在处理") {
            ForEach(Array(model.runtime.activeItems.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: ReadBoardDesign.Space.md) {
                    ProgressView().controlSize(.small).tint(ReadBoardDesign.C.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(item.stage).font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
                    }
                    Spacer()
                }
                .padding(.vertical, 9)
                if index < model.runtime.activeItems.count - 1 { ReadBoardHairline() }
            }
        }
    }

    private var processingFailuresCard: some View {
        operationSection("内容处理失败") {
            ForEach(Array(model.processingFailures.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: ReadBoardDesign.Space.md) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(ReadBoardDesign.C.scoreLow)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(item.sourceName) · \(jobTitle(item.jobType)) · 连续失败 \(item.consecutiveFailures) 次")
                            .font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
                        if let error = item.error, !error.isEmpty {
                            Text(error).font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.scoreLow)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("忽略") { Task { await model.ignoreProcessingFailure(id: item.id) } }
                        .buttonStyle(ReadBoardQuietButtonStyle())
                    Button("重试") { Task { await model.retryProcessingFailure(id: item.id) } }
                        .buttonStyle(ReadBoardSecondaryButtonStyle())
                }
                .padding(.vertical, 9)
                if index < model.processingFailures.count - 1 { ReadBoardHairline() }
            }
        }
    }

    private var fullTextFailuresCard: some View {
        operationSection("正文提取失败") {
            ForEach(Array(model.fullTextFailures.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: ReadBoardDesign.Space.md) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(ReadBoardDesign.C.scoreMid)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(item.sourceName) · \(item.sourceType)")
                            .font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
                        Text(item.error).font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.scoreLow)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("重试") { Task { await model.retryFullText(contentID: item.id) } }
                        .buttonStyle(ReadBoardSecondaryButtonStyle())
                }
                .padding(.vertical, 9)
                if index < model.fullTextFailures.count - 1 { ReadBoardHairline() }
            }
        }
    }

    private var authenticationCard: some View {
        operationSection("平台授权") {
            ForEach(Array(model.authentications.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: ReadBoardDesign.Space.md) {
                    Circle().fill(authenticationColor(item.phase)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).font(.system(size: 12, weight: .medium))
                        Text(item.accountName ?? item.message ?? authenticationTitle(item.phase))
                            .font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
                            .lineLimit(1)
                    }
                    Spacer()
                    ReadBoardBadge(
                        text: authenticationTitle(item.phase),
                        color: authenticationColor(item.phase))
                    if model.permissions.allows(.manageAuthentication, capability: .authentication),
                       item.phase != .notRequired {
                        if item.phase == .authenticated {
                            Button("退出") { signOutPlatform = item }
                                .buttonStyle(ReadBoardQuietButtonStyle())
                        } else {
                            Button("重新登录") {
                                Task { await model.beginAuthentication(platformID: item.platformID) }
                            }
                            .buttonStyle(ReadBoardSecondaryButtonStyle())
                        }
                    }
                }
                .padding(.vertical, 9)
                if index < model.authentications.count - 1 { ReadBoardHairline() }
            }
        }
    }

    private func operationSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.sm) {
            ReadBoardSectionLabel(text: title)
            ReadBoardPanel { VStack(spacing: 0) { content() } }
        }
    }

    private var healthSummary: ReadBoardServiceHealthSummary {
        ReadBoardServiceHealthSummary(
            runtime: model.runtime,
            authentications: model.authentications,
            problems: model.problemCounts)
    }

    private var phaseTitle: String {
        switch model.runtime.phase {
        case .idle: "处理引擎空闲"
        case .scanning: "正在扫描处理目标"
        case .working: "正在处理内容"
        }
    }

    private var phaseIcon: String {
        switch model.runtime.phase {
        case .idle: "pause.fill"
        case .scanning: "arrow.triangle.2.circlepath"
        case .working: "sparkles"
        }
    }

    private var phaseColor: Color {
        switch model.runtime.phase {
        case .idle: ReadBoardDesign.C.text3
        case .scanning: ReadBoardDesign.C.scoreMid
        case .working: ReadBoardDesign.C.accent
        }
    }

    private func authenticationTitle(_ phase: PlatformAuthenticationPhase) -> String {
        switch phase {
        case .notRequired: "无需登录"
        case .authenticated: "已登录"
        case .waitingForScan: "等待扫码"
        case .waitingForConfirmation: "等待确认"
        case .repairing: "正在修复"
        case .needsAttention: "需要处理"
        case .signedOut: "未登录"
        case .expired: "已过期"
        }
    }

    private func authenticationColor(_ phase: PlatformAuthenticationPhase) -> Color {
        switch phase {
        case .notRequired, .authenticated: ReadBoardDesign.C.scoreHigh
        case .waitingForScan, .waitingForConfirmation, .repairing: ReadBoardDesign.C.scoreMid
        case .needsAttention, .signedOut, .expired: ReadBoardDesign.C.scoreLow
        }
    }

    private func jobTitle(_ raw: String) -> String {
        switch raw {
        case "score": "AI 评分"
        case "summarize": "AI 摘要"
        case "translate": "AI 翻译"
        case "transcribe": "AI 转录"
        case "fulltext": "全文提取"
        default: raw
        }
    }

    @ViewBuilder
    private var statusToast: some View {
        if let message = model.statusMessage, !message.isEmpty {
            HStack(spacing: ReadBoardDesign.Space.sm) {
                Image(systemName: "checkmark.circle")
                Text(message).lineLimit(2)
                Button { model.clearStatus() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11))
            .foregroundStyle(ReadBoardDesign.C.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial).clipShape(Capsule())
            .padding(.bottom, 16)
        }
    }
}

public struct ReadBoardServiceHealthButton: View {
    @State private var model: ReadBoardServiceHealthMonitorModel
    private let action: () -> Void

    public init(
        environment: ReadBoardFeatureEnvironment,
        action: @escaping () -> Void
    ) {
        _model = State(initialValue: ReadBoardServiceHealthMonitorModel(environment: environment))
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
            }
        }
        .buttonStyle(.plain)
        .help(model.summary.message)
        .task {
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .readBoardLibrarySnapshotChanged)) { _ in
                Task { await model.load() }
            }
    }

    private var color: Color {
        switch model.summary.phase {
        case .healthy: ReadBoardDesign.C.scoreHigh
        case .repairing: ReadBoardDesign.C.scoreMid
        case .needsAttention: ReadBoardDesign.C.scoreLow
        }
    }

    private var icon: String {
        switch model.summary.phase {
        case .healthy: "checkmark"
        case .repairing: "arrow.triangle.2.circlepath"
        case .needsAttention: "exclamationmark"
        }
    }
}

private struct ReadBoardAuthenticationChallengeView: View {
    @Environment(\.dismiss) private var dismiss
    let model: ReadBoardOperationsFeatureModel

    var body: some View {
        VStack(spacing: ReadBoardDesign.Space.lg) {
            Text("平台登录")
                .font(.system(size: 18, weight: .semibold, design: .serif))
            if let challenge = model.authenticationChallenge {
                if let image = qrImage(challenge.qrPayload) {
                    image.resizable().interpolation(.none).scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(10).background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
                }
                Text("使用对应平台 App 扫描二维码并确认登录")
                    .font(.system(size: 12)).foregroundStyle(ReadBoardDesign.C.text2)
                Text("二维码将在 \(Date(timeIntervalSince1970: challenge.expiresAt).formatted(date: .omitted, time: .shortened)) 失效")
                    .font(.system(size: 10)).foregroundStyle(ReadBoardDesign.C.text3)
            }
            Button("取消") {
                model.dismissAuthentication()
                dismiss()
            }
            .buttonStyle(ReadBoardSecondaryButtonStyle())
        }
        .padding(ReadBoardDesign.Space.xl)
        .frame(minWidth: 360, minHeight: 420)
        .background(ReadBoardDesign.C.bg)
        .task(id: model.authenticationChallenge?.challengeID) {
            while model.authenticationChallenge != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if await model.pollAuthentication() { dismiss(); break }
            }
        }
    }

    private func qrImage(_ value: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(macOS)
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220)))
        #else
        return Image(uiImage: UIImage(cgImage: cgImage))
        #endif
    }
}
