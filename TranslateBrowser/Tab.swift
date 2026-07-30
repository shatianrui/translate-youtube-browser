import Foundation
import WebKit
import Combine
import SwiftUI

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
    @Published var showSubtitlePanel = true
    @Published var showSubtitleList = false

    @AppStorage("provider") private var providerRaw = LLMProvider.openai.rawValue
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ""
    @AppStorage("targetLang") private var targetLang = "中文"

    weak var webView: WKWebView?
    weak var tabsManager: TabsManager?

    private var lastLoadedVideoID: String?
    private var extractionTask: Task<Void, Never>?

    /// timedtext URLs the page requested for itself, reported by the injected script.
    private var capturedTimedTextURLs: [String] = []
    /// Live-caption fallback state: the line currently on screen, plus a cache so a repeated
    /// line (YouTube re-renders the same text often) costs at most one translation call.
    private var liveTranslationCache: [String: String] = [:]
    private var liveTranslationTask: Task<Void, Never>?

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
        extractionTask = Task { await extractAndTranslate() }
    }

    func onActiveIndexChanged(_ index: Int) {
        currentIndex = subtitles.indices.contains(index) ? index : nil
    }

    func onTimedTextURLCaptured(_ urlString: String) {
        guard !capturedTimedTextURLs.contains(urlString) else { return }
        capturedTimedTextURLs.append(urlString)
    }

    /// Live-caption fallback: translate the line YouTube is currently showing and push it back
    /// into the overlay. Only runs when no downloadable track was found for this video.
    func onLiveCaption(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            evalJS("window.__tbSetLiveTranslation && window.__tbSetLiveTranslation('', '')")
            return
        }
        if let cached = liveTranslationCache[trimmed] {
            pushLiveTranslation(orig: trimmed, trans: cached)
            return
        }
        pushLiveTranslation(orig: trimmed, trans: "")
        guard !apiKey.isEmpty else { return }
        liveTranslationTask?.cancel()
        liveTranslationTask = Task { [weak self] in
            guard let self else { return }
            let service = TranslationService(
                provider: self.provider,
                apiKey: self.apiKey,
                model: self.model.isEmpty ? self.provider.defaultModel : self.model
            )
            guard let translated = try? await service.translate(texts: [trimmed], to: self.targetLang).first,
                  !translated.isEmpty, !Task.isCancelled else { return }
            self.liveTranslationCache[trimmed] = translated
            self.pushLiveTranslation(orig: trimmed, trans: translated)
        }
    }

    private func pushLiveTranslation(orig: String, trans: String) {
        guard let o = jsStringLiteral(orig), let t = jsStringLiteral(trans) else { return }
        evalJS("window.__tbSetLiveTranslation && window.__tbSetLiveTranslation(\(o), \(t))")
    }

    /// JSON-encodes a Swift string into a JS string literal so caption text containing quotes,
    /// backslashes, or newlines can't break out of the evaluated snippet.
    private func jsStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func clearSubtitleState() {
        extractionTask?.cancel()
        liveTranslationTask?.cancel()
        subtitles = []
        currentIndex = nil
        lastLoadedVideoID = nil
        statusMessage = ""
        capturedTimedTextURLs = []
        liveTranslationCache = [:]
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

    /// Caption acquisition, most-reliable strategy first:
    ///  1. Turn captions on through the player API and reuse the timedtext URL the player
    ///     requests for itself — it carries the PoToken, so it returns real content where a URL
    ///     we rebuild from the player response 200s empty.
    ///  2. The player response's own track list (works on videos that aren't PoToken-gated).
    ///  3. InnerTube ANDROID_VR, which serves caption URLs that don't need a PoToken.
    ///  4. Failing all of those, translate the captions YouTube paints on screen, line by line.
    private func extractAndTranslate() async {
        guard let webView else { return }
        let videoID = lastLoadedVideoID
        statusMessage = "正在获取字幕…"
        subtitles = []
        currentIndex = nil
        capturedTimedTextURLs = []
        liveTranslationCache = [:]
        _ = try? await webView.evaluateJavaScript("window.__tbClearSubtitles && window.__tbClearSubtitles()")
        _ = try? await webView.evaluateJavaScript("window.__tbResetCapture && window.__tbResetCapture()")

        if let subs = await subtitlesFromPlayerRequest(webView: webView), !subs.isEmpty {
            if Task.isCancelled { return }
            await adopt(subs)
            return
        }
        if Task.isCancelled { return }

        // Strategies 2 & 3: track lists we resolve ourselves.
        var tracks = await pollPageTracks(webView: webView)
        if tracks.isEmpty, let videoID {
            statusMessage = "正在通过备用通道获取字幕轨…"
            tracks = (try? await SubtitleExtractor.fetchTracksViaAndroidVR(videoID: videoID)) ?? []
        }
        if Task.isCancelled { return }

        if !tracks.isEmpty {
            let track = pickBestTrack(from: tracks)
            statusMessage = "正在下载字幕（\(track.languageCode)）…"
            let subs = (try? await SubtitleExtractor.fetchSubtitles(
                from: track, videoID: videoID, using: webView
            )) ?? []
            if Task.isCancelled { return }
            if !subs.isEmpty {
                await adopt(subs)
                return
            }
        }

        await startLiveCaptionMode(webView: webView)
    }

    private func adopt(_ subs: [Subtitle]) async {
        subtitles = subs
        statusMessage = "已提取 \(subs.count) 条字幕，开始翻译…"
        await pushSubtitlesToPage()
        await translateAll()
    }

    /// Strategy 1. Switches a caption track on, then waits for the injected fetch/XHR hook to
    /// report the URL the player asked for and downloads that exact URL.
    private func subtitlesFromPlayerRequest(webView: WKWebView) async -> [Subtitle]? {
        statusMessage = "正在开启字幕轨…"
        // A URL that came back unusable won't become usable on a later pass, so remember which
        // ones were already attempted rather than re-downloading them every poll.
        var tried = Set<String>()
        // The player may still be booting right after an SPA navigation, so keep nudging it.
        for attempt in 0..<24 {
            if Task.isCancelled { return nil }
            _ = try? await webView.evaluateJavaScript("window.__tbEnableCaptions && window.__tbEnableCaptions(\(avoidLanguagesJSON()))")

            let fresh = rankCapturedURLs(await capturedURLs(webView: webView).filter { !tried.contains($0) })
            for url in fresh {
                if Task.isCancelled { return nil }
                tried.insert(url)
                let lang = SubtitleExtractor.language(ofCapturedURL: url)
                statusMessage = "正在下载字幕（\(lang.isEmpty ? "auto" : lang)）…"
                let subs = (try? await SubtitleExtractor.fetchSubtitles(
                    fromCapturedURL: url, using: webView
                )) ?? []
                if !subs.isEmpty { return subs }
            }
            if attempt < 23 {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        return nil
    }

    /// Merges URLs seen by the message handler with whatever the page has buffered, so a message
    /// that arrived before this task started still counts.
    private func capturedURLs(webView: WKWebView) async -> [String] {
        var urls = capturedTimedTextURLs
        if let json = try? await webView.evaluateJavaScript("JSON.stringify(window.__tbCapturedURLs ? window.__tbCapturedURLs() : [])") as? String,
           let data = json.data(using: .utf8),
           let fromPage = try? JSONDecoder().decode([String].self, from: data) {
            for url in fromPage where !urls.contains(url) {
                urls.append(url)
            }
        }
        return urls
    }

    /// Prefer a manual track in a language we'd actually want to translate from: skip tracks
    /// already in the target language, and treat ASR as a last resort.
    private func rankCapturedURLs(_ urls: [String]) -> [String] {
        let hints = targetLanguageHints()
        func isTarget(_ url: String) -> Bool {
            let lang = SubtitleExtractor.language(ofCapturedURL: url)
            return hints.contains { lang.hasPrefix($0) }
        }
        func score(_ url: String) -> Int {
            let lang = SubtitleExtractor.language(ofCapturedURL: url)
            let asr = SubtitleExtractor.isASR(capturedURL: url)
            if isTarget(url) { return asr ? 5 : 4 }
            if lang.hasPrefix("en") { return asr ? 1 : 0 }
            return asr ? 3 : 2
        }
        return urls.enumerated()
            .sorted { lhs, rhs in
                let left = score(lhs.element), right = score(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// Strategy 4. No track could be downloaded, so mirror YouTube's on-screen captions instead
    /// and translate each line as it appears.
    private func startLiveCaptionMode(webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("window.__tbEnableCaptions && window.__tbEnableCaptions(\(avoidLanguagesJSON()))")
        let enabled = (try? await webView.evaluateJavaScript("window.__tbSetLiveMode && window.__tbSetLiveMode(true)")) as? Bool
        if enabled == true {
            statusMessage = apiKey.isEmpty
                ? "已启用实时字幕，请在设置中填写 API Key"
                : "字幕无法下载，已切换到实时逐句翻译"
        } else {
            statusMessage = "该视频没有可用字幕"
        }
    }

    /// After an SPA navigation the player response can lag behind the URL change; poll for it.
    private func pollPageTracks(webView: WKWebView) async -> [CaptionTrack] {
        for attempt in 0..<12 {
            if Task.isCancelled { return [] }
            if let json = try? await webView.evaluateJavaScript(SubtitleExtractor.captionTracksJS) as? String,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([CaptionTrack].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            if attempt < 11 {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        return []
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

    /// Target-language prefixes as a JS array literal, for `__tbEnableCaptions`.
    private func avoidLanguagesJSON() -> String {
        let hints = targetLanguageHints()
        guard let data = try? JSONSerialization.data(withJSONObject: hints),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
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
