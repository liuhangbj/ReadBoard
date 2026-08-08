import Foundation
import ReadBoardContract

public struct LocalConfigurationGateway: ConfigurationGateway {
    public init() {}

    public func snapshot() async -> ServiceConfigurationSnapshot {
        let dependencies = await Task.detached {
            DependencyChecker.shared.checkAllGroups().flatMap(\.items).map { item in
                DependencyStatus(id: item.id, displayName: item.displayName,
                    path: item.installed ? item.path : nil, installed: item.installed,
                    version: item.version,
                    customPathIsStale: DependencyPaths.Kind(rawValue: item.id)
                        .map(DependencyPaths.isCustomStale) ?? false)
            }
        }.value
        let export = ExportPlatformConfig.shared
        return ServiceConfigurationSnapshot(
            proxyURL: FeedFetcher.globalProxy ?? "",
            featureFlags: Dictionary(uniqueKeysWithValues: FeatureBoard.allCases.map { ($0.rawValue, $0.enabled) }),
            pipelineFlags: Dictionary(uniqueKeysWithValues: AIPipeline.allCases.map { ($0.rawValue, $0.enabled) }),
            serviceFlags: ["defuddle": UserDefaults.standard.bool(forKey: "defuddle.enabled")],
            sourceTypeFlags: Dictionary(uniqueKeysWithValues: ["article", "podcast", "youtube", "bilibili", "wechat"].map {
                ($0, UserDefaults.standard.object(forKey: "type.\($0).enabled") as? Bool ?? true)
            }),
            llmProfiles: (0..<LLMSettings.slotCount).map { index in
                let item = LLMSettings.meta(index)
                return LLMProfileMetadata(id: index, baseURL: item.baseURL, model: item.model,
                    temperature: item.temperature, disableThinking: item.disableThinking,
                    hasAPIKey: !item.apiKey.isEmpty)
            },
            dependencies: dependencies,
            exportPlatforms: ExportPlatformConfiguration(
                obsidianEnabled: export.isEnabled("obsidian"), obsidianDirectory: export.obsidianDir,
                webhookEnabled: export.isEnabled("webhook"), webhookURL: export.webhookURL,
                webhookHeaders: export.webhookHeaders),
            aiPrompts: aiPromptSnapshot())
    }

    public func setProxyURL(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        FeedFetcher.globalProxy = trimmed.isEmpty ? nil : trimmed
    }

    public func setFeatureFlag(_ id: String, enabled: Bool) async {
        guard let board = FeatureBoard(rawValue: id) else { return }
        FeatureBoard.setEnabled(board, enabled)
    }

    public func setPipelineFlag(_ id: String, enabled: Bool) async {
        guard let pipeline = AIPipeline(rawValue: id) else { return }
        AIPipeline.setEnabled(pipeline, enabled)
    }

    public func setServiceFlag(_ id: String, enabled: Bool) async {
        guard id == "defuddle" else { return }
        UserDefaults.standard.set(enabled, forKey: "defuddle.enabled")
    }

    public func setSourceTypeFlag(_ id: String, enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: "type.\(id).enabled")
    }

    public func saveLLMProfile(_ update: LLMProfileUpdate) async -> Bool {
        while LLMSettings.slotCount <= update.id { LLMSettings.addSlot() }
        let old = LLMSettings.profile(update.id)
        return LLMSettings(baseURL: update.baseURL,
                           apiKey: update.apiKey ?? old.apiKey,
                           model: update.model,
                           temperature: update.temperature,
                           disableThinking: update.disableThinking).save(toProfile: update.id)
    }

    public func addLLMProfile() async { LLMSettings.addSlot() }
    public func removeLLMProfile(id: Int) async { LLMSettings.removeSlot(at: id) }
    public func moveLLMProfile(from: Int, to: Int) async { LLMSettings.moveSlot(from: from, to: to) }

    public func testLLMProfile(_ update: LLMProfileUpdate) async -> ConnectionTestResult {
        let old = update.id < LLMSettings.slotCount ? LLMSettings.profile(update.id) : nil
        let value = LLMSettings(baseURL: update.baseURL, apiKey: update.apiKey ?? old?.apiKey ?? "",
            model: update.model, temperature: update.temperature,
            disableThinking: update.disableThinking)
        let result = await LLMClient().testConnection(value)
        return ConnectionTestResult(succeeded: result.0, message: result.1)
    }

    public func fetchLLMModels(profileID: Int, endpoint: String, apiKey: String?) async throws -> [String] {
        guard let url = URL(string: endpoint) else { throw ConfigurationError.invalidURL }
        let stored = profileID < LLMSettings.slotCount ? LLMSettings.profile(profileID).apiKey : ""
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let key = apiKey ?? stored
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object["data"] as? [[String: Any]] else {
            throw ConfigurationError.modelListUnavailable
        }
        return values.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    public func setDependencyPath(id: String, path: String) async {
        guard let kind = DependencyPaths.Kind(rawValue: id) else { return }
        DependencyPaths.setCustom(kind, path)
    }

    public func updateExportPlatforms(_ configuration: ExportPlatformConfiguration) async {
        let value = ExportPlatformConfig.shared
        value.setEnabled("obsidian", configuration.obsidianEnabled)
        value.obsidianDir = configuration.obsidianDirectory
        value.setEnabled("webhook", configuration.webhookEnabled)
        value.webhookURL = configuration.webhookURL
        value.webhookHeaders = configuration.webhookHeaders
    }

    public func updateAIPrompts(_ configuration: AIPromptConfiguration) async {
        let defaults = UserDefaults.standard
        for (id, mode) in configuration.modes {
            defaults.set(mode, forKey: "ai.prompt.\(id).mode")
        }
        defaults.set(configuration.scoreDepthWeight, forKey: AIPromptSettings.scoreDepthWeightKey)
        defaults.set(configuration.scoreQualityWeight, forKey: AIPromptSettings.scoreQualityWeightKey)
        defaults.set(configuration.scoreReadabilityWeight, forKey: AIPromptSettings.scoreReadabilityWeightKey)
        defaults.set(configuration.summaryLength, forKey: AIPromptSettings.summaryLengthKey)
        defaults.set(configuration.summaryStyle, forKey: AIPromptSettings.summaryStyleKey)
        defaults.set(configuration.translationStyle, forKey: AIPromptSettings.translationStyleKey)
        defaults.set(configuration.translationLanguage, forKey: AIPromptSettings.translationLanguageKey)
        defaults.set(String(configuration.translationTerms.prefix(500)), forKey: AIPromptSettings.translationTermsKey)
        defaults.set(configuration.transcriptSpeechStyle, forKey: AIPromptSettings.transcriptSpeechStyleKey)
        defaults.set(configuration.transcriptTranslate, forKey: AIPromptSettings.transcriptTranslateKey)
    }

    private func aiPromptSnapshot() -> AIPromptConfiguration {
        let defaults = UserDefaults.standard
        func integer(_ key: String, _ fallback: Int) -> Int {
            let value = defaults.integer(forKey: key); return value > 0 ? value : fallback
        }
        return AIPromptConfiguration(
            modes: Dictionary(uniqueKeysWithValues: AIPipeline.allCases.map {
                ($0.rawValue, AIPromptSettings.mode(for: $0).rawValue)
            }),
            scoreDepthWeight: integer(AIPromptSettings.scoreDepthWeightKey, 40),
            scoreQualityWeight: integer(AIPromptSettings.scoreQualityWeightKey, 35),
            scoreReadabilityWeight: integer(AIPromptSettings.scoreReadabilityWeightKey, 25),
            summaryLength: integer(AIPromptSettings.summaryLengthKey, 150),
            summaryStyle: defaults.string(forKey: AIPromptSettings.summaryStyleKey) ?? "concise",
            translationStyle: defaults.string(forKey: AIPromptSettings.translationStyleKey) ?? "natural",
            translationLanguage: defaults.string(forKey: AIPromptSettings.translationLanguageKey) ?? "zh",
            translationTerms: defaults.string(forKey: AIPromptSettings.translationTermsKey) ?? "",
            transcriptSpeechStyle: defaults.string(forKey: AIPromptSettings.transcriptSpeechStyleKey) ?? "standard",
            transcriptTranslate: defaults.object(forKey: AIPromptSettings.transcriptTranslateKey) as? Bool ?? true)
    }
}

private enum ConfigurationError: LocalizedError {
    case invalidURL, modelListUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidURL: "模型列表 URL 无效"
        case .modelListUnavailable: "端点未返回模型列表，请检查密钥或服务权限"
        }
    }
}
