import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.providerKey) private var providerRaw = TranslationProvider.openai.rawValue
    @AppStorage(AppSettings.targetLanguageKey) private var targetLanguage = AppSettings.defaultTargetLanguage

    @AppStorage("apiKey.openai") private var openaiKey = ""
    @AppStorage("apiKey.anthropic") private var anthropicKey = ""
    @AppStorage("apiKey.openrouter") private var openrouterKey = ""
    @AppStorage("apiKey.xai") private var xaiKey = ""

    @AppStorage("model.openai") private var openaiModel = ""
    @AppStorage("model.anthropic") private var anthropicModel = ""
    @AppStorage("model.openrouter") private var openrouterModel = ""
    @AppStorage("model.xai") private var xaiModel = ""

    private var provider: TranslationProvider {
        TranslationProvider(rawValue: providerRaw) ?? .openai
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("翻译服务商") {
                    Picker("服务商", selection: $providerRaw) {
                        ForEach(TranslationProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    SecureField("API Key", text: apiKeyBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型(默认 \(provider.defaultModel))", text: modelBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("目标语言", text: $targetLanguage)
                } header: {
                    Text("目标语言")
                } footer: {
                    Text("字幕将被翻译成该语言,例如:简体中文、日本語、English。")
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("使用方法:打开 YouTube 视频并开启字幕(CC),应用会自动提取字幕、调用所选服务商翻译,并在播放器上叠加双语字幕。API Key 仅保存在本机。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        switch provider {
        case .openai: return $openaiKey
        case .anthropic: return $anthropicKey
        case .openrouter: return $openrouterKey
        case .xai: return $xaiKey
        }
    }

    private var modelBinding: Binding<String> {
        switch provider {
        case .openai: return $openaiModel
        case .anthropic: return $anthropicModel
        case .openrouter: return $openrouterModel
        case .xai: return $xaiModel
        }
    }
}

#Preview {
    SettingsView()
}
