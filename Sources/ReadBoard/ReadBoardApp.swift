import SwiftUI
import AppKit

// 入口在 Sources/ReadBoardMain/main.swift（独立 mini-target，库本身无 @main 以便测试链接）
public struct ReadBoardApp: App {
    private let configuration: ReadBoardConfiguration
    private let services: ReadBoardServices
    private let runtime: ServiceRuntime

    public init() {
        self.init(configuration: .community, services: .live)
    }

    public init(configuration: ReadBoardConfiguration) {
        self.init(configuration: configuration, services: .live)
    }

    public init(
        configuration: ReadBoardConfiguration,
        services: @autoclosure () -> ReadBoardServices
    ) {
        self.configuration = configuration
        ReadBoardRuntime.configure(
            applicationSupportDirectoryName: configuration.applicationSupportDirectoryName
        )
        // 必须先配置运行目录，再创建 live services。LocalReaderGateway 会首次访问
        // Database.shared；若顺序相反，Pro 会把数据库静态路径锁定到社区版目录。
        self.services = services()
        self.runtime = ServiceRuntime(configuration: configuration, services: self.services)
        // SIGPIPE：URLSession 在受限网络环境（沙箱/VPN/proxy）下写已断开的 socket 会触发，
        // 默认信号处理直接杀进程。设为 SIG_IGN 让系统调用返回 EPIPE 错误码而非崩溃。
        signal(SIGPIPE, SIG_IGN)
        // 追踪日志：路径打出来，运行期可在控制台/文件查（UserDefaults readboard.trace 控级别，
        // off/error/warn/info/debug，默认 info）。排查阅读页卡死/内存爆炸用。
        let lvl = UserDefaults.standard.string(forKey: "readboard.trace") ?? "info"
        fputs("[trace] 日志文件：\(Trace.logFileURL.path)  级别=\(lvl)（改 UserDefaults readboard.trace 可即时调级别）\n", stderr)
        Trace.i("═══ ReadBoard 启动 ═══ 版本跟踪日志就绪，日志路径见上", category: "app")
        // 启动后台管线 worker（周期扫描未处理内容，按开关补跑 AI 评分/翻译/摘要/转录）
        runtime.start()
    }

    public var body: some Scene {
        WindowGroup {
            RootView(configuration: configuration, services: services, onTerminate: { runtime.stop() })
                .environment(\.readBoardConfiguration, configuration)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 780)

        // 独立设置窗口（⌘, 打开）
        Settings {
            SettingsView(services: services)
                .environment(\.readBoardConfiguration, configuration)
        }
    }

}

public struct RootView: View {
    @StateObject private var tab = AppTab()
    private let configuration: ReadBoardConfiguration
    private let services: ReadBoardServices
    private let onTerminate: () -> Void

    public init(
        configuration: ReadBoardConfiguration = .community,
        services: ReadBoardServices = .live,
        onTerminate: @escaping () -> Void = {}
    ) {
        self.configuration = configuration
        self.services = services
        self.onTerminate = onTerminate
    }

    public var body: some View {
        // 无底部 Tab 栏——导航入口移到阅读页左栏底部（订阅源/管理），
        // 通过共享 AppTab 状态切换。阅读是主视图，订阅源/管理全窗切换。
        Group {
            switch tab.selection {
            case 1:
                SourcesView(services: services)
            case 3:
                ManageView(services: services)
            default:
                ContentView(services: services)
            }
        }
        .environmentObject(tab)
        .frame(minWidth: 900, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            onTerminate()
        }
    }
}

/// 全局 Tab 导航状态（阅读/订阅源/管理），左栏底部按钮切换
final class AppTab: ObservableObject {
    @Published var selection = 0
}
