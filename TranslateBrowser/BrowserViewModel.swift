import Foundation
import WebKit
import Combine

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var urlText = "https://www.youtube.com"
    @Published var subtitles: [Subtitle] = []
    @Published var currentIndex: Int?
    @Published var statusMessage = ""
    @Published var isTranslating = false
    @Published var showSubtitlePanel = true
    @Published var showSettings = false
    @Published var showSubtitleList = false

    @AppStorage("provider") private var providerRaw = LLMProvider.openai.rawValue
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ""
    @AppStorage("targetLang") private var targetLang = "中文"

    weak var webView: WKWebView?
    private var syncTimer: Timer?
    private var lastLoadedVideoURL: String?

    var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .openai }

    func loadFromAddressBar() {
        var text = urlText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return }
        if !text.contains("://") {
            text = text.contains(".") ? "https://\(text)" : "https://www.google.com/search?q=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)"
        }
        if let url = URL(string: text) {
            webView?.load(URLRequest(url: url))
        }
    }

    func onNavigationFinished(url: URL?) {
        guard let url else { return }
        urlText = url.absoluteString
        let isWatch = (url.host?.contains("youtube.com") == true) && url.absoluteString.contains("watch")
        guard isWatch else {
            if url.host?.contains("youtube.com") != true {
                stopSync()
                subtitles = []
            }
            return
        }
        guard url.absoluteString != lastLoadedVideoURL else { return }
        lastLoadedVideoURL = url.absoluteString
        Task { await extractAndTranslate() }
    }

    private func extractAndTranslate() async {
        guard let webView else { return }
        statusMessage = "正在获取字幕…"
        subtitles = []
        currentIndex = nil

        guard let json = try? await webView.evaluateJavaScript(SubtitleExtractor.captionTracksJS) as? String,
              let data = json.data(using: .utf8),
              let tracks = try? JSONDecoder().decode([CaptionTrack].self, from: data),
              !tracks.isEmpty else {
            statusMessage = "该视频没有可用字幕"
            return
        }

        let track = tracks.first(where: { $0.kind != "asr" && $0.languageCode.hasPrefix("en") })
            ?? tracks.first(where: { $0.kind != "asr" })
            ?? tracks[0]

        do {
            let subs = try await SubtitleExtractor.fetchSubtitles(from: track)
            guard !subs.isEmpty else {
                statusMessage = "字幕内容为空"
                return
            }
            subtitles = subs
            startSync()
            await translateAll()
        } catch {
            statusMessage = "字幕获取失败: \(error.localizedDescription)"
        }
    }

    func translateAll() async {
        guard !apiKey.isEmpty else {
            statusMessage = "请在设置中填写 \(provider.rawValue) 的 API Key"
            showSettings = true
            return
        }
        let service = TranslationService(
            provider: provider,
            apiKey: apiKey,
            model: model.isEmpty ? provider.defaultModel : model
        )
        isTranslating = true
        defer { isTranslating = false }
        let chunkSize = 25
        for start in stride(from: 0, to: subtitles.count, by: chunkSize) {
            let end = min(start + chunkSize, subtitles.count)
            let texts = subtitles[start..<end].map(\.text)
            do {
                let translated = try await service.translate(texts: texts, to: targetLang)
                for i in start..<end {
                    subtitles[i].translation = translated[i - start]
                }
                statusMessage = "已翻译 \(end)/\(subtitles.count)"
            } catch {
                statusMessage = "翻译失败: \(error.localizedDescription)"
                return
            }
        }
        statusMessage = "翻译完成（\(provider.rawValue)）"
    }

    private func startSync() {
        stopSync()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let webView = self.webView else { return }
                guard let t = try? await webView.evaluateJavaScript(SubtitleExtractor.currentTimeJS) as? Double, t >= 0 else { return }
                self.currentIndex = self.subtitles.firstIndex(where: { t >= $0.start && t <= $0.start + max($0.duration, 0.8) })
            }
        }
    }

    private func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}
