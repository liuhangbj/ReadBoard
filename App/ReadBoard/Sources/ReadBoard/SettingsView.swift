import SwiftUI

// MARK: - 设置面板（转录依赖状态 + 安装引导 + 模型下载）

struct SettingsView: View {
    @State private var deps: [TranscribeDependency] = []
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var cleanup = CacheCleanupService.shared
    @State private var copiedId: String? = nil
    @State private var archiveDays = 30
    @State private var deleteDays = 90
    @State private var keepCount = 5
    @State private var cleanHtml = true
    @State private var cleanHtmlDays = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.title2.bold())
                .padding()

            Form {
                Section("转录依赖（播客 / 视频转写）") {
                    ForEach(deps) { dep in
                        HStack(spacing: 10) {
                            Image(systemName: dep.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(dep.installed ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dep.displayName).font(.headline)
                                Text(dep.installed ? dep.path : dep.installHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if !dep.installed {
                                if let cmd = dep.installCommand {
                                    Button(copiedId == dep.id ? "已复制" : "复制命令") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(cmd, forType: .string)
                                        copiedId = dep.id
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            if copiedId == dep.id { copiedId = nil }
                                        }
                                    }
                                    .controlSize(.small)
                                } else {
                                    // 模型：自动下载
                                    Button("自动下载") { Task { await downloader.download() } }
                                        .controlSize(.small)
                                        .disabled(downloader.isDownloading)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }

                    // 模型下载进度
                    if downloader.isDownloading || !downloader.statusText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if downloader.progress >= 0 {
                                ProgressView(value: downloader.progress)
                            } else {
                                ProgressView()
                            }
                            Text(downloader.statusText)
                                .font(.caption).foregroundStyle(.secondary)
                            if let err = downloader.errorMessage {
                                Text(err).font(.caption).foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 3)
                    }

                    // 总体状态
                    HStack {
                        let ready = DependencyChecker.shared.transcribeReady
                        Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                            .foregroundStyle(ready ? .green : .orange)
                        Text(ready ? "转录功能可用" : "转录功能不可用——请先安装上方缺失依赖")
                            .font(.callout)
                            .foregroundStyle(ready ? .green : .orange)
                    }
                }

                Section("feed 自动抓取") {
                    Toggle("自动周期抓取（默认 15 分钟）", isOn: Binding(
                        get: { SourceStore.shared.autoSyncEnabled },
                        set: { SourceStore.shared.autoSyncEnabled = $0 }
                    ))
                    Text("关闭后只能手动点「全部刷新」抓 feed")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("缓存清理") {
                    // 当前占用
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("数据库").foregroundStyle(.secondary)
                            Spacer()
                            Text(CacheCleanupService.humanBytes(cleanup.dbBytes)).monospacedDigit()
                        }
                        HStack {
                            Text("本地备份（\(cleanup.backupCount) 份）").foregroundStyle(.secondary)
                            Spacer()
                            Text(CacheCleanupService.humanBytes(cleanup.backupBytes)).monospacedDigit()
                        }
                        HStack {
                            Text("临时文件（\(cleanup.tempCount) 项）").foregroundStyle(.secondary)
                            Spacer()
                            Text(CacheCleanupService.humanBytes(cleanup.tempBytes)).monospacedDigit()
                        }
                        HStack {
                            Text("可清理全文 HTML").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(cleanup.contentHtmlCount) 条").monospacedDigit()
                        }
                    }
                    .font(.callout)

                    // 可配置项
                    Stepper("已读 \(archiveDays) 天后自动归档", value: $archiveDays, in: 1...365)
                        .onChange(of: archiveDays) { _, v in cleanup.archiveAfterDays = v }
                    Stepper(deleteDays == 0 ? "归档内容永不删除" : "归档 \(deleteDays) 天后自动删除", value: $deleteDays, in: 0...730)
                        .onChange(of: deleteDays) { _, v in cleanup.deleteAfterDays = v }
                    Stepper("备份保留最近 \(keepCount) 份", value: $keepCount, in: 1...30)
                        .onChange(of: keepCount) { _, v in cleanup.backupKeepCount = v }
                    Toggle("清理已转 Markdown 的全文 HTML", isOn: $cleanHtml)
                        .onChange(of: cleanHtml) { _, v in cleanup.cleanContentHtml = v }
                    if cleanHtml {
                        Stepper("全文 HTML 保留 \(cleanHtmlDays) 天", value: $cleanHtmlDays, in: 1...90)
                            .onChange(of: cleanHtmlDays) { _, v in cleanup.cleanHtmlAfterDays = v }
                            .padding(.leading, 16)
                    }

                    // 执行
                    HStack {
                        Button(cleanup.isRunning ? "清理中…" : "立即清理") {
                            Task { await cleanup.runAll() }
                        }
                        .disabled(cleanup.isRunning)
                        if cleanup.isRunning { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("刷新占用") { cleanup.refreshStats() }
                            .controlSize(.small)
                    }
                    if !cleanup.lastRunSummary.isEmpty {
                        Text(cleanup.lastRunSummary)
                            .font(.caption).foregroundStyle(.green)
                    }
                    Text("星标 / 有标签的内容任何清理都不动。全文 HTML 是抓取中间产物，转成 Markdown 后清理可显著减小数据库。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            deps = DependencyChecker.shared.checkAll()
            archiveDays = cleanup.archiveAfterDays
            deleteDays = cleanup.deleteAfterDays
            keepCount = cleanup.backupKeepCount
            cleanHtml = cleanup.cleanContentHtml
            cleanHtmlDays = cleanup.cleanHtmlAfterDays
            cleanup.refreshStats()
        }
    }
}
