import SwiftUI
import AppKit

// 入口在 Sources/ReadBoardMain/main.swift（独立 mini-target，库本身无 @main 以便测试链接）
public struct ReadBoardApp: App {
    public init() {
        // SIGPIPE：URLSession 在受限网络环境（沙箱/VPN/proxy）下写已断开的 socket 会触发，
        // 默认信号处理直接杀进程。设为 SIG_IGN 让系统调用返回 EPIPE 错误码而非崩溃。
        signal(SIGPIPE, SIG_IGN)
        // 追踪日志：路径打出来，运行期可在控制台/文件查（UserDefaults readboard.trace 控级别，
        // off/error/warn/info/debug，默认 info）。排查阅读页卡死/内存爆炸用。
        let lvl = UserDefaults.standard.string(forKey: "readboard.trace") ?? "info"
        fputs("[trace] 日志文件：\(Trace.logFileURL.path)  级别=\(lvl)（改 UserDefaults readboard.trace 可即时调级别）\n", stderr)
        Trace.i("═══ ReadBoard 启动 ═══ 版本跟踪日志就绪，日志路径见上", category: "app")
        // 启动后台管线 worker（周期扫描未处理内容，按开关补跑 AI 评分/翻译/摘要/转录）
        PipelineWorker.shared.start()
        // 启动 DB 自动备份（每日热备到 Application Support/ReadBoard/backups，保留最近5份）
        BackupService.shared.start()
        // 启动数据保留策略（已读超期软删除，每日）
        RetentionService.shared.start()
        // 启动定时导出规则扫描；重复调用有内部防重保护。
        ExportService.shared.startScheduler()
        // feed 自动抓取调度：延迟到主 runloop 就绪后启动。
        // 直接在 init 调 startAutoSync()——Timer.scheduledTimer 此时注册的 runloop
        // 还没跑，Task 也可能被 SwiftUI 生命周期取消（实测重启后 CPU 0%、无网络、0 抓取）。
        // Task + 1s 延迟让 runloop 起来后再注册 Timer。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            SourceStore.shared.startAutoSync()
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            ExportService.shared.stopScheduler()
        }
    }
}

/// 全局 Tab 导航状态（阅读/订阅源/管理），左栏底部按钮切换
final class AppTab: ObservableObject {
    @Published var selection = 0
}
