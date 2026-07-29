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

                Section {
                    Text("打开视频后先载入字幕时间轴（原文立刻显示），再对当前台词实时翻译，并预翻译后续约 1 分钟内容。快进会立刻跟到新位置。API Key 仅保存在本机。")
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
