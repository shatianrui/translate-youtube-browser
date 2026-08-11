import Foundation

enum TranslationError: LocalizedError {
    case missingAPIKey(TranslationProvider)
    case httpError(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "未配置 \(provider.displayName) 的 API Key,请在设置中填写"
        case .httpError(let code, let body):
            let snippet = String(body.prefix(200))
            return "请求失败(HTTP \(code)):\(snippet)"
        case .malformedResponse:
            return "无法解析服务商返回的内容"
        }
    }
}

/// 调用 LLM 把一批字幕行翻译成目标语言,输入输出一一对应。
struct TranslationService {
    var session: URLSession = .shared

    func translate(lines: [String], targetLanguage: String) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        let provider = AppSettings.provider
        let apiKey = AppSettings.apiKey(for: provider)
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey(provider) }
        let model = AppSettings.model(for: provider)

        let systemPrompt = """
        You are a professional subtitle translator. Translate every line of the given JSON \
        array into \(targetLanguage). Keep the translation concise and natural, suitable for \
        video subtitles. Reply with ONLY a JSON array of strings — same length and order as \
        the input, no markdown fences, no explanations.
        """
        let userPrompt = try Self.jsonString(from: lines)

        let content: String
        switch provider {
        case .anthropic:
            content = try await callAnthropic(apiKey: apiKey, model: model,
                                              system: systemPrompt, user: userPrompt)
        case .openai, .openrouter, .xai:
            let base: String
            switch provider {
            case .openai: base = "https://api.openai.com/v1"
            case .openrouter: base = "https://openrouter.ai/api/v1"
            default: base = "https://api.x.ai/v1"
            }
            content = try await callOpenAICompatible(baseURL: base, apiKey: apiKey, model: model,
                                                     system: systemPrompt, user: userPrompt)
        }

        let translated = Self.parseStringArray(from: content)
        guard !translated.isEmpty else { throw TranslationError.malformedResponse }
        // 数量不符时对齐长度,避免字幕错位。
        if translated.count >= lines.count {
            return Array(translated.prefix(lines.count))
        }
        return translated + Array(repeating: "", count: lines.count - translated.count)
    }

    // MARK: - Providers

    private func callOpenAICompatible(baseURL: String, apiKey: String, model: String,
                                      system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.malformedResponse
        }
        return content
    }

    private func callAnthropic(apiKey: String, model: String,
                               system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw TranslationError.malformedResponse
        }
        return text
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TranslationError.httpError(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.malformedResponse
        }
        return json
    }

    // MARK: - Helpers

    static func jsonString(from lines: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: lines)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// 从模型回复中宽松地提取字符串数组(容忍 markdown 代码块等包裹)。
    static func parseStringArray(from content: String) -> [String] {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"), start < end else { return [] }
        let jsonPart = String(content[start...end])
        guard let data = jsonPart.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return array.map { ($0 as? String) ?? "" }
    }
}
