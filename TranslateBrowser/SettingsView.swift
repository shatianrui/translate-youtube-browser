import SwiftUI

struct SettingsView: View {
    @AppStorage("provider") private var providerRaw = LLMProvider.openai.rawValue
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ""
    @AppStorage("targetLang") private var targetLang = "中文"
    @Environment(\.dismiss) private var dismiss

    private var provider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .openai
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
                    SecureField("API Key（\(provider.apiKeyPlaceholder)）", text: $apiKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("模型（默认 \(provider.defaultModel)）", text: $model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section("目标语言") {
                    Picker("翻译成", selection: $targetLang) {
                        ForEach(languages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                }

                Section("官方 YouTube Studio 导入") {
                    Text("即将推出。该导入路径将仅使用官方 YouTube Studio / YouTube Data API。使用前必须登录 Google/YouTube 帐号，且该帐号必须拥有目标视频的编辑权限。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("使用 YouTube Studio 导入（暂不可用）") {}
                        .disabled(true)
                }

                Section {
                    Text("打开 YouTube 视频后会自动提取字幕，并在画面内叠加原文 + 译文双语字幕。API Key 仅保存在本机。若提示字幕为空，可点右上角刷新按钮重试。")
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
        }
    }
}
