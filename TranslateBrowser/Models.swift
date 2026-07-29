import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case openai = "ChatGPT (OpenAI)"
    case claude = "Claude (Anthropic)"
    case openrouter = "OpenRouter"
    case grok = "Grok (xAI)"

    var id: String { rawValue }

    /// Stable UserDefaults suffix — independent of display `rawValue`.
    var settingsID: String {
        switch self {
        case .openai: return "openai"
        case .claude: return "claude"
        case .openrouter: return "openrouter"
        case .grok: return "grok"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .claude: return "claude-3-5-haiku-latest"
        case .openrouter: return "openai/gpt-4o-mini"
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

/// Per-provider API key + model, so switching ChatGPT / Claude / OpenRouter / Grok
/// keeps each service's credentials instead of overwriting a single shared pair.
enum ProviderCredentials {
    private static let legacyAPIKey = "apiKey"
    private static let legacyModel = "model"
    private static let migratedFlag = "providerCredentials.migratedLegacy"

    private static func apiKeyKey(for provider: LLMProvider) -> String {
        "apiKey.\(provider.settingsID)"
    }

    private static func modelKey(for provider: LLMProvider) -> String {
        "model.\(provider.settingsID)"
    }

    /// One-time: copy old shared apiKey/model into the currently selected provider.
    static func migrateLegacyIfNeeded(currentProvider: LLMProvider) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlag) else { return }
        defaults.set(true, forKey: migratedFlag)

        let oldKey = defaults.string(forKey: legacyAPIKey) ?? ""
        let oldModel = defaults.string(forKey: legacyModel) ?? ""
        if !oldKey.isEmpty, (defaults.string(forKey: apiKeyKey(for: currentProvider)) ?? "").isEmpty {
            defaults.set(oldKey, forKey: apiKeyKey(for: currentProvider))
        }
        if !oldModel.isEmpty, (defaults.string(forKey: modelKey(for: currentProvider)) ?? "").isEmpty {
            defaults.set(oldModel, forKey: modelKey(for: currentProvider))
        }
    }

    static func apiKey(for provider: LLMProvider) -> String {
        migrateLegacyIfNeeded(currentProvider: provider)
        return UserDefaults.standard.string(forKey: apiKeyKey(for: provider)) ?? ""
    }

    static func setAPIKey(_ value: String, for provider: LLMProvider) {
        UserDefaults.standard.set(value, forKey: apiKeyKey(for: provider))
    }

    static func model(for provider: LLMProvider) -> String {
        migrateLegacyIfNeeded(currentProvider: provider)
        return UserDefaults.standard.string(forKey: modelKey(for: provider)) ?? ""
    }

    static func setModel(_ value: String, for provider: LLMProvider) {
        UserDefaults.standard.set(value, forKey: modelKey(for: provider))
    }

    /// Resolved model name: stored override or provider default.
    static func resolvedModel(for provider: LLMProvider) -> String {
        let stored = model(for: provider)
        return stored.isEmpty ? provider.defaultModel : stored
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

    init(baseUrl: String, languageCode: String, kind: String?, name: Name?) {
        self.baseUrl = baseUrl
        self.languageCode = languageCode
        self.kind = kind
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
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
