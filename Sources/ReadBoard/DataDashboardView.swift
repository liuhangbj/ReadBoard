import SwiftUI

/// 数据看板单页：顶部聚合运行状态，底部只保留核心数字概览。
public struct DataDashboardView: View {
    @EnvironmentObject private var appTab: AppTab

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { appTab.selection = 0 } label: {
                    Label("阅读", systemImage: "chevron.left")
                }
                .buttonStyle(.quiet)
                .help("返回阅读")

                Text("数据看板")
                    .font(.system(size: RB.F.pageTitle, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        SourceUpdateDashboardCard()
                            .frame(maxWidth: .infinity)
                        AIProcessingDashboardCard()
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 390)

                    DashboardStatsOverview()
                }
                .padding(20)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

// MARK: - 源更新与健康

private struct SourceUpdateDashboardCard: View {
    @StateObject private var store = SourceStore.shared
    @State private var healthReport: [SourceHealth] = []
    @State private var loadingHealth = true
    @State private var showProblemList = false

    private var enabledHealth: [SourceHealth] { healthReport.filter(\.enabled) }
    private var problems: [SourceHealth] {
        enabledHealth.filter { $0.hasError || $0.isStale }
    }
    private var healthyCount: Int { max(0, enabledHealth.count - problems.count) }

    var body: some View {
        DashboardCard(title: "源更新", icon: "arrow.triangle.2.circlepath", tint: .rbAccent) {
            HStack(spacing: 8) {
                if store.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("正在更新订阅源…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.rbText2)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbScoreHigh)
                    Text("源更新空闲")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.rbText2)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await store.syncAll() }
                } label: {
                    Label("立即更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .disabled(store.isSyncing)
            }

            if !store.lastSyncMessage.isEmpty {
                Text(store.lastSyncMessage)
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Hairline()

            if loadingHealth {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("检查源健康状态…")
                        .font(.caption)
                        .foregroundStyle(Color.rbText3)
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
            } else {
                HStack {
                    Text("源健康")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.rbText2)
                    Spacer()
                }

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    DashboardMetricTile(title: "启用", value: enabledHealth.count, tint: .rbAccent)
                    DashboardMetricTile(title: "健康", value: healthyCount, tint: .rbScoreHigh)
                    DashboardMetricTile(title: "问题", value: problems.count,
                                        tint: problems.isEmpty ? .rbText3 : .rbScoreLow)
                }

                HStack(spacing: 10) {
                    Image(systemName: problems.isEmpty
                          ? "checkmark.circle"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(problems.isEmpty ? Color.rbScoreHigh : Color.rbScoreLow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("源更新失败")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.rbText2)
                        Text(problems.isEmpty
                             ? "当前没有更新失败的订阅源"
                             : "更新失败或超过 48 小时未更新的订阅源")
                            .font(.caption2)
                            .foregroundStyle(Color.rbText3)
                    }
                    Spacer()
                    Text("\(problems.count)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(problems.isEmpty ? Color.rbText3 : Color.rbScoreLow)
                    Button("查看") { showProblemList = true }
                        .buttonStyle(.quiet)
                        .controlSize(.small)
                        .disabled(problems.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.rbSurface.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: RB.Radius.md)
                        .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                )
            }
        }
        .task { await reloadHealth() }
        .onChange(of: store.isSyncing) { wasSyncing, isSyncing in
            if wasSyncing, !isSyncing {
                Task { await reloadHealth() }
            }
        }
        .sheet(isPresented: $showProblemList, onDismiss: {
            Task { await reloadHealth() }
        }) {
            SourceFailureListSheet()
        }
    }

    @MainActor
    private func reloadHealth() async {
        loadingHealth = true
        let report = await Task.detached(priority: .userInitiated) {
            SourceHealthService.shared.report()
        }.value
        healthReport = report
        loadingHealth = false
    }
}

private struct SourceHealthDashboardRow: View {
    let source: SourceHealth

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: source.hasError
                  ? "exclamationmark.triangle.fill"
                  : "clock.badge.exclamationmark")
                .font(.system(size: 12))
                .foregroundStyle(source.hasError ? Color.rbScoreLow : Color.rbScoreMid)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.rbText)
                    .lineLimit(1)
                if let error = source.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Color.rbScoreLow)
                        .lineLimit(1)
                } else if let hours = source.hoursSinceFetch {
                    Text("上次抓取 \(Int(hours)) 小时前 · \(source.contentCount) 条")
                        .font(.caption2)
                        .foregroundStyle(Color.rbText3)
                } else {
                    Text("尚未完成首次抓取 · \(source.contentCount) 条")
                        .font(.caption2)
                        .foregroundStyle(Color.rbText3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - AI 内容处理

private struct AIProcessingDashboardCard: View {
    @StateObject private var worker = PipelineWorker.shared
    @State private var showFailureList = false

    private var phaseLabel: String {
        switch worker.phase {
        case .scanning: "内容处理引擎扫描中"
        case .working: "内容处理引擎工作中"
        case .idle: "内容处理引擎空闲"
        }
    }

    var body: some View {
        DashboardCard(title: "AI 内容处理", icon: "gearshape.2", tint: .rbTranslate) {
            HStack(spacing: 8) {
                if worker.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbText3)
                }
                Text(phaseLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.rbText2)
                Spacer(minLength: 8)
                Button {
                    Task { await worker.runOnce() }
                } label: {
                    Label("立即扫描", systemImage: "play")
                }
                .buttonStyle(.quiet)
                .controlSize(.small)
                .disabled(worker.isRunning)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("队列数量")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.rbText2)
                Spacer()
                Text("\(worker.pendingBreakdown.items)")
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.rbText)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                DashboardMetricTile(title: "AI 评分", value: worker.pendingBreakdown.score, tint: .rbAccent)
                DashboardMetricTile(title: "AI 翻译", value: worker.pendingBreakdown.translate, tint: .rbTranslate)
                DashboardMetricTile(title: "AI 摘要", value: worker.pendingBreakdown.summarize, tint: .rbSummary)
                DashboardMetricTile(title: "AI 转录", value: worker.pendingBreakdown.transcribe, tint: .rbPodcast)
            }

            Hairline()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("当前正在处理")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.rbText2)
                    Spacer()
                    if !worker.currentItems.isEmpty {
                        Text("\(worker.currentItems.count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.rbAccent)
                    }
                }
                if worker.currentItems.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(Color.rbText3)
                        Text("当前没有正在处理的内容")
                            .font(.caption)
                            .foregroundStyle(Color.rbText3)
                    }
                } else {
                    ForEach(worker.currentItems) { item in
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text(item.stage)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.rbAccent)
                                .frame(width: 34, alignment: .leading)
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(Color.rbText2)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(Color.rbSurface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.md)
                    .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
            )

            HStack(spacing: 10) {
                Image(systemName: worker.deadLetterCount > 0
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.circle")
                    .foregroundStyle(worker.deadLetterCount > 0 ? Color.rbScoreLow : Color.rbScoreHigh)
                VStack(alignment: .leading, spacing: 2) {
                    Text("内容处理失败")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.rbText2)
                    Text(worker.deadLetterCount > 0
                         ? "连续失败 3 次后暂停的任务"
                         : "当前没有暂停的失败任务")
                        .font(.caption2)
                        .foregroundStyle(Color.rbText3)
                }
                Spacer()
                Text("\(worker.deadLetterCount)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(worker.deadLetterCount > 0 ? Color.rbScoreLow : Color.rbText3)
                Button("查看") { showFailureList = true }
                    .buttonStyle(.quiet)
                    .controlSize(.small)
                    .disabled(worker.deadLetterCount == 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.rbSurface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.md)
                    .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
            )
        }
        .sheet(isPresented: $showFailureList, onDismiss: {
            worker.requestPendingRefresh()
        }) {
            ContentFailureListSheet()
        }
    }
}

// MARK: - 核心数字概览

private struct DashboardStatsOverview: View {
    @State private var overview = StatsOverview()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "数据概览")
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                statCard("订阅源", "\(overview.enabledSources)/\(overview.totalSources)", "dot.radiowaves.left.and.right", .rbAccent)
                statCard("内容总数", "\(overview.totalContent)", "doc.text", .rbText2)
                statCard("未读", "\(overview.unreadCount)", "circlebadge.fill", .rbAccent)
                statCard("星标", "\(overview.starredCount)", "star.fill", .rbStar)
                statCard("重复", "\(overview.duplicateCount)", "doc.on.doc", .rbSummary)
                statCard("全文", "\(overview.withFulltext)", "text.alignleft", .rbScoreHigh)
                statCard("已 AI 评分", "\(overview.scored)", "number", .rbAccent)
                statCard("已翻译", "\(overview.translated)", "globe", .rbTranslate)
                statCard("DB 大小", String(format: "%.0f MB", overview.dbSizeMB), "internaldrive", .rbText2)
            }
        }
        .task {
            overview = await Task.detached(priority: .utility) {
                StatsService.shared.overview()
            }.value
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.rbText)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.rbSurface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RB.Radius.lg)
                .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
        )
    }
}

// MARK: - 通用看板组件

private struct DashboardMetricTile: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.rbText2)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.rbSurface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: RB.Radius.md)
                .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
        )
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    private let content: Content

    init(title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Spacer()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.rbSurface.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RB.Radius.lg)
                .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
        )
    }
}
