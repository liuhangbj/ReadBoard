import ReadBoardContract
import ReadBoardUI
import SwiftUI

#if os(macOS)
import AppKit
#endif

public struct ReadBoardExportPlatformSettingsPane: View {
    private let configuration: any ConfigurationGateway
    private let allowsServerPathEditing: Bool

    @State private var value = ExportPlatformConfiguration()
    @State private var webhookHeaders = ""
    @State private var saveTask: Task<Void, Never>?

    public init(
        configuration: any ConfigurationGateway,
        allowsServerPathEditing: Bool
    ) {
        self.configuration = configuration
        self.allowsServerPathEditing = allowsServerPathEditing
    }

    public var body: some View {
        Form {
            Section("笔记软件") {
                Toggle("Obsidian / Markdown 目录", isOn: $value.obsidianEnabled)
                    .onChange(of: value.obsidianEnabled) { _, _ in scheduleSave() }
                if value.obsidianEnabled { obsidianDirectoryRow }
            }

            Section {
                Toggle("Webhook", isOn: $value.webhookEnabled)
                    .onChange(of: value.webhookEnabled) { _, _ in scheduleSave() }
                if value.webhookEnabled {
                    TextField("https://…", text: $value.webhookURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: value.webhookURL) { _, _ in scheduleSave() }
                    Text("自定义 Header（每行 Key: Value）")
                        .font(.caption)
                        .foregroundStyle(ReadBoardDesign.C.text3)
                    TextEditor(text: $webhookHeaders)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 72)
                        .overlay(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.sm)
                            .stroke(ReadBoardDesign.C.separator, lineWidth: 0.5))
                        .onChange(of: webhookHeaders) { _, _ in scheduleSave() }
                }
            } header: {
                Text("通用")
            } footer: {
                Text("开启平台后，可在“导出规则”页面创建规则，将处理后的内容同步至目标平台。")
            }
        }
        .formStyle(.grouped)
        .task {
            if let loaded = try? await configuration.snapshot().exportPlatforms {
                value = loaded
                webhookHeaders = value.webhookHeaders.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            }
        }
        .onDisappear {
            saveTask?.cancel()
            persist()
        }
    }

    @ViewBuilder
    private var obsidianDirectoryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(ReadBoardDesign.C.text3)
            Text(value.obsidianDirectory.isEmpty ? "未设置 Vault 目录" : value.obsidianDirectory)
                .font(.caption)
                .foregroundStyle(ReadBoardDesign.C.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            #if os(macOS)
            if allowsServerPathEditing {
                Button("选择…", action: pickDirectory).controlSize(.small)
            }
            #endif
        }
        if !allowsServerPathEditing {
            Text("这是 ReadBoard 服务端目录，只能在 Core 主机修改。")
                .font(.caption2)
                .foregroundStyle(ReadBoardDesign.C.text3)
        }
    }

    #if os(macOS)
    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 Obsidian Vault 目录"
        if panel.runModal() == .OK, let url = panel.url {
            value.obsidianDirectory = url.path
            persist()
        }
    }
    #endif

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        value.webhookHeaders = Dictionary(uniqueKeysWithValues: webhookHeaders
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && !parts[0].isEmpty ? (parts[0], parts[1]) : nil
            })
        let payload = value
        Task { await configuration.updateExportPlatforms(payload) }
    }
}
