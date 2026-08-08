import Foundation

/// 统一持有服务进程生命周期。窗口只负责展示；关闭任一窗口不会误停 worker，
/// 应用终止时所有 scheduler 按相反顺序收尾。
@MainActor
public final class ServiceRuntime {
    private let configuration: ReadBoardConfiguration
    private let services: ReadBoardServices
    private var started = false
    private var delayedSourceStart: Task<Void, Never>?

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
        RemoteAccessController.shared.start(services: services)
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
        RemoteAccessController.shared.stop()
        configuration.modules.reversed().forEach { $0.stop() }
        ExportService.shared.stopScheduler()
        RetentionService.shared.stop()
        BackupService.shared.stop()
        PipelineWorker.shared.stop()
    }
}
