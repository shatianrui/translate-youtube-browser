import Foundation
import WebKit
import Combine
import SwiftUI

/// Caption text and playback time reported by the injected page observer. The observer only sends
/// captions that are already visibly rendered in the current YouTube player after the user enables CC.
struct VisibleCaptionPayload {
    let text: String
    let time: Double

    init?(_ body: Any) {
        guard let values = body as? [String: Any],
              let rawText = values["text"] as? String else { return nil }
        let cleaned = SubtitleExtractor.cleanCaptionText(rawText)
        guard !cleaned.isEmpty else { return nil }
        text = cleaned
        time = (values["time"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// One browser tab: its own WKWebView plus YouTube subtitle extraction/translation state.
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
    @Published var showSubtitlePanel = false
    @Published var showSubtitleList = false

    @AppStorage("provider") private var providerRaw = LLMProvider.openai.rawValue
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ""
    @AppStorage("targetLang") private var targetLang = "中文"

    weak var webView: WKWebView?
    weak var tabsManager: TabsManager?

    private var lastLoadedVideoID: String?
    private var extractionTask: Task<Void, Never>?
    private var visibleCaptionTranslationTask: Task<Void, Never>?
    private var usesVisibleCaptionFallback = false
    private var lastVisibleCaptionText = ""
    private var lastVisibleCaptionTime = -Double.infinity

    init(urlText: String, isPrivate: Bool = false) {
        self.urlText = urlText
        self.isPrivate = isPrivate
    }

    var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .openai }

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

    /// Called on full loads and YouTube SPA navigations.
    func onURLChanged(_ url: URL?) {
        guard let url else { return }
        urlText = url.absoluteString
        let host = url.host?.lowercased() ?? ""
        let isYouTube = host.contains("youtube.com") || host.contains("youtu.be") || host.contains("youtube-nocookie.com")
        guard isYouTube, let videoID = videoID(from: url) else {
            if !isYouTube {
                clearSubtitleState()
            }
            return
        }
        guard videoID != lastLoadedVideoID else { return }
        lastLoadedVideoID = videoID
        extractionTask?.cancel()
        resetVisibleCaptionFallback()
        extractionTask = Task { await extractAndTranslate() }
    }

    func onActiveIndexChanged(_ index: Int) {
        currentIndex = subtitles.indices.contains(index) ? index : nil
    }

    func onVisibleCaption(_ payload: VisibleCaptionPayload) {
        guard usesVisibleCaptionFallback else { return }
        // Mutation observers can report the same on-screen caption repeatedly. Keep repetitions
        // that occur later in playback, but do not send duplicate provider requests in one cue.
        guard payload.text != lastVisibleCaptionText || payload.time - lastVisibleCaptionTime > 1.0 else { return }
        lastVisibleCaptionText = payload.text
        lastVisibleCaptionTime = payload.time

        let subtitle = Subtitle(start: max(payload.time, 0), duration: 4, text: payload.text)
        subtitles.append(subtitle)
        currentIndex = subtitles.indices.last
        statusMessage = "正在实时翻译…"
        Task { await pushSubtitlesToPage() }

        visibleCaptionTranslationTask?.cancel()
        let index = subtitles.indices.last!
        visibleCaptionTranslationTask = Task { [weak self] in
            await self?.translateVisibleCaption(at: index)
        }
    }

    private func resetVisibleCaptionFallback() {
        visibleCaptionTranslationTask?.cancel()
        visibleCaptionTranslationTask = nil
        usesVisibleCaptionFallback = false
        lastVisibleCaptionText = ""
        lastVisibleCaptionTime = -Double.infinity
    }

    private func beginVisibleCaptionFallback() {
        guard !Task.isCancelled else { return }
        resetVisibleCaptionFallback()
        usesVisibleCaptionFallback = true
        statusMessage = "请在 YouTube 播放器中开启 CC 以实时翻译"
    }

    private func clearSubtitleState() {
        extractionTask?.cancel()
        resetVisibleCaptionFallback()
        subtitles = []
        currentIndex = nil
        lastLoadedVideoID = nil
        statusMessage = ""
        evalJS("window.__tbClearSubtitles && window.__tbClearSubtitles()")
    }

    /// Supports /watch?v=, youtu.be/<id>, /shorts/<id>, /embed/<id>, /live/<id>.
    private func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtu.be") {
            let id = url.path.split(separator: "/").first.map(String.init)
            return validVideoID(id)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
            return validVideoID(parts[1])
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if let v = items?.first(where: { $0.name == "v" })?.value {
            return validVideoID(v)
        }
        return nil
    }

    private func validVideoID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.split(separator: "?").first.map(String.init) ?? raw
        // YouTube IDs are typically 11 chars of [A-Za-z0-9_-]
        guard id.count >= 10, id.count <= 12,
              id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return id
    }

    private func extractAndTranslate() async {
        guard let webView else { return }
        statusMessage = "正在获取字幕…"
        subtitles = []
        currentIndex = nil
        _ = try? await webView.evaluateJavaScript("window.__tbClearSubtitles && window.__tbClearSubtitles()")

        // After SPA navigation the player/captions can lag; poll before giving up.
        var tracks: [CaptionTrack] = []
        for attempt in 0..<20 {
            if Task.isCancelled { return }
            if let json = try? await webView.evaluateJavaScript(SubtitleExtractor.captionTracksJS) as? String,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([CaptionTrack].self, from: data),
               !decoded.isEmpty {
                tracks = decoded
                break
            }
            if attempt < 19 {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }

        guard !tracks.isEmpty else {
            beginVisibleCaptionFallback()
            return
        }

        let track = pickBestTrack(from: tracks)
        statusMessage = "正在下载字幕（\(track.languageCode)）…"

        do {
            let subs = try await SubtitleExtractor.fetchSubtitles(from: track, using: webView)
            guard !subs.isEmpty else {
                beginVisibleCaptionFallback()
                return
            }
            if Task.isCancelled { return }
            subtitles = subs
            statusMessage = "已提取 \(subs.count) 条字幕，开始翻译…"
            await pushSubtitlesToPage()
            await translateAll()
        } catch {
            if Task.isCancelled { return }
            // A track can be listed yet return an empty/blocked page body. Stay inside the loaded
            // page and wait for the user's visible CC captions rather than probing other clients.
            beginVisibleCaptionFallback()
        }
    }

    /// Prefer manual English (good translation source), then other manual (non-target), then ASR.
    private func pickBestTrack(from tracks: [CaptionTrack]) -> CaptionTrack {
        let hints = targetLanguageHints()
        func isTarget(_ track: CaptionTrack) -> Bool {
            hints.contains { track.languageCode.hasPrefix($0) }
        }
        if let enManual = tracks.first(where: { $0.kind != "asr" && $0.languageCode.hasPrefix("en") }) {
            return enManual
        }
        if let manualOther = tracks.first(where: { $0.kind != "asr" && !isTarget($0) }) {
            return manualOther
        }
        if let anyManual = tracks.first(where: { $0.kind != "asr" }) {
            return anyManual
        }
        if let enAsr = tracks.first(where: { $0.languageCode.hasPrefix("en") }) {
            return enAsr
        }
        return tracks[0]
    }

    private func targetLanguageHints() -> [String] {
        switch targetLang {
        case "中文", "繁體中文": return ["zh", "zh-Hans", "zh-Hant", "zh-CN", "zh-TW"]
        case "日本語": return ["ja"]
        case "한국어": return ["ko"]
        case "Français": return ["fr"]
        case "Deutsch": return ["de"]
        case "Español": return ["es"]
        case "Русский": return ["ru"]
        case "English": return ["en"]
        default: return []
        }
    }

    private struct PageSubtitle: Encodable {
        let s: Double
        let d: Double
        let o: String
        let t: String
    }

    private func pushSubtitlesToPage() async {
        guard let webView else { return }
        let payload = subtitles.map {
            PageSubtitle(s: $0.start, d: $0.duration, o: $0.text, t: $0.translation ?? "")
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("window.__tbSetSubtitles && window.__tbSetSubtitles(\(json))")
    }

    private func evalJS(_ script: String) {
        guard let webView else { return }
        Task { _ = try? await webView.evaluateJavaScript(script) }
    }

    private func translateVisibleCaption(at index: Int) async {
        guard usesVisibleCaptionFallback, subtitles.indices.contains(index) else { return }
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
        do {
            let translated = try await service.translate(texts: [subtitles[index].text], to: targetLang)
            guard !Task.isCancelled, usesVisibleCaptionFallback,
                  subtitles.indices.contains(index), let text = translated.first else { return }
            subtitles[index].translation = text
            statusMessage = "实时字幕已翻译（\(provider.rawValue)）"
            await pushSubtitlesToPage()
        } catch {
            guard !Task.isCancelled else { return }
            statusMessage = "实时字幕翻译失败: \(error.localizedDescription)"
        }
    }

    func translateAll() async {
        guard !apiKey.isEmpty else {
            statusMessage = "请在设置中填写 \(provider.rawValue) 的 API Key"
            tabsManager?.showSettings = true
            return
        }
        guard !subtitles.isEmpty else { return }
        let service = TranslationService(
            provider: provider,
            apiKey: apiKey,
            model: model.isEmpty ? provider.defaultModel : model
        )
        isTranslating = true
        defer { isTranslating = false }
        let chunkSize = 20
        for start in stride(from: 0, to: subtitles.count, by: chunkSize) {
            if Task.isCancelled { return }
            let end = min(start + chunkSize, subtitles.count)
            let texts = subtitles[start..<end].map(\.text)
            do {
                let translated = try await service.translate(texts: texts, to: targetLang)
                for i in start..<end {
                    let idx = i - start
                    if translated.indices.contains(idx) {
                        subtitles[i].translation = translated[idx]
                    }
                }
                statusMessage = "已翻译 \(end)/\(subtitles.count)"
                await pushSubtitlesToPage()
            } catch {
                statusMessage = "翻译失败: \(error.localizedDescription)"
                return
            }
        }
        statusMessage = "翻译完成（\(provider.rawValue)）"
        await pushSubtitlesToPage()
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        // Allow extractAndTranslate to run again for the same video after a manual reload.
        lastLoadedVideoID = nil
        webView?.reload()
    }
    func stopLoading() { webView?.stopLoading() }
}
