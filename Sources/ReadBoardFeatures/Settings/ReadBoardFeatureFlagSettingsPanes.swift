import ReadBoardContract
import ReadBoardUI
import SwiftUI

private struct ReadBoardFeatureBoardDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String

    static let all: [Self] = [
        .init(id: "media", title: "多平台订阅",
              subtitle: "podcast · video · social media 的抓取与入队",
              icon: "waveform.circle"),
        .init(id: "fulltext", title: "全文提取",
              subtitle: "defuddle / CDP 全文提取与回填",
              icon: "doc.text.magnifyingglass"),
        .init(id: "ai", title: "AI 内容处理",
              subtitle: "AI 评分 · AI 摘要 · AI 翻译 · AI 转录",
              icon: "brain.head.profile"),
        .init(id: "export", title: "导出规则",
              subtitle: "按条件导出到 Obsidian / Markdown / Webhook",
              icon: "square.and.arrow.up"),
    ]
}

public struct ReadBoardFeatureBoardSettingsPane: View {
    private let configuration: any ConfigurationGateway
    @State private var states: [String: Bool] = [:]

    public init(configuration: any ConfigurationGateway) {
        self.configuration = configuration
    }

    public var body: some View {
        Form {
            Section {
                ForEach(ReadBoardFeatureBoardDescriptor.all) { board in
                    HStack(spacing: ReadBoardDesign.Space.md) {
                        Image(systemName: board.icon)
                            .readBoardTextRole(.item)
                            .foregroundStyle(ReadBoardDesign.C.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(board.title)
                                .readBoardTextRole(.itemTitle)
                            Text(board.subtitle)
                                .readBoardTextRole(.detail)
                                .foregroundStyle(ReadBoardDesign.C.text2)
                        }
                        Spacer()
                        Toggle("", isOn: featureBinding(board.id))
                            .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                ReadBoardSettingsSectionTitle("功能开关")
            } footer: {
                Text("关闭板块后，该板块下的所有自动与手动功能都会停用。")
                    .readBoardTextRole(.detail)
            }
        }
        .formStyle(.grouped)
        .task {
            if let loaded = try? await configuration.snapshot().featureFlags {
                states = loaded
            }
        }
    }

    private func featureBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { states[id] ?? true },
            set: { updateFeature(id: id, enabled: $0) })
    }

    private func updateFeature(id: String, enabled: Bool) {
        states[id] = enabled
        let gateway = configuration
        Task { await gateway.setFeatureFlag(id, enabled: enabled) }
    }
}

public struct ReadBoardFulltextSettingsPane: View {
    private let configuration: any ConfigurationGateway
    @State private var enabled = false
    @State private var dependencies: [DependencyStatus] = []
    @State private var missingDependencies: [String] = []
    @State private var showMissingAlert = false

    public init(configuration: any ConfigurationGateway) {
        self.configuration = configuration
    }

    public var body: some View {
        Form {
            Section {
                ReadBoardSettingsToggleRow(
                    "启用 defuddle",
                    detail: enabled ? "已开启" : "已关闭",
                    isOn: Binding(
                        get: { enabled },
                        set: { value in updateEnabled(value) }))
            } footer: {
                Text("基于 Node.js 的服务端网页正文提取引擎，与 Obsidian Web Clipper 使用相同核心。")
                    .readBoardTextRole(.detail)
            }
        }
        .formStyle(.grouped)
        .task {
            if let snapshot = try? await configuration.snapshot() {
                enabled = snapshot.serviceFlags["defuddle"] ?? false
                dependencies = snapshot.dependencies
            }
        }
        .alert("defuddle 依赖缺失", isPresented: $showMissingAlert) {
            Button("重新检测") { Task { await reloadAndEnable() } }
            Button("关闭", role: .cancel) {
                enabled = false
                Task { await configuration.setServiceFlag("defuddle", enabled: false) }
            }
        } message: {
            Text("缺少：\(missingDependencies.joined(separator: "、"))\n\n请先在依赖页面完成安装或在 Core 主机重新检测。")
        }
    }

    private func updateEnabled(_ value: Bool) {
        if !value {
            enabled = false
            Task { await configuration.setServiceFlag("defuddle", enabled: false) }
            return
        }
        let missing = dependencyProblems()
        if missing.isEmpty {
            enabled = true
            Task { await configuration.setServiceFlag("defuddle", enabled: true) }
        } else {
            missingDependencies = missing
            showMissingAlert = true
        }
    }

    private func reloadAndEnable() async {
        guard let loaded = try? await configuration.snapshot().dependencies else { return }
        dependencies = loaded
        let missing = dependencyProblems()
        if missing.isEmpty {
            enabled = true
            showMissingAlert = false
            await configuration.setServiceFlag("defuddle", enabled: true)
        } else {
            missingDependencies = missing
        }
    }

    private func dependencyProblems() -> [String] {
        var result: [String] = []
        if dependencies.first(where: { $0.id == "node" })?.installed != true {
            result.append("node")
        }
        if dependencies.first(where: { $0.id == "defuddleEngine" })?.installed != true {
            result.append("defuddle 引擎")
        }
        return result
    }
}
