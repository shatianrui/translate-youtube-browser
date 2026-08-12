import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case openai = "ChatGPT (OpenAI)"
    case claude = "Claude (Anthropic)"
    case openrouter = "OpenRouter"
    case grok = "Grok (xAI)"

    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5-mini"
        case .claude: return "claude-haiku-4-5-20251001"
        case .openrouter: return "openai/gpt-5-mini"
        case .grok: return "grok-3-mini"
        }
    }

    var endpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/messages"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .grok: return "https://api.x.ai/v1/chat/completions"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .openai: return "sk-..."
        case .claude: return "sk-ant-..."
        case .openrouter: return "sk-or-..."
        case .grok: return "xai-..."
        }
    }
}

struct Subtitle: Identifiable {
    let id = UUID()
    let start: Double
    let duration: Double
    let text: String
    var translation: String?
}

struct CaptionTrack: Decodable {
    let baseUrl: String
    let languageCode: String
    let kind: String?
    let name: Name?

    enum CodingKeys: String, CodingKey {
        case baseUrl, languageCode, kind, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseUrl = try c.decode(String.self, forKey: .baseUrl)
        languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        name = try c.decodeIfPresent(Name.self, forKey: .name)
    }

    struct Name: Decodable {
        let simpleText: String?
        let runs: [Run]?

        struct Run: Decodable {
            let text: String?
        }

        var display: String {
            simpleText ?? runs?.compactMap { $0.text }.joined() ?? ""
        }
    }
}
