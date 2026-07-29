import Foundation

enum TranslationError: LocalizedError {
    case badResponse(Int, String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .badResponse(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .emptyReply: return "模型返回为空"
        }
    }
}

struct TranslationService {
    let provider: LLMProvider
    let apiKey: String
    let model: String

    func translate(texts: [String], to target: String) async throws -> [String] {
        // Tiny realtime batches: skip numbered multi-line ceremony for lower latency.
        if texts.count <= 2 {
            return try await translateLive(texts: texts, to: target)
        }
        let numbered = texts.enumerated()
            .map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let prompt = """
        将下列字幕逐条翻译成\(target)。要求：只输出翻译，保留原有编号（格式为"编号. 译文"），每行一条，不要合并、不要解释。

        \(numbered)
        """
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let reply = try await chat(prompt: prompt, maxTokens: 2048)
                let parsed = Self.parseNumbered(reply, count: texts.count)
                let nonEmpty = parsed.filter { !$0.isEmpty }.count
                if nonEmpty >= max(1, texts.count / 2) || attempt == 1 {
                    return parsed
                }
            } catch {
                lastError = error
                if attempt == 1 { throw error }
            }
        }
        if let lastError { throw lastError }
        return Array(repeating: "", count: texts.count)
    }

    /// Low-latency path for the current cue (+ next): one short reply, no big batch.
    private func translateLive(texts: [String], to target: String) async throws -> [String] {
        if texts.count == 1 {
            let prompt = """
            把这句字幕翻译成\(target)。只输出译文，不要引号、不要解释：
            \(texts[0].replacingOccurrences(of: "\n", with: " "))
            """
            let reply = try await chat(prompt: prompt, maxTokens: 256)
            let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return [line]
        }
        let numbered = texts.enumerated()
            .map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let prompt = """
        将下列\(texts.count)句字幕翻译成\(target)。只输出译文，保留编号，每行一条：
        \(numbered)
        """
        let reply = try await chat(prompt: prompt, maxTokens: 512)
        return Self.parseNumbered(reply, count: texts.count)
    }

    private func chat(prompt: String, maxTokens: Int = 8192) async throws -> String {
        var request = URLRequest(url: URL(string: provider.endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = maxTokens <= 512 ? 20 : 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]
        switch provider {
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": maxTokens,
                "messages": [["role": "user", "content": prompt]]
            ]
        case .openrouter:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("TranslateBrowser/1.0", forHTTPHeaderField: "X-Title")
            body = [
                "model": model,
                "max_tokens": maxTokens,
                "messages": [["role": "user", "content": prompt]]
            ]
        default:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "max_tokens": maxTokens,
                "messages": [["role": "user", "content": prompt]]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslationError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content: String?
        if provider == .claude {
            content = (json?["content"] as? [[String: Any]])?.first?["text"] as? String
        } else {
            let choices = json?["choices"] as? [[String: Any]]
            content = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text = content, !text.isEmpty else { throw TranslationError.emptyReply }
        return text
    }

    static func parseNumbered(_ text: String, count: Int) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let range = trimmed.range(of: #"^\d+[.、\)]\s*"#, options: .regularExpression) {
                result.append(String(trimmed[range.upperBound...]))
            } else if !result.isEmpty {
                result[result.count - 1] += " " + trimmed
            } else {
                result.append(trimmed)
            }
        }
        while result.count < count { result.append("") }
        return Array(result.prefix(count))
    }
}
