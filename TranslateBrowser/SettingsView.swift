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
                    Text("打开 YouTube 视频后，双语字幕会自动出现在画面底部原 CC 位置（上方原文、下方译文），无需点开列表。若提示被拦截，点状态条上的刷新，或长按地址栏旁 Aa 可重新翻译。API Key 仅保存在本机。")
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
