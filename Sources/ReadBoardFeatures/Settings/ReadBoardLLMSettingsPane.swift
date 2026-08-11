import ReadBoardContract
import ReadBoardUI
import SwiftUI

private struct ReadBoardLLMPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let baseURL: String
    let model: String
    let temperature: Double

    static let all: [Self] = [
        .init(id: "deepseek", title: "DeepSeek",
              baseURL: "https://api.deepseek.com/v1/chat/completions",
              model: "deepseek-chat", temperature: 0.3),
        .init(id: "moonshot", title: "Moonshot 开发者 API",
              baseURL: "https://api.moonshot.cn/v1/chat/completions",
              model: "kimi-k2", temperature: 1),
        .init(id: "kimi-coding", title: "Kimi Coding Plan",
              baseURL: "https://api.kimi.com/coding/v1/chat/completions",
              model: "kimi-k2", temperature: 1),
        .init(id: "openrouter", title: "OpenRouter",
              baseURL: "https://openrouter.ai/api/v1/chat/completions",
              model: "", temperature: 0.3),
        .init(id: "openai", title: "OpenAI",
              baseURL: "https://api.openai.com/v1/chat/completions",
              model: "gpt-4o-mini", temperature: 0.3),
        .init(id: "custom", title: "自定义（OpenAI 兼容）",
              baseURL: "", model: "", temperature: 0.3),
    ]
}

public struct ReadBoardLLMSettingsPane: View {
    private let configuration: any ConfigurationGateway
    @State private var profiles: [LLMProfileMetadata] = []
    @State private var isLoading = true

    public init(configuration: any ConfigurationGateway) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM 模型")
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                    Text("从上到下依次尝试；空模型会自动跳过。密钥只写入服务端，永不回传明文。")
                        .font(.caption)
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                Spacer()
                Button {
                    Task {
                        await configuration.addLLMProfile()
                        await reload()
                    }
                } label: {
                    Label("添加模型", systemImage: "plus")
                }
                .buttonStyle(ReadBoardSecondaryButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ReadBoardHairline()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if profiles.isEmpty {
                ContentUnavailableView(
                    "还没有模型",
                    systemImage: "brain.head.profile",
                    description: Text("添加一个 OpenAI 兼容模型后即可启用评分、摘要和翻译。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                            ReadBoardLLMProfileCard(
                                index: index,
                                profile: profile,
                                canMoveUp: index > 0,
                                canMoveDown: index < profiles.count - 1,
                                configuration: configuration,
                                onReload: { await reload() })
                                .id("\(profile.id)|\(profile.baseURL)|\(profile.model)|\(profile.hasAPIKey)")
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task { await reload() }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        if let loaded = try? await configuration.snapshot().llmProfiles {
            profiles = loaded.sorted(by: { $0.id < $1.id })
        }
        isLoading = false
    }
}

private struct ReadBoardLLMProfileCard: View {
    let index: Int
    let profile: LLMProfileMetadata
    let canMoveUp: Bool
    let canMoveDown: Bool
    let configuration: any ConfigurationGateway
    let onReload: @MainActor () async -> Void

    @State private var presetID = "custom"
    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var model: String
    @State private var temperature: Double
    @State private var disableThinking: Bool
    @State private var availableModels: [String] = []
    @State private var isTesting = false
    @State private var isFetchingModels = false
    @State private var resultMessage: String?
    @State private var resultSucceeded = false

    init(
        index: Int,
        profile: LLMProfileMetadata,
        canMoveUp: Bool,
        canMoveDown: Bool,
        configuration: any ConfigurationGateway,
        onReload: @escaping @MainActor () async -> Void
    ) {
        self.index = index
        self.profile = profile
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.configuration = configuration
        self.onReload = onReload
        _baseURL = State(initialValue: profile.baseURL)
        _model = State(initialValue: profile.model)
        _temperature = State(initialValue: profile.temperature)
        _disableThinking = State(initialValue: profile.disableThinking)
    }

    var body: some View {
        ReadBoardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(ReadBoardDesign.C.text3)
                    Text("模型 \(index + 1)")
                        .font(.system(size: 14, weight: .semibold))
                    if profile.hasAPIKey {
                        ReadBoardBadge(text: "密钥已保存", color: ReadBoardDesign.C.scoreHigh)
                    }
                    Spacer()
                    Picker("预设", selection: $presetID) {
                        ForEach(ReadBoardLLMPreset.all) { preset in
                            Text(preset.title).tag(preset.id)
                        }
                    }
                    .frame(width: 190)
                    .onChange(of: presetID) { _, value in applyPreset(value) }
                    Button { move(to: index - 1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(ReadBoardQuietButtonStyle()).disabled(!canMoveUp)
                    Button { move(to: index + 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(ReadBoardQuietButtonStyle()).disabled(!canMoveDown)
                    Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                        .buttonStyle(ReadBoardQuietButtonStyle())
                }

                LabeledContent("API 地址") {
                    TextField("https://…/v1/chat/completions", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                }

                LabeledContent("API Key") {
                    SecureField(profile.hasAPIKey ? "留空则保留已保存密钥" : "输入 API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                }

                LabeledContent("模型") {
                    HStack(spacing: 8) {
                        if availableModels.isEmpty {
                            TextField("模型 ID", text: $model)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $model) {
                                if !model.isEmpty, !availableModels.contains(model) {
                                    Text(model).tag(model)
                                }
                                ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                        Button {
                            Task { await fetchModels() }
                        } label: {
                            if isFetchingModels { ProgressView().controlSize(.small) }
                            else { Text("获取模型") }
                        }
                        .disabled(baseURL.isEmpty || isFetchingModels)
                    }
                    .frame(maxWidth: 520)
                }

                LabeledContent("温度 \(temperature, specifier: "%.1f")") {
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                        .frame(maxWidth: 320)
                }
                Toggle("结构化任务关闭模型思考", isOn: $disableThinking)

                if let resultMessage {
                    Label(resultMessage, systemImage: resultSucceeded
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(resultSucceeded
                            ? ReadBoardDesign.C.scoreHigh : ReadBoardDesign.C.scoreLow)
                }

                HStack {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting { ProgressView().controlSize(.small) }
                        else { Text("测试连接") }
                    }
                    .disabled(baseURL.isEmpty || model.isEmpty || isTesting)
                    if profile.hasAPIKey {
                        Button("清除已保存密钥", role: .destructive) {
                            Task { await save(apiKeyOverride: "") }
                        }
                        .buttonStyle(ReadBoardQuietButtonStyle())
                    }
                    Spacer()
                    Button("保存") { Task { await save(apiKeyOverride: nil) } }
                        .buttonStyle(ReadBoardPrimaryButtonStyle())
                        .disabled(baseURL.isEmpty || model.isEmpty)
                }
            }
        }
    }

    private var update: LLMProfileUpdate {
        LLMProfileUpdate(
            id: profile.id,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: temperature,
            disableThinking: disableThinking,
            apiKey: apiKey.isEmpty ? nil : apiKey)
    }

    private func applyPreset(_ id: String) {
        guard let preset = ReadBoardLLMPreset.all.first(where: { $0.id == id }),
              id != "custom" else { return }
        baseURL = preset.baseURL
        model = preset.model
        temperature = preset.temperature
        disableThinking = ["deepseek", "moonshot", "kimi-coding"].contains(id)
        availableModels = []
    }

    private func save(apiKeyOverride: String?) async {
        var payload = update
        if let apiKeyOverride {
            payload.apiKey = apiKeyOverride
        }
        let ok = await configuration.saveLLMProfile(payload)
        resultSucceeded = ok
        resultMessage = ok ? "设置已保存" : "保存失败"
        if ok {
            apiKey = ""
            await onReload()
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let result = await configuration.testLLMProfile(update)
        resultSucceeded = result.succeeded
        resultMessage = result.message
    }

    private func fetchModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            availableModels = try await configuration.fetchLLMModels(
                profileID: profile.id,
                endpoint: modelsEndpoint,
                apiKey: apiKey.isEmpty ? nil : apiKey)
                .sorted()
            resultSucceeded = true
            resultMessage = "已获取 \(availableModels.count) 个模型"
        } catch {
            resultSucceeded = false
            resultMessage = error.localizedDescription
        }
    }

    private var modelsEndpoint: String {
        if baseURL.hasSuffix("/chat/completions") {
            return String(baseURL.dropLast("/chat/completions".count)) + "/models"
        }
        return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models"
    }

    private func move(to destination: Int) {
        Task {
            await configuration.moveLLMProfile(from: index, to: destination)
            await onReload()
        }
    }

    private func remove() {
        Task {
            await configuration.removeLLMProfile(id: profile.id)
            await onReload()
        }
    }
}
