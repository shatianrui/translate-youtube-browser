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
    private var translationTask: Task<Void, Never>?
    /// Filled asynchronously when the page interceptor steals a player timedtext response.
    private var pendingCapturedBody: String?
    /// Bumped on seek / restart so in-flight chunk results can still apply, but the
    /// next chunk is always chosen from the latest playhead.
    private var translationEpoch = 0
    private var lastSeekNudgeTime: TimeInterval = 0

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
        let previous = currentIndex
        currentIndex = subtitles.indices.contains(index) ? index : nil
        // Seek / fast-forward into untranslated region → restart so realtime hits the new cue ASAP.
        guard let currentIndex, needsTranslation(currentIndex) else { return }
        if let previous, abs(currentIndex - previous) >= 2 {
            nudgeTranslationPriority()
        } else if previous == nil || needsTranslation(currentIndex) {
            // Crossing into a cue that still lacks a translation — wake the realtime loop.
            nudgeTranslationPriority()
        }
    }

    /// Called from the WKScriptMessageHandler when fetch/XHR hooks capture timedtext.
    func onCapturedCaptionBody(_ body: String) {
        pendingCapturedBody = body
    }

    private func nudgeTranslationPriority() {
        let now = Date().timeIntervalSince1970
        guard now - lastSeekNudgeTime > 0.35 else { return }
        lastSeekNudgeTime = now
        // Always restart: cancels an in-flight prefetch chunk and prioritizes the new playhead.
        startRealtimeTranslation()
    }

    private func clearSubtitleState() {
        extractionTask?.cancel()
        translationTask?.cancel()
        translationEpoch &+= 1
        subtitles = []
        currentIndex = nil
        lastLoadedVideoID = nil
        pendingCapturedBody = nil
        isTranslating = false
        statusMessage = ""
        evalJS("window.__tbClearSubtitles && window.__tbClearSubtitles(); window.__tbClearCaptionCapture && window.__tbClearCaptionCapture()")
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
        let videoID = lastLoadedVideoID
        statusMessage = "正在获取字幕…"
        subtitles = []
        currentIndex = nil
        pendingCapturedBody = nil
        translationTask?.cancel()
        translationEpoch &+= 1
        isTranslating = false
        _ = try? await webView.evaluateJavaScript("""
            window.__tbClearSubtitles && window.__tbClearSubtitles();
            window.__tbClearCaptionCapture && window.__tbClearCaptionCapture();
            """)

        // Give the player a moment after SPA navigation, then try player-side capture first
        // (YouTube's own timedtext request carries a valid PoToken — external fetches often don't).
        try? await Task.sleep(nanoseconds: 800_000_000)
        if Task.isCancelled { return }

        statusMessage = "正在唤醒播放器字幕…"
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
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }

        if tracks.isEmpty, let videoID {
            statusMessage = "正在通过备用通道获取字幕轨…"
            tracks = (try? await SubtitleExtractor.fetchTracksViaAndroidVR(videoID: videoID)) ?? []
        }

        // Even without a track list, player capture may still succeed if CC can be toggled.
        let track = tracks.isEmpty
            ? CaptionTrack(baseUrl: "", languageCode: "en", kind: nil, name: nil)
            : pickBestTrack(from: tracks)

        if tracks.isEmpty {
            statusMessage = "正在拦截播放器字幕请求…"
        } else {
            statusMessage = "正在下载字幕（\(track.languageCode)）…"
        }

        do {
            // Prefer any body already stolen by the network hooks while we were polling.
            var subs: [Subtitle] = []
            if let pending = pendingCapturedBody {
                pendingCapturedBody = nil
                subs = SubtitleExtractor.parseCaptionBody(pending)
            }
            if subs.isEmpty {
                subs = try await SubtitleExtractor.fetchSubtitles(from: track, videoID: videoID, using: webView)
            }
            // One more chance: hooks may have filled pending during the async wait.
            if subs.isEmpty, let pending = pendingCapturedBody {
                pendingCapturedBody = nil
                subs = SubtitleExtractor.parseCaptionBody(pending)
            }
            guard !subs.isEmpty else {
                statusMessage = "字幕获取被 YouTube 拦截，请点 ↻ 重试或先点开视频 CC 字幕"
                return
            }
            if Task.isCancelled { return }
            subtitles = subs
            // Timeline is ready — show originals immediately, then realtime-translate the playhead.
            statusMessage = "时间轴已就绪，实时翻译中…"
            await pushSubtitlesToPage()
            startRealtimeTranslation()
        } catch {
            if Task.isCancelled { return }
            statusMessage = "字幕获取失败: \(error.localizedDescription)"
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
        /// Exclusive end time, clipped to the next cue's start so display matches
        /// YouTube's original caption windows (no linger into the following line).
        let e: Double
        let o: String
        let t: String
    }

    private func pushSubtitlesToPage() async {
        guard let webView else { return }
        let payload: [PageSubtitle] = subtitles.indices.map { i in
            let sub = subtitles[i]
            let rawEnd = sub.start + max(sub.duration, 0.05)
            let end: Double
            if i + 1 < subtitles.count {
                // YouTube never keeps the previous line up once the next cue starts.
                end = min(rawEnd, subtitles[i + 1].start)
            } else {
                end = rawEnd
            }
            return PageSubtitle(
                s: sub.start,
                e: max(end, sub.start + 0.05),
                o: sub.text,
                t: sub.translation ?? ""
            )
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("window.__tbSetSubtitles && window.__tbSetSubtitles(\(json))")
    }

    private func evalJS(_ script: String) {
        guard let webView else { return }
        Task { _ = try? await webView.evaluateJavaScript(script) }
    }

    private func needsTranslation(_ index: Int) -> Bool {
        guard subtitles.indices.contains(index) else { return false }
        let t = subtitles[index].translation
        return t == nil || t?.isEmpty == true
    }

    /// Read the in-page video clock so realtime / prefetch follow seeks.
    private func currentPlaybackTime() async -> Double? {
        guard let webView else { return nil }
        let js = "(document.querySelector('video') ? document.querySelector('video').currentTime : -1)"
        guard let t = try? await webView.evaluateJavaScript(js) as? Double, t >= 0 else { return nil }
        return t
    }

    private func indexNear(time: Double) -> Int {
        if let i = currentIndex, subtitles.indices.contains(i) { return i }
        if let i = subtitles.firstIndex(where: { time < $0.start + max($0.duration, 0.05) }) {
            return i
        }
        return max(0, subtitles.count - 1)
    }

    /// Current line (+ maybe the next) for minimum-latency realtime translation.
    private func realtimeChunk(center: Int) -> [Int]? {
        var indices: [Int] = []
        if needsTranslation(center) { indices.append(center) }
        let next = center + 1
        if next < subtitles.count, needsTranslation(next) {
            indices.append(next)
        }
        // Also cover a cue that just started 1 behind if still on screen overlap.
        let prev = center - 1
        if prev >= 0, needsTranslation(prev), indices.count < 3 {
            indices.insert(prev, at: 0)
        }
        return indices.isEmpty ? nil : indices
    }

    /// Contiguous untranslated cues inside the rolling lookahead window only.
    private func prefetchChunk(center: Int, playhead: Double, maxCount: Int, cueWindow: Int, secondsWindow: Double) -> [Int]? {
        let windowEndIndex = min(subtitles.count, center + cueWindow)
        let windowEndTime = playhead + secondsWindow
        guard let start = (center..<windowEndIndex).first(where: { needsTranslation($0) }) else {
            return nil
        }
        // Don't prefetch far beyond the time window either.
        if subtitles[start].start > windowEndTime { return nil }

        var indices = [start]
        var i = start + 1
        while indices.count < maxCount,
              i < windowEndIndex,
              needsTranslation(i),
              subtitles[i].start <= windowEndTime {
            indices.append(i)
            i += 1
        }
        return indices
    }

    /// Manual "重新翻译": clear translations and restart realtime + prefetch.
    func translateAll() async {
        guard !apiKey.isEmpty else {
            statusMessage = "请在设置中填写 \(provider.rawValue) 的 API Key"
            tabsManager?.showSettings = true
            return
        }
        guard !subtitles.isEmpty else { return }
        for i in subtitles.indices {
            subtitles[i].translation = nil
        }
        await pushSubtitlesToPage()
        startRealtimeTranslation()
    }

    private func startRealtimeTranslation() {
        guard !apiKey.isEmpty else {
            statusMessage = "请在设置中填写 \(provider.rawValue) 的 API Key"
            tabsManager?.showSettings = true
            return
        }
        guard !subtitles.isEmpty else { return }
        translationTask?.cancel()
        translationEpoch &+= 1
        let epoch = translationEpoch
        translationTask = Task { [weak self] in
            await self?.runRealtimeTranslation(epoch: epoch)
        }
    }

    /// Realtime: translate the playhead cue immediately.
    /// Prefetch: keep a rolling window ahead translated (not the whole remaining track).
    private func runRealtimeTranslation(epoch: Int) async {
        let service = TranslationService(
            provider: provider,
            apiKey: apiKey,
            model: model.isEmpty ? provider.defaultModel : model
        )

        // Realtime = tiny batches for low latency; prefetch = modest ahead fill.
        let prefetchBatch = 8
        let prefetchCues = 20          // ~rolling cue window ahead of playhead
        let prefetchSeconds: Double = 75

        while !Task.isCancelled, translationEpoch == epoch {
            let playhead = await currentPlaybackTime()
                ?? currentIndex.map { subtitles[$0].start }
                ?? 0
            let center = indexNear(time: playhead)

            // 1) Realtime — current (and immediate next) cue first.
            if let indices = realtimeChunk(center: center) {
                isTranslating = true
                statusMessage = "实时翻译"
                let ok = await translateIndices(indices, service: service, epoch: epoch)
                if !ok { return }
                continue
            }

            // 2) Prefetch — only within the rolling ahead window.
            if let indices = prefetchChunk(
                center: center,
                playhead: playhead,
                maxCount: prefetchBatch,
                cueWindow: prefetchCues,
                secondsWindow: prefetchSeconds
            ), let first = indices.first, let last = indices.last {
                isTranslating = true
                statusMessage = "预翻译 \(first + 1)–\(last + 1)"
                let ok = await translateIndices(indices, service: service, epoch: epoch)
                if !ok { return }
                continue
            }

            // 3) Window satisfied — idle briefly; playhead advance / seek wakes more work.
            isTranslating = false
            if statusMessage.hasPrefix("实时") || statusMessage.hasPrefix("预翻译") || statusMessage.contains("时间轴") {
                statusMessage = ""
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        if translationEpoch == epoch {
            isTranslating = false
            translationTask = nil
        }
    }

    @discardableResult
    private func translateIndices(_ indices: [Int], service: TranslationService, epoch: Int) async -> Bool {
        guard !indices.isEmpty else { return true }
        let texts = indices.map { subtitles[$0].text }
        do {
            let translated = try await service.translate(texts: texts, to: targetLang)
            if Task.isCancelled || translationEpoch != epoch { return false }
            for (offset, idx) in indices.enumerated() {
                if translated.indices.contains(offset), needsTranslation(idx) {
                    subtitles[idx].translation = translated[offset]
                }
            }
            await pushSubtitlesToPage()
            return true
        } catch {
            if Task.isCancelled || translationEpoch != epoch { return false }
            statusMessage = "翻译失败: \(error.localizedDescription)"
            isTranslating = false
            return false
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        lastLoadedVideoID = nil
        translationTask?.cancel()
        translationEpoch &+= 1
        webView?.reload()
    }
    func stopLoading() { webView?.stopLoading() }
}
