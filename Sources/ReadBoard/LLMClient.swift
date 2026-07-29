import Foundation

// MARK: - LLM 配置（全部来自 App 内模型配置页，不读 .env / 不读外部环境变量）

public struct LLMProvider: Hashable {
    var name: String
    var endpoint: String
    var apiKey: String
    var model: String
    /// 温度：本质是模型属性（推理模型如 kimi-k2 强制 1，普通模型 0.3 即可）。
    /// 默认 0.3 兼容旧行为；Kimi 类 preset 会设 1。
    var temperature: Double = 0.3
}

// MARK: - OpenAI 兼容客户端（fallback 链）

public enum LLMError: Error, LocalizedError {
    case noProvider
    case httpError(Int, String)
    case emptyResponse
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .noProvider: return "未配置 LLM API Key"
        case .httpError(let c, let b): return "LLM HTTP \(c): \(b.prefix(200))"
        case .emptyResponse: return "LLM 返回空"
        case .invalidJSON: return "LLM 返回非 JSON"
        }
    }
}

public struct ChatMessage {
    let role: String
    let content: String
}

public final class LLMClient {

    /// URLSession 取消通常表现为 URLError.cancelled，而不是 CancellationError。
    /// 两者都必须终止 fallback 链，不能当成普通网络失败继续请求下一个模型。
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// 每次调用都读当前配置（设置页改后立即生效，无需重启）。
    /// 多模型按列表从上到下 fallback（空模型跳过）。不读 .env / 不读外部环境变量。
    private func activeProviders() -> [LLMProvider] {
        var list: [LLMProvider] = []
        for (i, s) in LLMSettings.profiles().enumerated() {
            list.append(LLMProvider(name: "profile\(i + 1)", endpoint: s.baseURL, apiKey: s.apiKey, model: s.model, temperature: s.temperature))
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
    func chat(messages: [ChatMessage], maxTokens: Int = 4096) async throws -> (content: String, model: String) {
        try Task.checkCancellation()
        let providers = activeProviders()
        guard !providers.isEmpty else { throw LLMError.noProvider }
        var lastError: Error = LLMError.emptyResponse
        for p in providers {
            try Task.checkCancellation()
            do {
                let text = try await callWithRateLimitRetry(p, messages: messages, maxTokens: maxTokens)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (text, p.model)
                }
            } catch {
                if Self.isCancellation(error) || Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                continue  // fallback 下一个
            }
        }
        throw lastError
    }

    /// 429 限流时同 provider 退避重试（最多 2 次），其余错误直接抛出走 fallback
    private func callWithRateLimitRetry(_ p: LLMProvider, messages: [ChatMessage], maxTokens: Int) async throws -> String {
        var delays: [UInt64] = [2_000_000_000, 5_000_000_000]  // 2s, 5s
        while true {
            try Task.checkCancellation()
            do {
                return try await call(p, messages: messages, maxTokens: maxTokens)
            } catch {
                if Self.isCancellation(error) || Task.isCancelled {
                    throw CancellationError()
                }
                guard case LLMError.httpError(let code, _) = error,
                      code == 429, !delays.isEmpty else { throw error }
                let d = delays.removeFirst()
                // 不吞 CancellationError：worker 超时后必须立刻结束，不能继续重试并产生费用。
                try await Task.sleep(nanoseconds: d)
            }
        }
    }

    /// 测试连接：只测传入的这条配置，不走 fallback 链
    func testConnection(_ s: LLMSettings) async -> (Bool, String) {
        guard s.isValid else { return (false, "配置不完整：baseURL / apiKey / model 都要填") }
        let p = LLMProvider(name: "test", endpoint: s.baseURL, apiKey: s.apiKey, model: s.model, temperature: 1)
        do {
            let text = try await call(
                p, messages: [ChatMessage(role: "user", content: "回复\"ok\"两个字即可")],
                maxTokens: 10)
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

    private func call(_ p: LLMProvider, messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        guard let url = URL(string: p.endpoint) else { throw LLMError.httpError(0, "bad endpoint") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": p.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": p.temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Task.checkCancellation()
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
