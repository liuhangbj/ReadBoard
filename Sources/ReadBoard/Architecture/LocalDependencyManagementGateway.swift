import Foundation
import ReadBoardContract

public struct LocalDependencyManagementGateway: DependencyManagementGateway {
    public init() {}

    public func snapshot() async -> DependencyManagementSnapshot {
        await DependencyTaskCoordinator.shared.snapshot()
    }

    public func submit(_ request: DependencyTaskRequest) async throws -> DependencyTaskSnapshot {
        try await DependencyTaskCoordinator.shared.submit(request)
    }

    public func cancel(taskID: String) async {
        await DependencyTaskCoordinator.shared.cancel(taskID: taskID)
    }
}

private actor DependencyTaskCoordinator {
    static let shared = DependencyTaskCoordinator()

    private var tasks: [String: DependencyTaskSnapshot] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var processes: [String: ProcessBox] = [:]

    func snapshot() async -> DependencyManagementSnapshot {
        let dependencies = await LocalConfigurationGateway().snapshot().dependencies
        let recent = tasks.values.sorted { $0.startedAt > $1.startedAt }
        return DependencyManagementSnapshot(
            dependencies: dependencies,
            tasks: Array(recent.prefix(20)))
    }

    func submit(_ request: DependencyTaskRequest) throws -> DependencyTaskSnapshot {
        guard DependencyCommand.isSupported(request) else {
            throw DependencyManagementError.unsupported
        }
        if let active = tasks.values.first(where: {
            $0.dependencyID == request.dependencyID
                && [.queued, .running].contains($0.phase)
        }) {
            return active
        }
        let id = UUID().uuidString.lowercased()
        let initial = DependencyTaskSnapshot(
            id: id,
            dependencyID: request.dependencyID,
            operation: request.operation,
            phase: .queued,
            message: "等待服务端执行")
        tasks[id] = initial
        workers[id] = Task { [weak self] in await self?.run(id: id, request: request) }
        return initial
    }

    func cancel(taskID: String) {
        workers[taskID]?.cancel()
        processes[taskID]?.terminate()
        workers.removeValue(forKey: taskID)
        processes.removeValue(forKey: taskID)
        guard let old = tasks[taskID], [.queued, .running].contains(old.phase) else { return }
        tasks[taskID] = replacing(old, phase: .cancelled, message: "已取消", finished: true)
    }

    private func run(id: String, request: DependencyTaskRequest) async {
        guard let initial = tasks[id] else { return }
        tasks[id] = replacing(initial, phase: .running, message: runningMessage(request))
        do {
            switch request.operation {
            case .redetect:
                break
            case .install, .update:
                if request.dependencyID == DependencyPaths.Kind.whisperModel.rawValue {
                    try await runModelDownload(replacingExisting: request.operation == .update)
                } else {
                    try await runCommand(id: id, command: try DependencyCommand.resolve(request))
                }
            }
            try Task.checkCancellation()
            if let current = tasks[id] {
                tasks[id] = replacing(
                    current,
                    phase: .succeeded,
                    message: request.operation == .redetect ? "检测完成" : "操作完成",
                    finished: true)
            }
        } catch is CancellationError {
            if let current = tasks[id] {
                tasks[id] = replacing(current, phase: .cancelled, message: "已取消", finished: true)
            }
        } catch {
            if let current = tasks[id] {
                tasks[id] = replacing(
                    current,
                    phase: .failed,
                    message: error.localizedDescription,
                    finished: true)
            }
        }
        workers.removeValue(forKey: id)
        processes.removeValue(forKey: id)
    }

    private func runCommand(id: String, command: DependencyCommand) async throws {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let box = ProcessBox(process)
        processes[id] = box
        try await Task.detached(priority: .utility) {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: data.suffix(2_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw DependencyManagementError.commandFailed(
                    detail.isEmpty ? "依赖命令执行失败" : detail)
            }
        }.value
    }

    @MainActor
    private func runModelDownload(replacingExisting: Bool) async throws {
        let downloader = ModelDownloader.shared
        await downloader.download(modelName: "medium", replacingExisting: replacingExisting)
        if let message = downloader.errorMessage {
            throw DependencyManagementError.commandFailed(message)
        }
    }

    private func runningMessage(_ request: DependencyTaskRequest) -> String {
        switch request.operation {
        case .install: "正在安装"
        case .update: "正在更新"
        case .redetect: "正在重新检测"
        }
    }

    private func replacing(
        _ value: DependencyTaskSnapshot,
        phase: DependencyTaskPhase,
        message: String,
        finished: Bool = false
    ) -> DependencyTaskSnapshot {
        DependencyTaskSnapshot(
            id: value.id,
            dependencyID: value.dependencyID,
            operation: value.operation,
            phase: phase,
            progress: value.progress,
            message: message,
            startedAt: value.startedAt,
            finishedAt: finished ? Date().timeIntervalSince1970 : nil)
    }
}

private struct DependencyCommand: Sendable {
    let executable: URL
    let arguments: [String]

    static func isSupported(_ request: DependencyTaskRequest) -> Bool {
        if request.operation == .redetect { return true }
        return [
            DependencyPaths.Kind.node.rawValue,
            DependencyPaths.Kind.whisperCLI.rawValue,
            DependencyPaths.Kind.ffmpeg.rawValue,
            DependencyPaths.Kind.ytdlp.rawValue,
            DependencyPaths.Kind.whisperModel.rawValue,
        ].contains(request.dependencyID)
    }

    static func resolve(_ request: DependencyTaskRequest) throws -> DependencyCommand {
        let package: String = switch request.dependencyID {
        case DependencyPaths.Kind.node.rawValue: "node"
        case DependencyPaths.Kind.whisperCLI.rawValue: "whisper-cpp"
        case DependencyPaths.Kind.ffmpeg.rawValue: "ffmpeg"
        case DependencyPaths.Kind.ytdlp.rawValue: "yt-dlp"
        default: throw DependencyManagementError.unsupported
        }
        let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let path = brewCandidates.first(where: FileManager.default.isExecutableFile) else {
            throw DependencyManagementError.brewUnavailable
        }
        let action = request.operation == .update ? "upgrade" : "install"
        return DependencyCommand(
            executable: URL(fileURLWithPath: path),
            arguments: [action, package])
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }
}

private enum DependencyManagementError: LocalizedError {
    case unsupported
    case brewUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "服务端不支持这个依赖操作"
        case .brewUnavailable: "服务端没有找到 Homebrew，无法自动安装"
        case .commandFailed(let detail): detail
        }
    }
}
