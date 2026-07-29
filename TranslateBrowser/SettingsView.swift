import SwiftUI

struct SettingsView: View {
    @AppStorage("provider") private var providerRaw = LLMProvider.openai.rawValue
    @AppStorage("targetLang") private var targetLang = "中文"
    @Environment(\.dismiss) private var dismiss

    private var provider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .openai
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { ProviderCredentials.apiKey(for: provider) },
            set: { ProviderCredentials.setAPIKey($0, for: provider) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { ProviderCredentials.model(for: provider) },
            set: { ProviderCredentials.setModel($0, for: provider) }
        )
    }

    private let languages = ["中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский", "繁體中文"]

    var body: some View {
        NavigationStack {
            Form {
                Section("翻译服务") {
                    Picker("服务商", selection: $providerRaw) {
                        ForEach(LLMProvider.allCases) { p in
                            Text(p.rawValue).tag(p.rawValue)
                        }
                    }
                    SecureField("API Key（\(provider.apiKeyPlaceholder)）", text: apiKeyBinding)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .id("apiKey-\(provider.settingsID)")
                    TextField("模型（默认 \(provider.defaultModel)）", text: modelBinding)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .id("model-\(provider.settingsID)")
                    Text("各服务商的 API Key 与模型会分别记住")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("目标语言") {
                    Picker("翻译成", selection: $targetLang) {
                        ForEach(languages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                }

                Section {
                    Text("切换 ChatGPT / Claude / OpenRouter / Grok 时，各自的 API Key 和模型互不影响。打开视频后先载入字幕时间轴（原文立刻显示），再对当前台词实时翻译，并预翻译后续约 1 分钟内容。API Key 仅保存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                ProviderCredentials.migrateLegacyIfNeeded(currentProvider: provider)
            }
        }
    }
}
