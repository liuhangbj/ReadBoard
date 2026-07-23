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

    // NSLock 保护下的缓存，声明 nonisolated(unsafe) 豁免 Swift 6 全局可变状态检查
    nonisolated(unsafe) private static var cachedDotEnv: [String: String]?
    private static let dotEnvLock = NSLock()

    private static func loadDotEnv() -> [String: String] {
        // R6: .env 解析结果缓存——chat 每次调用都走 activeProviders，不能每次都读盘解析
        dotEnvLock.lock()
        defer { dotEnvLock.unlock() }
        if let cached = cachedDotEnv { return cached }
        let path = NSHomeDirectory() + "/agents/projects/rss-curation/.env"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            cachedDotEnv = [:]
            return [:]
        }
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
        cachedDotEnv = dict
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

    /// 每次调用都读当前配置（设置页改后立即生效，无需重启）。
    /// App 内保存的配置排最前，其后是 .env 探测的 fallback 链。
    private func activeProviders() -> [LLMProvider] {
        var list: [LLMProvider] = []
        let s = LLMSettings.current()
        if s.isValid {
            list.append(LLMProvider(name: "app", endpoint: s.baseURL, apiKey: s.apiKey, model: s.model))
        }
        // fallback：.env 链（去重——若和 App 配置同 endpoint+model 就不重复）
        for p in LLMConfig.defaultProviders() where !p.apiKey.isEmpty {
            if !list.contains(where: { $0.endpoint == p.endpoint && $0.model == p.model }) {
                list.append(p)
            }
        }
        return list
    }

    var isAvailable: Bool { !activeProviders().isEmpty }

    /// 按 fallback 链调用，返回首个非空结果。
    /// R6 错误分类：
    /// - 401/403（鉴权失败）：换 key 也没用——但同链其他 provider 是不同 key，可继续 fallback；
    ///   若链上最后一个也 401/403，抛鉴权错误而不是笼统的 emptyResponse。
    /// - 429（限流）：同 provider 退避重试 2 次（2s/5s）再 fallback 下一个。
    /// - 网络错误/5xx/解析错误：直接 fallback 下一个。
    func chat(messages: [ChatMessage], temperature: Double = 0.3, maxTokens: Int = 4096) async throws -> (content: String, model: String) {
        let providers = activeProviders()
        guard !providers.isEmpty else { throw LLMError.noProvider }
        var lastError: Error = LLMError.emptyResponse
        for p in providers {
            do {
                let text = try await callWithRateLimitRetry(p, messages: messages, temperature: temperature, maxTokens: maxTokens)
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

    /// 429 限流时同 provider 退避重试（最多 2 次），其余错误直接抛出走 fallback
    private func callWithRateLimitRetry(_ p: LLMProvider, messages: [ChatMessage], temperature: Double, maxTokens: Int) async throws -> String {
        var delays: [UInt64] = [2_000_000_000, 5_000_000_000]  // 2s, 5s
        while true {
            do {
                return try await call(p, messages: messages, temperature: temperature, maxTokens: maxTokens)
            } catch LLMError.httpError(let code, _) where code == 429 && !delays.isEmpty {
                let d = delays.removeFirst()
                try? await Task.sleep(nanoseconds: d)
                continue
            }
        }
    }

    /// 测试连接：只测设置页当前编辑的这条配置，不走 fallback 链
    /// （走链的话 app 配置失效会被 .env 兜底掩盖，用户误以为自己的配置通了）
    func testConnection() async -> (Bool, String) {
        let s = LLMSettings.current()
        guard s.isValid else { return (false, "配置不完整：baseURL / apiKey / model 都要填") }
        let p = LLMProvider(name: "app", endpoint: s.baseURL, apiKey: s.apiKey, model: s.model)
        do {
            let text = try await call(
                p, messages: [ChatMessage(role: "user", content: "回复\"ok\"两个字即可")],
                temperature: 0, maxTokens: 10)
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)
            return (true, "连接成功（\(p.model)）：\(preview)")
        } catch LLMError.httpError(let code, _) where code == 401 || code == 403 {
            return (false, "鉴权失败（HTTP \(code)）：API Key 无效或无权限，请检查 Key")
        } catch LLMError.httpError(let code, let body) where code == 429 {
            return (false, "限流（HTTP 429）：额度不足或触发限流，稍后再试。\(body.prefix(100))")
        } catch {
            return (false, error.localizedDescription)
        }
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
