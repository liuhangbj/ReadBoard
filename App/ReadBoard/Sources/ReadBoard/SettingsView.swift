import SwiftUI

// MARK: - 设置面板（转录依赖状态 + 安装引导 + 模型下载）

struct SettingsView: View {
    @State private var deps: [TranscribeDependency] = []
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var copiedId: String? = nil

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
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { deps = DependencyChecker.shared.checkAll() }
    }
}
