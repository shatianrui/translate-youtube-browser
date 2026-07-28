import Foundation
import WebKit
import Combine
import SwiftUI

/// One browser tab: its own WKWebView plus the YouTube subtitle-extraction/translation state for
/// whatever page is currently loaded in it. Multiple tabs simply mean multiple `Tab` instances
/// managed by `TabsManager`, each rendering its own `BrowserView`.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool

    @Published var urlText: String
    @Published var pageTitle: String = ""
    @Published var estimatedProgress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false

    @Published var subtitles: [Subtitle] = []
    @Published var currentIndex: Int?
    @Published var statusMessage = ""
    @Published var isTranslating = false
    @Published var showSubtitlePanel = true
    @Published var showSubtitleList = false

    @AppStorage("provider") private var providerRaw = LLMProvider.openai.rawValue
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ""
    @AppStorage("targetLang") private var targetLang = "中文"

    weak var webView: WKWebView?
    /// Settings are app-wide, not per-tab; this lets translateAll() pop the shared settings
    /// sheet when the API key is missing without Tab needing to own that state itself.
    weak var tabsManager: TabsManager?

    private var lastLoadedVideoID: String?
    private var extractionTask: Task<Void, Never>?

    init(urlText: String, isPrivate: Bool = false) {
        self.urlText = urlText
        self.isPrivate = isPrivate
    }

    var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .openai }

    /// A short label for the tab switcher: the page title if we have one, else the host.
    var displayTitle: String {
        if !pageTitle.isEmpty { return pageTitle }
        return URL(string: urlText)?.host ?? urlText
    }

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

    func load(_ urlString: String) {
        urlText = urlString
        loadFromAddressBar()
    }

    /// Called both on full page loads and on YouTube's in-page (SPA) navigations between videos.
    func onURLChanged(_ url: URL?) {
        guard let url else { return }
        urlText = url.absoluteString
        let isYouTube = url.host?.contains("youtube.com") == true
        let isWatch = isYouTube && url.path.contains("/watch")
        guard isWatch, let videoID = videoID(from: url) else {
            if !isYouTube {
                extractionTask?.cancel()
                subtitles = []
                currentIndex = nil
                lastLoadedVideoID = nil
                statusMessage = ""
                evalJS("window.__tbClearSubtitles && window.__tbClearSubtitles()")
            }
            return
        }
        guard videoID != lastLoadedVideoID else { return }
        lastLoadedVideoID = videoID
        extractionTask?.cancel()
        extractionTask = Task { await extractAndTranslate() }
    }

    /// Reported by the injected page script when the caption bubble it renders switches to a
    /// different cue (or none). Keeps the "字幕列表" sheet's highlighted row in sync without any
    /// Swift-side polling.
    func onActiveIndexChanged(_ index: Int) {
        currentIndex = subtitles.indices.contains(index) ? index : nil
    }

    private func videoID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value
    }

    private func extractAndTranslate() async {
        guard let webView else { return }
        statusMessage = "正在获取字幕…"
        subtitles = []
        currentIndex = nil
        _ = try? await webView.evaluateJavaScript("window.__tbClearSubtitles && window.__tbClearSubtitles()")

        // Right after a YouTube SPA navigation, the player and its caption data can take a
        // moment to become available, so poll for a while instead of failing on the first miss.
        var tracks: [CaptionTrack] = []
        for attempt in 0..<16 {
            if Task.isCancelled { return }
            if let json = try? await webView.evaluateJavaScript(SubtitleExtractor.captionTracksJS) as? String,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([CaptionTrack].self, from: data),
               !decoded.isEmpty {
                tracks = decoded
                break
            }
            if attempt < 15 {
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
            await pushSubtitlesToPage()
            await translateAll()
        } catch {
            if Task.isCancelled { return }
            statusMessage = "字幕获取失败: \(error.localizedDescription)"
        }
    }

    /// JSON-encodes the current subtitles (with whatever translations exist so far) and hands
    /// them to the in-page script so the bilingual caption is drawn inside the video itself —
    /// including inside YouTube's own fullscreen presentation — rather than as a Swift-side
    /// overlay that would be left behind when the page goes fullscreen.
    private struct PageSubtitle: Encodable {
        let s: Double
        let d: Double
        let o: String
        let t: String
    }

    private func pushSubtitlesToPage() async {
        guard let webView else { return }
        let payload = subtitles.map { PageSubtitle(s: $0.start, d: $0.duration, o: $0.text, t: $0.translation ?? "") }
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("window.__tbSetSubtitles && window.__tbSetSubtitles(\(json))")
    }

    /// Fire-and-forget JS evaluation for call sites that aren't already `async` (evaluateJavaScript
    /// only exists as an `async throws` API here, so a bare call must be wrapped in a Task).
    private func evalJS(_ script: String) {
        guard let webView else { return }
        Task { _ = try? await webView.evaluateJavaScript(script) }
    }

    func translateAll() async {
        guard !apiKey.isEmpty else {
            statusMessage = "请在设置中填写 \(provider.rawValue) 的 API Key"
            tabsManager?.showSettings = true
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
                await pushSubtitlesToPage()
            } catch {
                statusMessage = "翻译失败: \(error.localizedDescription)"
                return
            }
        }
        statusMessage = "翻译完成（\(provider.rawValue)）"
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }
}
