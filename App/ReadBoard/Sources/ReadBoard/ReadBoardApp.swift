import SwiftUI

// 入口在 Sources/ReadBoardMain/main.swift（独立 mini-target，库本身无 @main 以便测试链接）
public struct ReadBoardApp: App {
    public init() {
        // 启动后台管线 worker（周期扫描未处理内容，按开关补跑打分/翻译/摘要/转录）
        PipelineWorker.shared.start()
        // 启动 feed 自动抓取调度（周期 syncAll，信息流源头）
        SourceStore.shared.startAutoSync()
        // 启动 DB 自动备份（每日热备到 Data/backups/，保留最近5份）
        BackupService.shared.start()
        // 启动数据保留策略（已读超期归档/归档超期删除，每日）
        RetentionService.shared.start()
        // 存量补齐：无管线源的历史内容入库即归档（纯原文 md），后台跑一次。
        // 只跑未归档的（幂等），增量执行——每次启动只补新出现的缺口。
        Task.detached(priority: .background) {
            let n = ArchiveService.shared.backfillNoPipelineArchives()
            if n > 0 { fputs("[archive] 存量补齐归档 \(n) 条（无管线源纯原文）\n", stderr) }
        }
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 780)

        // 独立设置窗口（⌘, 打开）
        Settings {
            SettingsView()
        }
    }
}

public struct RootView: View {
    @State private var tab = 0

    public var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("阅读", systemImage: "doc.text") }
                .tag(0)
            SourcesView()
                .tabItem { Label("订阅源", systemImage: "dot.radiowaves.left.and.right") }
                .tag(1)
            ManageView()
                .tabItem { Label("管理", systemImage: "chart.bar.doc.horizontal") }
                .tag(3)
        }
    }
}
