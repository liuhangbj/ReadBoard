import SwiftUI

// 入口在 Sources/ReadBoardMain/main.swift（独立 mini-target，库本身无 @main 以便测试链接）
public struct ReadBoardApp: App {
    public init() {
        // 启动后台管线 worker（周期扫描未处理内容，按开关补跑打分/翻译/摘要/转录）
        PipelineWorker.shared.start()
        // 启动 DB 自动备份（每日热备到 Data/backups/，保留最近5份）
        BackupService.shared.start()
        // 启动数据保留策略（已读超期归档/归档超期删除，每日）
        RetentionService.shared.start()
        // feed 自动抓取调度：延迟到主 runloop 就绪后启动。
        // 直接在 init 调 startAutoSync()——Timer.scheduledTimer 此时注册的 runloop
        // 还没跑，Task 也可能被 SwiftUI 生命周期取消（实测重启后 CPU 0%、无网络、0 抓取）。
        // Task + 1s 延迟让 runloop 起来后再注册 Timer。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            SourceStore.shared.startAutoSync()
        }
        // 存量补齐：无管线源的历史内容入库即归档（纯原文 md），后台跑一次。
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
    @StateObject private var tab = AppTab()

    public var body: some View {
        // 无底部 Tab 栏——导航入口移到阅读页左栏底部（订阅源/管理），
        // 通过共享 AppTab 状态切换。阅读是主视图，订阅源/管理全窗切换。
        Group {
            switch tab.selection {
            case 1:
                SourcesView()
            case 3:
                ManageView()
            default:
                ContentView()
            }
        }
        .environmentObject(tab)
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// 全局 Tab 导航状态（阅读/订阅源/管理），左栏底部按钮切换
final class AppTab: ObservableObject {
    @Published var selection = 0
}
