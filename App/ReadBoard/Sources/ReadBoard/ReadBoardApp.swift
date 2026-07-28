import SwiftUI

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
        // 凭证存储已切换为本地 AES-GCM 加密文件（SecretStore），不再依赖 Keychain。
        // Keychain 在当前运行环境（ad-hoc 自签 + agent 会话）下写入返回 -34018，无法落盘。
        // 此处仅做一次性迁移：把历史上可能残留在 Keychain 里的旧 Key 读出来导入 SecretStore。
        migrateKeychainSecretsIfNeeded()
        // 启动后台管线 worker（周期扫描未处理内容，按开关补跑 AI 评分/翻译/摘要/转录）
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

    /// 一次性把可能残留在 Keychain 里的旧 API Key 抢救到 SecretStore（幂等，只跑一次）。
    /// 当前环境 Keychain 写入已失效，但读取（若用户此前在能弹框时存过）可能仍有残留值。
    /// 即便读不到也不影响：SecretStore 已是唯一真相源，旧 Keychain 项将被忽略。
    private func migrateKeychainSecretsIfNeeded() {
        let flag = "com.readboard.keychainSecretsMigrated"
        let d = UserDefaults.standard
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)
        // llm.slot{0..<16}.apiKey 尝试从 Keychain 读取并导入 SecretStore
        for i in 0..<16 {
            let k = "llm.slot\(i).apiKey"
            if let v = KeychainHelper.load(forKey: k), !v.isEmpty {
                _ = SecretStore.save(v, forKey: k)
                KeychainHelper.delete(forKey: k)
                fputs("[migrate] 从 Keychain 抢救到 SecretStore: \(k)\n", stderr)
            }
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
