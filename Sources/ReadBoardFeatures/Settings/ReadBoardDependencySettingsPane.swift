import ReadBoardContract
import ReadBoardUI
import SwiftUI

#if os(macOS)
import AppKit
#endif

public struct ReadBoardDependencySettingsPane: View {
    private let configuration: any ConfigurationGateway
    private let dependencyManagement: (any DependencyManagementGateway)?
    private let allowsServerPathEditing: Bool

    @State private var dependencies: [DependencyStatus] = []
    @State private var tasks: [DependencyTaskSnapshot] = []
    @State private var editingPaths: [String: String] = [:]
    @State private var isLoading = true
    @State private var message: String?

    public init(
        configuration: any ConfigurationGateway,
        dependencyManagement: (any DependencyManagementGateway)?,
        allowsServerPathEditing: Bool
    ) {
        self.configuration = configuration
        self.dependencyManagement = dependencyManagement
        self.allowsServerPathEditing = allowsServerPathEditing
    }

    public var body: some View {
        Group {
            if dependencyManagement == nil {
                ContentUnavailableView(
                    "依赖管理不可用",
                    systemImage: "shippingbox",
                    description: Text("当前服务端版本没有提供依赖状态接口。"))
            } else {
                Form {
                    dependencyGroup(
                        title: "网页正文提取",
                        description: "Node.js 与随 App 安装的 defuddle 引擎",
                        ids: ["node", "defuddleEngine"])
                    dependencyGroup(
                        title: "音视频转录",
                        description: "Whisper、ffmpeg 与语音模型",
                        ids: ["whisperCLI", "ffmpeg", "whisperModel"])
                    dependencyGroup(
                        title: "视频获取",
                        description: "yt-dlp 与 ffmpeg",
                        ids: ["ytdlp", "ffmpeg"])
                    if let message {
                        Section { Text(message).readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.text2) }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .overlay {
            if isLoading { ProgressView().controlSize(.small) }
        }
        .task {
            while !Task.isCancelled {
                await reload()
                let active = tasks.contains { [.queued, .running].contains($0.phase) }
                try? await Task.sleep(for: .seconds(active ? 1 : 10))
            }
        }
    }

    private func dependencyGroup(
        title: String,
        description: String,
        ids: [String]
    ) -> some View {
        Section {
            ForEach(ids.compactMap { id in dependencies.first(where: { $0.id == id }) }) { item in
                dependencyRow(item)
            }
        } header: {
            HStack {
                ReadBoardSettingsSectionTitle(title)
                Spacer()
                let ready = ids.allSatisfy { id in
                    dependencies.first(where: { $0.id == id })?.installed == true
                }
                Label(ready ? "可用" : "缺少依赖",
                      systemImage: ready ? "checkmark.circle" : "exclamationmark.triangle")
                    .readBoardTextRole(.detail)
                    .foregroundStyle(ready
                        ? ReadBoardDesign.C.scoreHigh : ReadBoardDesign.C.scoreMid)
            }
        } footer: {
            Text(description)
                .readBoardTextRole(.detail)
        }
    }

    private func dependencyRow(_ item: DependencyStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: item.installed
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(item.installed
                        ? ReadBoardDesign.C.scoreHigh : ReadBoardDesign.C.scoreMid)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).readBoardTextRole(.itemTitle)
                    Text(item.version ?? (item.installed ? "已安装" : "服务端未找到"))
                        .readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.text3)
                }
                Spacer()
                if let active = activeTask(item.id) {
                    ProgressView().controlSize(.small)
                    Text(active.message).readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.text2)
                    Button("取消") { Task { await cancel(active) } }
                        .buttonStyle(ReadBoardQuietButtonStyle())
                        .readBoardSettingsButton(.inline)
                } else if supportsInstall(item.id) {
                    Button(item.installed ? "更新" : "安装") {
                        Task { await submit(item) }
                    }
                    .buttonStyle(ReadBoardSecondaryButtonStyle())
                    .readBoardSettingsButton(.inline)
                }
            }

            if allowsServerPathEditing {
                HStack(spacing: 8) {
                    TextField("自动检测或输入服务端路径", text: pathBinding(item))
                        .readBoardSettingsInput(.fill, design: .monospaced)
                    #if os(macOS)
                    Button("选择…") { pickPath(item) }
                        .buttonStyle(ReadBoardSecondaryButtonStyle())
                        .readBoardSettingsButton(.inline)
                    #endif
                    Button("保存") { savePath(item) }
                        .buttonStyle(ReadBoardSecondaryButtonStyle())
                        .readBoardSettingsButton(.inline)
                        .disabled((editingPaths[item.id] ?? "") == (item.path ?? ""))
                }
            } else {
                Text(item.path ?? "由服务端自动检测")
                    .readBoardTextRole(.detail, design: .monospaced)
                    .foregroundStyle(ReadBoardDesign.C.text3)
                    .textSelection(.enabled)
                Text("服务端路径只能在 Core 主机修改。")
                    .readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.text3)
            }

            if item.customPathIsStale {
                Text("已保存的路径不可用，请在 Core 主机修改或清空后重新检测。")
                    .readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.scoreLow)
            }
            if let failed = tasks.first(where: { $0.dependencyID == item.id && $0.phase == .failed }) {
                Text(failed.message).readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.scoreLow)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reload() async {
        guard let dependencyManagement else {
            isLoading = false
            return
        }
        isLoading = dependencies.isEmpty
        if let snapshot = try? await dependencyManagement.snapshot() {
            dependencies = snapshot.dependencies
            tasks = snapshot.tasks
            for item in dependencies where editingPaths[item.id] == nil {
                editingPaths[item.id] = item.path ?? ""
            }
        }
        isLoading = false
    }

    private func pathBinding(_ item: DependencyStatus) -> Binding<String> {
        Binding(
            get: { editingPaths[item.id] ?? item.path ?? "" },
            set: { editingPaths[item.id] = $0 })
    }

    private func activeTask(_ id: String) -> DependencyTaskSnapshot? {
        tasks.first { $0.dependencyID == id && [.queued, .running].contains($0.phase) }
    }

    private func supportsInstall(_ id: String) -> Bool {
        ["node", "whisperCLI", "ffmpeg", "ytdlp", "whisperModel"].contains(id)
    }

    private func submit(_ item: DependencyStatus) async {
        guard let dependencyManagement else { return }
        do {
            _ = try await dependencyManagement.submit(DependencyTaskRequest(
                dependencyID: item.id,
                operation: item.installed ? .update : .install))
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func cancel(_ task: DependencyTaskSnapshot) async {
        guard let dependencyManagement else { return }
        await dependencyManagement.cancel(taskID: task.id)
        await reload()
    }

    private func savePath(_ item: DependencyStatus) {
        let path = (editingPaths[item.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await configuration.setDependencyPath(id: item.id, path: path)
            message = "\(item.displayName) 路径已保存"
            await reload()
        }
    }

    #if os(macOS)
    private func pickPath(_ item: DependencyStatus) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 \(item.displayName)；留空时由 ReadBoard 自动检测"
        if panel.runModal() == .OK, let url = panel.url {
            editingPaths[item.id] = url.path
        }
    }
    #endif
}
