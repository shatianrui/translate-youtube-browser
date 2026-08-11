import Foundation

/// 支持的 LLM 服务商。
enum TranslationProvider: String, CaseIterable, Identifiable {
    case openai
    case anthropic
    case openrouter
    case xai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "ChatGPT (OpenAI)"
        case .anthropic: return "Claude (Anthropic)"
        case .openrouter: return "OpenRouter"
        case .xai: return "Grok (xAI)"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-haiku-latest"
        case .openrouter: return "openai/gpt-4o-mini"
        case .xai: return "grok-3-mini"
        }
    }

    var apiKeyDefaultsKey: String { "apiKey.\(rawValue)" }
    var modelDefaultsKey: String { "model.\(rawValue)" }
}

/// 基于 UserDefaults 的轻量设置存取,供非 View 层(翻译服务等)读取。
enum AppSettings {
    static let providerKey = "translation.provider"
    static let targetLanguageKey = "translation.targetLanguage"
    static let defaultTargetLanguage = "简体中文"

    static var provider: TranslationProvider {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? ""
        return TranslationProvider(rawValue: raw) ?? .openai
    }

    static var targetLanguage: String {
        let value = UserDefaults.standard.string(forKey: targetLanguageKey) ?? ""
        return value.isEmpty ? defaultTargetLanguage : value
    }

    static func apiKey(for provider: TranslationProvider) -> String {
        (UserDefaults.standard.string(forKey: provider.apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func model(for provider: TranslationProvider) -> String {
        let value = (UserDefaults.standard.string(forKey: provider.modelDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultModel : value
    }
}
