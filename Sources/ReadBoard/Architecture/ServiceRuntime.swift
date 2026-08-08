import Foundation

/// 统一持有服务进程生命周期。窗口只负责展示；关闭任一窗口不会误停 worker，
/// 应用终止时所有 scheduler 按相反顺序收尾。
@MainActor
public final class ServiceRuntime {
    private let configuration: ReadBoardConfiguration
    private let services: ReadBoardServices
    private var started = false
    private var delayedSourceStart: Task<Void, Never>?
    private var httpServer: ReadBoardHTTPServer?

    public init(configuration: ReadBoardConfiguration, services: ReadBoardServices) {
        self.configuration = configuration; self.services = services
    }

    public func start() {
        guard !started else { return }
        started = true
        PipelineWorker.shared.start()
        BackupService.shared.start()
        RetentionService.shared.start()
        ExportService.shared.startScheduler()
        configuration.modules.forEach { $0.start() }
        if RemoteAccessSettings.enabled {
            let server = ReadBoardHTTPServer(services: services, token: RemoteAccessSettings.deviceToken,
                port: RemoteAccessSettings.port, allowLAN: RemoteAccessSettings.allowLAN)
            do { try server.start(); httpServer = server }
            catch { Trace.e("HTTP 服务启动失败：\(error.localizedDescription)", category: "service") }
        }
        delayedSourceStart = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            SourceStore.shared.startAutoSync()
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        delayedSourceStart?.cancel(); delayedSourceStart = nil
        SourceStore.shared.stopAutoSync()
        httpServer?.stop(); httpServer = nil
        configuration.modules.reversed().forEach { $0.stop() }
        ExportService.shared.stopScheduler()
        RetentionService.shared.stop()
        BackupService.shared.stop()
        PipelineWorker.shared.stop()
    }
}

enum RemoteAccessSettings {
    private static let tokenKey = "service.http.deviceToken"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "service.http.enabled") as? Bool ?? true
    }
    static var allowLAN: Bool { UserDefaults.standard.bool(forKey: "service.http.allowLAN") }
    static var port: UInt16 {
        let value = UserDefaults.standard.integer(forKey: "service.http.port")
        return UInt16(exactly: value > 0 ? value : 7331) ?? 7331
    }
    static var deviceToken: String {
        if let value = SecretStore.load(forKey: tokenKey), !value.isEmpty { return value }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        precondition(SecretStore.save(value, forKey: tokenKey), "Unable to persist service device token")
        return value
    }
}
