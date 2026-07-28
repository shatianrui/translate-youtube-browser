import Foundation
import WebKit
import Combine
import SwiftUI

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
    private var lastLoadedVideoID: String?
    private var extractionTask: Task<Void, Never>?

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

    /// Called both on full page loads and on YouTube's in-page (SPA) navigations between videos.
    func onURLChanged(_ url: URL?) {
        guard let url else { return }
        urlText = url.absoluteString
        let isYouTube = url.host?.contains("youtube.com") == true
        let isWatch = isYouTube && url.path.contains("/watch")
        guard isWatch, let videoID = videoID(from: url) else {
            if !isYouTube {
                stopSync()
                extractionTask?.cancel()
                subtitles = []
                currentIndex = nil
                lastLoadedVideoID = nil
                statusMessage = ""
            }
            return
        }
        guard videoID != lastLoadedVideoID else { return }
        lastLoadedVideoID = videoID
        extractionTask?.cancel()
        extractionTask = Task { await extractAndTranslate() }
    }

    private func videoID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value
    }

    private func extractAndTranslate() async {
        guard let webView else { return }
        stopSync()
        statusMessage = "正在获取字幕…"
        subtitles = []
        currentIndex = nil

        // Right after a YouTube SPA navigation, the player and its caption data can take a
        // moment to become available, so poll briefly instead of failing on the first miss.
        var tracks: [CaptionTrack] = []
        for attempt in 0..<10 {
            if Task.isCancelled { return }
            if let json = try? await webView.evaluateJavaScript(SubtitleExtractor.captionTracksJS) as? String,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([CaptionTrack].self, from: data),
               !decoded.isEmpty {
                tracks = decoded
                break
            }
            if attempt < 9 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        guard !tracks.isEmpty else {
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
            if Task.isCancelled { return }
            subtitles = subs
            startSync()
            await translateAll()
        } catch {
            if Task.isCancelled { return }
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
