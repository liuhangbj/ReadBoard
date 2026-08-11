import ReadBoardContract
import ReadBoardUI
import SwiftUI

private struct ReadBoardAIPipelineDescriptor: Identifiable {
    let id: String
    let title: String

    static let all: [Self] = [
        .init(id: "score", title: "AI 评分"),
        .init(id: "summarize", title: "AI 摘要"),
        .init(id: "translate", title: "AI 翻译"),
        .init(id: "transcribe", title: "AI 转录"),
    ]
}

public struct ReadBoardAIContentSettingsPane: View {
    private let configuration: any ConfigurationGateway
    @State private var flags: [String: Bool] = [:]
    @State private var prompts = AIPromptConfiguration()
    @State private var saveTask: Task<Void, Never>?

    public init(configuration: any ConfigurationGateway) {
        self.configuration = configuration
    }

    public var body: some View {
        Form {
            Section {
                ForEach(ReadBoardAIPipelineDescriptor.all) { pipeline in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(pipeline.title, isOn: Binding(
                            get: { flags[pipeline.id] ?? true },
                            set: { value in
                                flags[pipeline.id] = value
                                Task { await configuration.setPipelineFlag(
                                    pipeline.id,
                                    enabled: value) }
                            }))
                        ReadBoardAIPromptEditor(
                            pipelineID: pipeline.id,
                            configuration: $prompts)
                    }
                    .padding(.vertical, 5)
                }
            } header: {
                Text("AI 内容处理开关")
            } footer: {
                Text("全局开关开启后，仍可在文件夹或订阅源中单独设置处理策略，也可对单篇内容手动执行。")
            }
        }
        .formStyle(.grouped)
        .task {
            if let snapshot = try? await configuration.snapshot() {
                flags = snapshot.pipelineFlags
                prompts = snapshot.aiPrompts
            }
        }
        .onChange(of: prompts) { _, _ in schedulePromptSave() }
        .onDisappear {
            saveTask?.cancel()
            let value = prompts
            Task { await configuration.updateAIPrompts(value) }
        }
    }

    private func schedulePromptSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let value = prompts
            await configuration.updateAIPrompts(value)
        }
    }
}

private struct ReadBoardAIPromptEditor: View {
    let pipelineID: String
    @Binding var configuration: AIPromptConfiguration

    private var mode: Binding<String> {
        Binding(
            get: { configuration.modes[pipelineID] ?? "default" },
            set: { configuration.modes[pipelineID] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("提示词")
                    .font(.caption)
                    .foregroundStyle(ReadBoardDesign.C.text2)
                Spacer()
                Picker("", selection: mode) {
                    Text("使用默认").tag("default")
                    Text("使用自定义").tag("custom")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            if mode.wrappedValue == "custom" {
                customFields
                Text("程序会把这些字段拼入固定提示词；输出格式和语言分流保持不变。")
                    .font(.caption2)
                    .foregroundStyle(ReadBoardDesign.C.text3)
            }
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private var customFields: some View {
        switch pipelineID {
        case "score":
            weightRow("内容深度", value: $configuration.scoreDepthWeight)
            weightRow("信息质量", value: $configuration.scoreQualityWeight)
            weightRow("可读性", value: $configuration.scoreReadabilityWeight)
            let weights = normalizedWeights
            Text("实际权重：\(weights.0)% / \(weights.1)% / \(weights.2)%（自动归一化为 100%）")
                .font(.caption2)
                .foregroundStyle(ReadBoardDesign.C.text3)
        case "summarize":
            pickerRow("摘要长度", selection: $configuration.summaryLength) {
                Text("100 字").tag(100)
                Text("150 字").tag(150)
                Text("200 字").tag(200)
                Text("300 字").tag(300)
            }
            pickerRow("输出风格", selection: $configuration.summaryStyle) {
                Text("精简概括").tag("concise")
                Text("完整叙述").tag("narrative")
                Text("要点列表").tag("bullets")
            }
        case "translate":
            pickerRow("翻译文风", selection: $configuration.translationStyle) {
                Text("准确忠实").tag("faithful")
                Text("自然流畅").tag("natural")
                Text("简洁凝练").tag("concise")
            }
            pickerRow("输出语言", selection: $configuration.translationLanguage) {
                Text("中文").tag("zh")
                Text("英文").tag("en")
                Text("日文").tag("ja")
            }
            HStack {
                Text("术语要求").font(.caption).foregroundStyle(ReadBoardDesign.C.text2)
                Spacer()
                TextField("如：公司名保留英文，首次出现补中文",
                          text: $configuration.translationTerms)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 310)
            }
        case "transcribe":
            pickerRow("口语程度", selection: $configuration.transcriptSpeechStyle) {
                Text("保留口语").tag("spoken")
                Text("适度整理").tag("standard")
                Text("偏书面化").tag("written")
            }
            Toggle("翻译非中文转录稿", isOn: $configuration.transcriptTranslate)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    private var normalizedWeights: (Int, Int, Int) {
        let d = max(configuration.scoreDepthWeight, 1)
        let q = max(configuration.scoreQualityWeight, 1)
        let r = max(configuration.scoreReadabilityWeight, 1)
        let total = Double(d + q + r)
        let depth = Int((Double(d) / total * 100).rounded())
        let quality = Int((Double(q) / total * 100).rounded())
        return (depth, quality, max(0, 100 - depth - quality))
    }

    private func weightRow(_ title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 5...80, step: 5) {
            HStack {
                Text(title).font(.caption).foregroundStyle(ReadBoardDesign.C.text2)
                Spacer()
                Text("\(value.wrappedValue)").font(.caption.monospacedDigit())
            }
        }
    }

    private func pickerRow<Value: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(ReadBoardDesign.C.text2)
            Spacer()
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
        }
    }
}
