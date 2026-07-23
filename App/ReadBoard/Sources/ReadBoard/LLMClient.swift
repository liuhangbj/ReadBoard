import Foundation

// MARK: - LLM 配置（可 App 内覆盖，默认读 rss-curation .env 复用 key）

struct LLMProvider: Hashable {
    var name: String
    var endpoint: String
    var apiKey: String
    var model: String
}

enum LLMConfig {
    /// 从 rss-curation/.env 读取 key（复用，避免重复配置）。
    /// 优先 DeepSeek；环境变量 READBOARD_LLM_* 可覆盖。
    static func defaultProviders() -> [LLMProvider] {
        let env = loadDotEnv()
        var providers: [LLMProvider] = []

        // 环境变量覆盖优先
        if let key = ProcessInfo.processInfo.environment["READBOARD_LLM_KEY"], !key.isEmpty {
            let ep = ProcessInfo.processInfo.environment["READBOARD_LLM_ENDPOINT"]
                ?? "https://api.deepseek.com/v1/chat/completions"
            let model = ProcessInfo.processInfo.environment["READBOARD_LLM_MODEL"] ?? "deepseek-chat"
            providers.append(LLMProvider(name: "custom", endpoint: ep, apiKey: key, model: model))
            return providers
        }

        if let key = env["DEEPSEEK_API_KEY"], !key.isEmpty {
            providers.append(LLMProvider(
                name: "deepseek",
                endpoint: "https://api.deepseek.com/v1/chat/completions",
                apiKey: key, model: "deepseek-chat"))
        }
        // Kimi 作为备选（若有）
        if let key = env["KIMI_API_KEY"], !key.isEmpty {
            providers.append(LLMProvider(
                name: "kimi",
                endpoint: "https://api.moonshot.cn/v1/chat/completions",
                apiKey: key, model: "kimi-k2-0905-preview"))
        }
        return providers
    }

    private static func loadDotEnv() -> [String: String] {
        let path = NSHomeDirectory() + "/agents/projects/rss-curation/.env"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var dict: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            dict[k] = v
        }
        return dict
    }
}

// MARK: - OpenAI 兼容客户端（fallback 链）

enum LLMError: Error, LocalizedError {
    case noProvider
    case httpError(Int, String)
    case emptyResponse
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .noProvider: return "未配置 LLM API Key"
        case .httpError(let c, let b): return "LLM HTTP \(c): \(b.prefix(200))"
        case .emptyResponse: return "LLM 返回空"
        case .invalidJSON: return "LLM 返回非 JSON"
        }
    }
}

struct ChatMessage {
    let role: String
    let content: String
}

final class LLMClient {
    private let providers: [LLMProvider]

    init(providers: [LLMProvider] = LLMConfig.defaultProviders()) {
        self.providers = providers.filter { !$0.apiKey.isEmpty }
    }

    var isAvailable: Bool { !providers.isEmpty }

    /// 按 fallback 链调用，返回首个非空结果
    func chat(messages: [ChatMessage], temperature: Double = 0.3, maxTokens: Int = 4096) async throws -> (content: String, model: String) {
        guard isAvailable else { throw LLMError.noProvider }
        var lastError: Error = LLMError.emptyResponse
        for p in providers {
            do {
                let text = try await call(p, messages: messages, temperature: temperature, maxTokens: maxTokens)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (text, p.model)
                }
            } catch {
                lastError = error
                continue  // fallback 下一个
            }
        }
        throw lastError
    }

    private func call(_ p: LLMProvider, messages: [ChatMessage], temperature: Double, maxTokens: Int) async throws -> String {
        guard let url = URL(string: p.endpoint) else { throw LLMError.httpError(0, "bad endpoint") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": p.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code < 400 else {
            throw LLMError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.invalidJSON
        }
        return content
    }
}
