import Foundation

public struct ExportPlatformConfiguration: Codable, Equatable, Sendable {
    public var obsidianEnabled: Bool
    public var obsidianDirectory: String
    public var webhookEnabled: Bool
    public var webhookURL: String
    public var webhookHeaders: [String: String]
    public init(obsidianEnabled: Bool = false, obsidianDirectory: String = "",
                webhookEnabled: Bool = false, webhookURL: String = "",
                webhookHeaders: [String: String] = [:]) {
        self.obsidianEnabled = obsidianEnabled; self.obsidianDirectory = obsidianDirectory
        self.webhookEnabled = webhookEnabled; self.webhookURL = webhookURL
        self.webhookHeaders = webhookHeaders
    }
}

public struct LLMProfileMetadata: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public var baseURL: String
    public var model: String
    public var temperature: Double
    public var disableThinking: Bool
    public var hasAPIKey: Bool
    public init(id: Int, baseURL: String = "", model: String = "", temperature: Double = 0.3,
                disableThinking: Bool = false, hasAPIKey: Bool = false) {
        self.id = id; self.baseURL = baseURL; self.model = model; self.temperature = temperature
        self.disableThinking = disableThinking; self.hasAPIKey = hasAPIKey
    }
}

public struct LLMProfileUpdate: Codable, Equatable, Sendable {
    public let id: Int
    public var baseURL: String
    public var model: String
    public var temperature: Double
    public var disableThinking: Bool
    /// nil 保留原密钥；空字符串清除；其他值替换。响应永不返回密钥。
    public var apiKey: String?
    public init(id: Int, baseURL: String, model: String, temperature: Double,
                disableThinking: Bool, apiKey: String? = nil) {
        self.id = id; self.baseURL = baseURL; self.model = model; self.temperature = temperature
        self.disableThinking = disableThinking; self.apiKey = apiKey
    }
}

public struct DependencyStatus: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let path: String?
    public let installed: Bool
    public let version: String?
    public let customPathIsStale: Bool
    public init(id: String, displayName: String, path: String?, installed: Bool,
                version: String?, customPathIsStale: Bool = false) {
        self.id = id; self.displayName = displayName; self.path = path
        self.installed = installed; self.version = version; self.customPathIsStale = customPathIsStale
    }
}

public struct AIPromptConfiguration: Codable, Equatable, Sendable {
    public var modes: [String: String]
    public var scoreDepthWeight: Int
    public var scoreQualityWeight: Int
    public var scoreReadabilityWeight: Int
    public var summaryLength: Int
    public var summaryStyle: String
    public var translationStyle: String
    public var translationLanguage: String
    public var translationTerms: String
    public var transcriptSpeechStyle: String
    public var transcriptTranslate: Bool
    public init(modes: [String: String] = [:], scoreDepthWeight: Int = 40,
                scoreQualityWeight: Int = 35, scoreReadabilityWeight: Int = 25,
                summaryLength: Int = 150, summaryStyle: String = "concise",
                translationStyle: String = "natural", translationLanguage: String = "zh",
                translationTerms: String = "", transcriptSpeechStyle: String = "standard",
                transcriptTranslate: Bool = true) {
        self.modes = modes; self.scoreDepthWeight = scoreDepthWeight
        self.scoreQualityWeight = scoreQualityWeight; self.scoreReadabilityWeight = scoreReadabilityWeight
        self.summaryLength = summaryLength; self.summaryStyle = summaryStyle
        self.translationStyle = translationStyle; self.translationLanguage = translationLanguage
        self.translationTerms = translationTerms; self.transcriptSpeechStyle = transcriptSpeechStyle
        self.transcriptTranslate = transcriptTranslate
    }
}

public struct ServiceConfigurationSnapshot: Codable, Equatable, Sendable {
    public var proxyURL: String
    public var featureFlags: [String: Bool]
    public var pipelineFlags: [String: Bool]
    public var serviceFlags: [String: Bool]
    public var sourceTypeFlags: [String: Bool]
    public var llmProfiles: [LLMProfileMetadata]
    public var dependencies: [DependencyStatus]
    public var exportPlatforms: ExportPlatformConfiguration
    public var aiPrompts: AIPromptConfiguration
    public init(proxyURL: String = "", featureFlags: [String: Bool] = [:],
                pipelineFlags: [String: Bool] = [:], serviceFlags: [String: Bool] = [:],
                sourceTypeFlags: [String: Bool] = [:],
                llmProfiles: [LLMProfileMetadata] = [],
                dependencies: [DependencyStatus] = [],
                exportPlatforms: ExportPlatformConfiguration = .init(),
                aiPrompts: AIPromptConfiguration = .init()) {
        self.proxyURL = proxyURL; self.featureFlags = featureFlags; self.pipelineFlags = pipelineFlags
        self.serviceFlags = serviceFlags
        self.sourceTypeFlags = sourceTypeFlags
        self.llmProfiles = llmProfiles; self.dependencies = dependencies
        self.exportPlatforms = exportPlatforms
        self.aiPrompts = aiPrompts
    }
}

public struct ConnectionTestResult: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let message: String
    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded; self.message = message
    }
}

public protocol ConfigurationGateway: Sendable {
    func snapshot() async throws -> ServiceConfigurationSnapshot
    func setProxyURL(_ value: String) async
    func setFeatureFlag(_ id: String, enabled: Bool) async
    func setPipelineFlag(_ id: String, enabled: Bool) async
    func setServiceFlag(_ id: String, enabled: Bool) async
    func setSourceTypeFlag(_ id: String, enabled: Bool) async
    @discardableResult func saveLLMProfile(_ update: LLMProfileUpdate) async -> Bool
    func addLLMProfile() async
    func removeLLMProfile(id: Int) async
    func moveLLMProfile(from: Int, to: Int) async
    func testLLMProfile(_ update: LLMProfileUpdate) async -> ConnectionTestResult
    func fetchLLMModels(profileID: Int, endpoint: String, apiKey: String?) async throws -> [String]
    func setDependencyPath(id: String, path: String) async
    func updateExportPlatforms(_ configuration: ExportPlatformConfiguration) async
    func updateAIPrompts(_ configuration: AIPromptConfiguration) async
}
