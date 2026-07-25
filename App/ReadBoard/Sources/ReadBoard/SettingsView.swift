import SwiftUI
import AppKit

// MARK: - 独立设置窗口（⌘, 打开，NavigationSplitView 分页）
// 六页：通用 / 功能板块 / AI 与 LLM / 依赖 / 导出规则 / 缓存清理

public enum SettingsPage: String, CaseIterable, Identifiable {
    case general, boards, ai, deps, export, cleanup
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .ai: return "AI 与 LLM"
        case .deps: return "依赖"
        case .boards: return "功能板块"
        case .export: return "导出规则"
        case .cleanup: return "缓存清理"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .ai: return "brain.head.profile"
        case .deps: return "shippingbox"
        case .boards: return "square.grid.2x2"
        case .export: return "square.and.arrow.up"
        case .cleanup: return "trash"
        }
    }
}

public struct SettingsView: View {
    @State private var selection: SettingsPage? = .general

    public var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.icon)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selection ?? .general {
            case .general: GeneralPane()
            case .boards: BoardsPane()
            case .ai: AILLMPane()
            case .deps: DepsPane()
            case .export: ExportRulePane()
            case .cleanup: CleanupPane()
            }
        }
        // 去掉左上角「隐藏左栏」切换按钮——设置页 sidebar 固定显示，不需用户收起
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 720, minHeight: 500)
    }
}

// MARK: - 通用

public struct GeneralPane: View {
    @State private var proxyInput: String = FeedFetcher.globalProxy ?? ""
    @State private var archiveDirInput: String = ""
    @State private var archivedCount = 0

    public var body: some View {
        Form {
            Section("feed 自动抓取") {
                Toggle("自动周期抓取", isOn: Binding(
                    get: { SourceStore.shared.autoSyncEnabled },
                    set: { SourceStore.shared.autoSyncEnabled = $0 }
                ))
                // 抓取周期间隔下拉（15/30/60/120/360 分钟）
                HStack {
                    Text("抓取间隔")
                    Picker("", selection: Binding(
                        get: { Int(SourceStore.shared.syncInterval / 60) },
                        set: { SourceStore.shared.setSyncInterval(minutes: $0) }
                    )) {
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                        Text("120 分钟").tag(120)
                        Text("360 分钟").tag(360)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                Text("关闭后只能手动点「全部刷新」抓 feed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("md 文件生成（管线完成后落盘）") {
                // 目录用系统文件夹选择器（NSOpenPanel），不手填路径
                HStack {
                    Text(archiveDirInput.isEmpty ? "默认：~/readboard/archive" : archiveDirInput)
                        .font(.callout)
                        .foregroundStyle(archiveDirInput.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择目录…") { pickArchiveDir() }
                    if !archiveDirInput.isEmpty {
                        Button("恢复默认") {
                            archiveDirInput = ""
                            UserDefaults.standard.removeObject(forKey: "archive.dir")
                            refreshArchiveStats()
                        }
                    }
                }
                Text("管线全部跑完的内容自动落成双语 md 存到这里，按源名分子目录。数据库记录保留（可检索），只清 HTML 中间产物。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("已生成 \(archivedCount) 个文件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("网络代理") {
                TextField("代理地址（如 http://127.0.0.1:7890，留空直连）", text: $proxyInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let v = proxyInput.trimmingCharacters(in: .whitespaces)
                        FeedFetcher.globalProxy = v.isEmpty ? nil : v
                    }
                HStack {
                    Button("保存") {
                        let v = proxyInput.trimmingCharacters(in: .whitespaces)
                        FeedFetcher.globalProxy = v.isEmpty ? nil : v
                    }
                    Button("清除") {
                        proxyInput = ""
                        FeedFetcher.globalProxy = nil
                    }
                }
                Text("所有 feed 抓取 / 全文回填 / YouTube 解析统一走此代理")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
        .onAppear {
            archiveDirInput = UserDefaults.standard.string(forKey: "archive.dir") ?? ""
            refreshArchiveStats()
        }
    }

    private func refreshArchiveStats() {
        archivedCount = ArchiveService.shared.archivedFileCount()
    }

    /// 系统文件夹选择器选 md 保存目录（不手填路径）
    private func pickArchiveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 md 文件保存目录"
        if panel.runModal() == .OK, let url = panel.url {
            archiveDirInput = url.path
            UserDefaults.standard.set(url.path, forKey: "archive.dir")
            refreshArchiveStats()
        }
    }
}

// MARK: - AI 与 LLM

public struct AILLMPane: View {
    public var body: some View {
        Form {
            Section("LLM 服务（三槽按序 fallback，允许留空）") {
                Text("槽1 失败自动换槽2，再失败换槽3，最后 .env 兜底。空槽跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(0..<LLMSettings.slotCount, id: \.self) { i in
                LLMSlotView(slotIndex: i)
            }

            Section("AI 子管线开关（需 AI 板块总开关开启）") {
                ForEach(AIPipeline.allCases) { p in
                    Toggle(p.displayName, isOn: Binding(
                        get: { p.enabled },
                        set: { AIPipeline.setEnabled(p, $0) }
                    ))
                }
                Text("这些开关与「功能板块」页的 AI 总开关叠加生效；源/文件夹级还有第三层开关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI 与 LLM")
    }
}

/// 单个 LLM 配置槽（baseURL + apiKey + model + 预设 + 测试），允许留空（空槽跳过）
public struct LLMSlotView: View {
    let slotIndex: Int

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var presetId = "deepseek"
    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var testOK = false
    @State private var savedHint = false

    private var slotLabel: String { "槽 \(slotIndex + 1)" }
    private var filled: Bool { !baseURL.isEmpty || !apiKey.isEmpty || !model.isEmpty }

    public var body: some View {
        Section("\(slotLabel)\(filled ? "" : "（空）")") {
            Picker("预设", selection: $presetId) {
                ForEach(LLMSettings.presets) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .onChange(of: presetId) { _, v in
                if let p = LLMSettings.presets.first(where: { $0.id == v }), !p.baseURL.isEmpty {
                    baseURL = p.baseURL
                    model = p.defaultModel
                }
            }
            TextField("Base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
            SecureField("API Key（存 Keychain，不落明文）", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            TextField("模型", text: $model)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("保存") {
                    LLMSettings(baseURL: baseURL, apiKey: apiKey, model: model)
                        .save(toSlot: slotIndex)
                    savedHint = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedHint = false }
                }
                .disabled(baseURL.isEmpty || apiKey.isEmpty || model.isEmpty)
                Button("清空此槽") {
                    baseURL = ""; apiKey = ""; model = ""
                    LLMSettings.clear(slot: slotIndex)
                }
                .disabled(!filled)
                if savedHint {
                    Text("已保存").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button(testing ? "测试中…" : "测试连接") {
                    testing = true
                    testResult = nil
                    Task {
                        let s = LLMSettings(baseURL: baseURL, apiKey: apiKey, model: model)
                        let (ok, msg) = await LLMClient().testConnection(s)
                        testOK = ok
                        testResult = msg
                        testing = false
                    }
                }
                .disabled(testing || baseURL.isEmpty || apiKey.isEmpty || model.isEmpty)
            }
            if let r = testResult {
                Text(r)
                    .font(.caption)
                    .foregroundStyle(testOK ? .green : .red)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            let s = LLMSettings.slot(slotIndex)
            baseURL = s.baseURL
            apiKey = s.apiKey
            model = s.model
            presetId = LLMSettings.presets.first(where: { $0.baseURL == s.baseURL })?.id ?? "custom"
        }
    }
}

// MARK: - 依赖

public struct DepsPane: View {
    @State private var deps: [TranscribeDependency] = []
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var copiedId: String? = nil
    @State private var customPaths: [String: String] = [:]

    public var body: some View {
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
                                Button("自动下载") { Task { await downloader.download() } }
                                    .controlSize(.small)
                                    .disabled(downloader.isDownloading)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }

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

                HStack {
                    let ready = DependencyChecker.shared.transcribeReady
                    Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                        .foregroundStyle(ready ? .green : .orange)
                    Text(ready ? "转录功能可用" : "转录功能不可用——请先安装上方缺失依赖")
                        .font(.callout)
                        .foregroundStyle(ready ? .green : .orange)
                }
            }

            Section("自定义路径（留空 = 自动探测 PATH 和常见位置）") {
                ForEach(DependencyPaths.Kind.allCases) { kind in
                    HStack {
                        Text(kind.displayName)
                            .frame(width: 150, alignment: .leading)
                        Text(customPaths[kind.rawValue].isNilOrEmpty ? "自动探测" : (customPaths[kind.rawValue] ?? ""))
                            .font(.caption)
                            .foregroundStyle(customPaths[kind.rawValue].isNilOrEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // 系统文件选择器选路径（不手填）
                        Button("选择…") { pickDependencyPath(kind) }
                            .controlSize(.small)
                        // 路径失效告警：配了但文件不在（brew 升级/卸载后）
                        if DependencyPaths.isCustomStale(kind) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("该路径已失效（文件不存在），请修正或清除回自动探测")
                        }
                        if !customPaths[kind.rawValue].isNilOrEmpty {
                            Button("清除") {
                                customPaths[kind.rawValue] = ""
                                DependencyPaths.setCustom(kind, "")
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Text("全文抓取的 node 也在此配置。改动即时生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("依赖")
        .onAppear {
            deps = DependencyChecker.shared.checkAll()
            for kind in DependencyPaths.Kind.allCases {
                customPaths[kind.rawValue] = UserDefaults.standard.string(forKey: kind.defaultsKey) ?? ""
            }
        }
    }

    /// 系统文件选择器选依赖路径（whisper-cli/ffmpeg/yt-dlp/node 可执行、whisper 模型文件）
    private func pickDependencyPath(_ kind: DependencyPaths.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 \(kind.displayName) 的路径"
        if panel.runModal() == .OK, let url = panel.url {
            customPaths[kind.rawValue] = url.path
            DependencyPaths.setCustom(kind, url.path)
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

// MARK: - 功能板块

public struct BoardsPane: View {
    @State private var states: [String: Bool] = [:]

    public var body: some View {
        Form {
            Section {
                ForEach(FeatureBoard.allCases) { board in
                    HStack(spacing: 12) {
                        Image(systemName: board.icon)
                            .frame(width: 24)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(board.displayName).font(.headline)
                            Text(board.subtitle)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(board.subFeatures.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { states[board.rawValue] ?? board.enabled },
                            set: { states[board.rawValue] = $0; FeatureBoard.setEnabled(board, $0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("板块总开关")
            } footer: {
                Text("关掉板块 = 该板块下所有功能全停（无论源级/文件夹级开关怎么开）。AI 子管线细开关在「AI 与 LLM」页。")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("功能板块")
        .onAppear {
            for b in FeatureBoard.allCases { states[b.rawValue] = b.enabled }
        }
    }
}

// MARK: - 缓存清理

public struct CleanupPane: View {
    @ObservedObject private var cleanup = CacheCleanupService.shared
    @State private var archiveDays = 30
    @State private var deleteDays = 90
    @State private var keepCount = 5
    @State private var archiveEnabled = true
    @State private var deleteEnabled = true
    @State private var backupKeepEnabled = true
    @State private var cleanHtml = true
    @State private var cleanHtmlDays = 7
    @State private var showCleanConfirm = false

    /// 清理策略行：开关（可关闭）+ 天数自填（关闭时天数输入禁用）
    private func cleanupDayRow(title: String, unit: String,
                               enabled: Binding<Bool>, days: Binding<Int>,
                               onEnable: @escaping (Bool) -> Void,
                               onDays: @escaping (Int) -> Void) -> some View {
        HStack {
            Toggle(title, isOn: enabled)
                .onChange(of: enabled.wrappedValue) { _, v in onEnable(v) }
            Spacer()
            TextField("", value: days, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .disabled(!enabled.wrappedValue)
                .onChange(of: days.wrappedValue) { _, v in
                    if v > 0 { onDays(v) }
                }
            Text(unit)
                .foregroundStyle(enabled.wrappedValue ? .secondary : Color(nsColor: .tertiaryLabelColor))
        }
    }

    public var body: some View {
        Form {
            Section("当前占用") {
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
                Button("刷新占用") { cleanup.refreshStats() }
                    .controlSize(.small)
            }

            Section("清理策略") {
                // 每项：开关（可关闭）+ 天数自填（TextField 数字）
                cleanupDayRow(
                    title: "已读自动归档", unit: "天后归档",
                    enabled: $archiveEnabled, days: $archiveDays,
                    onEnable: { cleanup.archiveEnabled = $0 },
                    onDays: { cleanup.archiveAfterDays = $0 }
                )
                cleanupDayRow(
                    title: "归档自动删除", unit: "天后删除",
                    enabled: $deleteEnabled, days: $deleteDays,
                    onEnable: { cleanup.deleteEnabled = $0 },
                    onDays: { cleanup.deleteAfterDays = $0 }
                )
                cleanupDayRow(
                    title: "备份滚动保留", unit: "份",
                    enabled: $backupKeepEnabled, days: $keepCount,
                    onEnable: { cleanup.backupKeepEnabled = $0 },
                    onDays: { cleanup.backupKeepCount = $0 }
                )
                cleanupDayRow(
                    title: "清理已转 Markdown 的全文 HTML", unit: "天后清理",
                    enabled: $cleanHtml, days: $cleanHtmlDays,
                    onEnable: { cleanup.cleanContentHtml = $0 },
                    onDays: { cleanup.cleanHtmlAfterDays = $0 }
                )
            }

            Section {
                HStack {
                    Button(cleanup.isRunning ? "清理中…" : "立即清理") {
                        showCleanConfirm = true
                    }
                    .disabled(cleanup.isRunning)
                    if cleanup.isRunning { ProgressView().controlSize(.small) }
                }
                .alert("立即清理？", isPresented: $showCleanConfirm) {
                    Button("取消", role: .cancel) {}
                    Button("开始清理") { Task { await cleanup.runAll() } }
                } message: {
                    Text("将按上方策略归档/删除内容、清理 HTML 和临时文件。\n删除的内容会先备份到回收站（下方可恢复）。")
                }
                if !cleanup.lastRunSummary.isEmpty {
                    Text(cleanup.lastRunSummary)
                        .font(.caption).foregroundStyle(.green)
                }
                Text("星标 / 有标签的内容任何清理都不动。物理删除前会导出 JSONL 到 Data/trash/ 回收站。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("数据库备份 / 恢复") {
                BackupRestoreView()
            }

            Section("回收站（删除的内容备份）") {
                TrashRestoreView()
            }

            Section("管线死信任务") {
                DeadLetterView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("缓存清理")
        .onAppear {
            archiveDays = cleanup.archiveAfterDays
            deleteDays = cleanup.deleteAfterDays
            keepCount = cleanup.backupKeepCount
            archiveEnabled = cleanup.archiveEnabled
            deleteEnabled = cleanup.deleteEnabled
            backupKeepEnabled = cleanup.backupKeepEnabled
            cleanHtml = cleanup.cleanContentHtml
            cleanHtmlDays = cleanup.cleanHtmlAfterDays
            cleanup.refreshStats()
        }
    }
}

// MARK: - 备份/恢复（嵌进缓存清理页底部）

public struct BackupRestoreView: View {
    @State private var backups: [BackupInfo] = []
    @State private var selectedBackup: BackupInfo? = nil
    @State private var showRestoreConfirm = false
    @State private var message: String = ""
    @State private var busy = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(busy ? "备份中…" : "立即备份") {
                    busy = true
                    message = ""
                    Task {
                        await BackupService.shared.backupNow()
                        await MainActor.run {
                            message = BackupService.shared.lastBackupError == nil
                                ? "✅ 已备份：\(BackupService.shared.lastBackupAt ?? "")"
                                : "❌ 备份失败：\(BackupService.shared.lastBackupError ?? "")"
                            busy = false
                            reload()
                        }
                    }
                }
                .controlSize(.small)
                .disabled(busy)
                Spacer()
            }

            if backups.isEmpty {
                Text("暂无本地备份")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Picker("选择备份", selection: $selectedBackup) {
                    Text("未选择").tag(nil as BackupInfo?)
                    ForEach(backups) { b in
                        Text(b.displayName).tag(b as BackupInfo?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.caption)

                Button("恢复所选备份…") {
                    showRestoreConfirm = true
                }
                .controlSize(.small)
                .disabled(selectedBackup == nil)
                .foregroundStyle(.red)
            }

            if !message.isEmpty {
                Text(message).font(.caption)
            }
            Text("恢复前会自动给当前库做一次安全备份。恢复完成后需重启 App。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .alert("确认恢复？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复并退出 App", role: .destructive) {
                guard let b = selectedBackup else { return }
                do {
                    try BackupService.shared.restore(from: b.path)
                    // 恢复后连接句柄已失效，直接退出让用户重开
                    NSApp.terminate(nil)
                } catch {
                    message = "❌ 恢复失败：\(error.localizedDescription)"
                }
            }
        } message: {
            Text("将用 \(selectedBackup?.displayName ?? "") 替换当前数据库。\n当前库会先自动备份，可随时再换回来。")
        }
    }

    private func reload() {
        backups = BackupService.shared.listBackups()
    }
}

// MARK: - 回收站恢复（清理删除的内容可找回）

public struct TrashRestoreView: View {
    @State private var batches: [CacheCleanupService.TrashBatch] = []
    @State private var message = ""
    @State private var showClearConfirm = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if batches.isEmpty {
                Text("回收站为空——清理删除的内容会备份到这里。")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(batches) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(b.date) · \(b.itemCount) 条")
                                .font(.callout)
                            Text(CacheCleanupService.humanBytes(b.sizeBytes))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复") {
                            let r = CacheCleanupService.shared.restoreTrash(batch: b)
                            // 全部条目都已在库里（恢复成功 + 本就存在）→ 备份文件已无价值，删掉防残留
                            if r.restored + r.skipped > 0 {
                                CacheCleanupService.shared.deleteTrash(batch: b)
                            }
                            message = "✅ 恢复 \(r.restored) 条（跳过已存在 \(r.skipped)），已放回归档，备份文件已清理"
                            reload()
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            CacheCleanupService.shared.deleteTrash(batch: b)
                            reload()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                HStack {
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    Button("清空回收站…", role: .destructive) { showClearConfirm = true }
                        .controlSize(.small)
                }
            }
            Text("恢复后内容放回「归档」，可在阅读区归档筛选里查看/取消归档。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .alert("清空回收站？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                CacheCleanupService.shared.clearAllTrash()
                reload()
            }
        } message: {
            Text("回收站里 \(batches.reduce(0) { $0 + $1.itemCount }) 条备份将永久删除，不可找回。")
        }
    }

    private func reload() {
        batches = CacheCleanupService.shared.listTrash()
    }
}

// MARK: - 死信任务管理（管线失败 >=3 被永久跳过的）

public struct DeadLetterView: View {
    @StateObject private var worker = PipelineWorker.shared
    @State private var items: [(contentId: Int64, jtype: String, fails: Int)] = []

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text("无死信任务——连续失败 3 次的管线任务会出现在这里。")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack {
                        Text("内容 #\(it.contentId) · \(it.jtype)")
                            .font(.callout)
                        Text("失败 \(it.fails) 次")
                            .font(.caption2).foregroundStyle(.red)
                        Spacer()
                        Button("重置重试") {
                            worker.resetDeadLetter(contentId: it.contentId, jtype: it.jtype)
                            reload()
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button("全部重置", role: .destructive) {
                        worker.resetAllDeadLetters()
                        reload()
                    }
                    .controlSize(.small)
                }
            }
            Text("死信是连续失败 3 次被永久跳过的任务（防 LLM 费用失控）。重置后下轮 worker 会重新尝试。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        items = worker.deadLetters()
    }
}
