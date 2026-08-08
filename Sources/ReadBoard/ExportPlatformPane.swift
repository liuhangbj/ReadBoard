import SwiftUI
import AppKit
import ReadBoardContract

// MARK: - 导出平台配置

public struct ExportPlatformPane: View {
    private let configuration: any ConfigurationGateway
    @State private var obsidianOn = false
    @State private var webhookOn = false

    @State private var obsidianDir = ""
    @State private var webhookURL = ""
    @State private var webhookHeaders    = ""

    public init(configuration: any ConfigurationGateway) { self.configuration = configuration }

    public var body: some View {
        Form {
            Section {
                platformToggle(key: "obsidian", title: "Obsidian / Markdown 目录", isOn: $obsidianOn)
                if obsidianOn { obsidianConfig }
            } header: {
                Text("笔记软件")
            }

            Section {
                platformToggle(key: "webhook", title: "Webhook", isOn: $webhookOn)
                if webhookOn { webhookConfig }
            } header: {
                Text("通用")
            } footer: {
                Text("开启平台后，可在「导出规则」页面创建规则将处理后的内容同步至该平台")
            }
        }
        .formStyle(.grouped)
        .task {
            let value = await configuration.snapshot().exportPlatforms
            obsidianOn = value.obsidianEnabled; obsidianDir = value.obsidianDirectory
            webhookOn = value.webhookEnabled; webhookURL = value.webhookURL
            webhookHeaders = value.webhookHeaders
                .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    @ViewBuilder
    private func platformToggle(key: String, title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { v in
                isOn.wrappedValue = v
                persist()
            }
        ))
        .tint(Color.rbAccent)
    }

    // MARK: - Obsidian

    @ViewBuilder
    private var obsidianConfig: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Color.rbText3)
            Text(obsidianDir.isEmpty ? "未选择 Vault 目录" : obsidianDir)
                .font(.caption).foregroundStyle(Color.rbText3).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("选择…") { pickObsidianDir() }.controlSize(.small)
        }
        .padding(6).background(Color.rbBgSidebar).clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
    }

    // MARK: - Webhook

    @ViewBuilder
    private var webhookConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("URL").font(.caption).foregroundStyle(Color.rbText3).frame(width: 40, alignment: .leading)
                TextField("https://…", text: $webhookURL).textFieldStyle(.roundedBorder).font(.caption)
                    .onChange(of: webhookURL) { _, _ in persist() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("自定义 Header（每行 Key: Value）").font(.caption).foregroundStyle(Color.rbText3)
                TextEditor(text: $webhookHeaders)
                    .font(.system(size: 11, design: .monospaced)).frame(minHeight: 52)
                    .overlay(RoundedRectangle(cornerRadius: RB.Radius.sm).stroke(Color.rbSeparator, lineWidth: 0.5))
                    .onChange(of: webhookHeaders) { _, v in
                        var dict: [String: String] = [:]
                        for line in v.split(separator: "\n") {
                            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                            if parts.count == 2 { dict[parts[0]] = parts[1] }
                        }
                        persist(headers: dict)
                    }
            }
        }
    }

    private func pickObsidianDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "选择"; panel.message = "选择 Obsidian Vault 目录"
        if panel.runModal() == .OK, let url = panel.url {
            obsidianDir = url.path
            persist()
        }
    }

    private func persist(headers: [String: String]? = nil) {
        let parsedHeaders = headers ?? Dictionary(uniqueKeysWithValues: webhookHeaders
            .split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            })
        let value = ExportPlatformConfiguration(obsidianEnabled: obsidianOn,
            obsidianDirectory: obsidianDir, webhookEnabled: webhookOn,
            webhookURL: webhookURL, webhookHeaders: parsedHeaders)
        Task { await configuration.updateExportPlatforms(value) }
    }
}
