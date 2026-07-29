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
    @AppStorage("targetLang") private var targetLang = "中文"

    weak var webView: WKWebView?
    weak var tabsManager: TabsManager?

    private var lastLoadedVideoID: String?
    private var extractionTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    /// Soft retries when timedtext comes back empty after ads / player init races.
    private var captionFetchRetries = 0
    /// Filled asynchronously when the page interceptor steals a player timedtext response.
    private var pendingCapturedBody: String?
    /// Bumped on seek / restart so in-flight chunk results can still apply, but the
    /// next chunk is always chosen from the latest playhead.
    private var translationEpoch = 0
    private var lastSeekNudgeTime: TimeInterval = 0

    /// Real-time cue translation（播放头落到哪条，就优先翻哪条）
    private var realtimeTask: Task<Void, Never>?
    /// Prevent duplicate LLM calls for the same cue index (realtime + prefetch).
    private var translatingIndices: Set<Int> = []

    init(urlText: String, isPrivate: Bool = false) {
        self.urlText = urlText
        self.isPrivate = isPrivate
    }

    var provider: LLMProvider { LLMProvider(rawValue: providerRaw) ?? .openai }

    private var apiKey: String { ProviderCredentials.apiKey(for: provider) }
    private var model: String { ProviderCredentials.resolvedModel(for: provider) }

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
        if let rewritten = BrowserView.normalizedYouTubeURL(from: text) {
            text = rewritten
            urlText = rewritten
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
        // SPA may land on /shorts/ — rewrite to /watch for quality menu + caption APIs.
        if let rewritten = BrowserView.normalizedYouTubeURL(from: url.absoluteString),
           rewritten != url.absoluteString,
           let newURL = URL(string: rewritten) {
            urlText = rewritten
            webView?.load(URLRequest(url: newURL))
            return
        }
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
        captionFetchRetries = 0
        extractionTask?.cancel()
        extractionTask = Task { await extractAndTranslate() }
    }

    func onActiveIndexChanged(_ index: Int) {
        let previous = currentIndex
        currentIndex = subtitles.indices.contains(index) ? index : nil
        guard let currentIndex else { return }

        // 1) Immersive realtime: cue appears => translate immediately.
        if shouldTranslateIndex(currentIndex) {
            scheduleRealtimeCueTranslation(for: currentIndex)
        }

        // 2) Only restart prefetch on real seeks (avoid restarting on every single line change).
        if let previous, abs(currentIndex - previous) >= 2 {
            nudgeTranslationPriority()
        } else if previous == nil {
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
        // Restart prefetch task so pending windows align with the new playhead.
        startRealtimeTranslation()
    }

    private func clearSubtitleState() {
        extractionTask?.cancel()
        translationTask?.cancel()
        realtimeTask?.cancel()
        translatingIndices.removeAll()
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
        statusMessage = ""
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

        // Wait out pre-roll ads so we capture content timedtext, not ad captions.
        try? await Task.sleep(nanoseconds: 600_000_000)
        if Task.isCancelled { return }
        for _ in 0..<40 {
            if Task.isCancelled { return }
            let ad = try? await webView.evaluateJavaScript("""
                (function() {
                  var p = document.getElementById('movie_player')
                    || document.querySelector('.html5-video-player');
                  if (p && p.classList && (p.classList.contains('ad-showing')
                      || p.classList.contains('ad-interrupting'))) return true;
                  return !!document.querySelector('.ad-showing, .ad-interrupting, .ytp-ad-player-overlay');
                })()
                """) as? Bool
            if ad != true { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        // Clear anything captured during the ad break.
        pendingCapturedBody = nil
        _ = try? await webView.evaluateJavaScript(
            "window.__tbClearCaptionCapture && window.__tbClearCaptionCapture();"
        )
        if Task.isCancelled { return }

        // Turn native CC on ASAP — YouTube only emits pot-bearing timedtext while CC is active.
        // Native text is CSS-hidden; we overlay bilingual captions in the same place.
        _ = try? await webView.evaluateJavaScript("window.__tbEnsureCaptionsOn && window.__tbEnsureCaptionsOn('en')")

        var tracks: [CaptionTrack] = []
        for attempt in 0..<16 {
            if Task.isCancelled { return }
            if attempt == 0 || attempt == 4 || attempt == 8 {
                _ = try? await webView.evaluateJavaScript("window.__tbEnsureCaptionsOn && window.__tbEnsureCaptionsOn('en')")
            }
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
            tracks = (try? await SubtitleExtractor.fetchTracksViaAndroidVR(videoID: videoID)) ?? []
        }
        if tracks.isEmpty, let videoID {
            tracks = (try? await SubtitleExtractor.fetchTracksViaEmbedded(videoID: videoID)) ?? []
        }

        // Even without a track list, player capture may still succeed if CC can be toggled.
        let track = tracks.isEmpty
            ? CaptionTrack(baseUrl: "", languageCode: "en", kind: nil, name: nil)
            : pickBestTrack(from: tracks)

        do {
            var subs: [Subtitle] = []

            // Give the player a moment to fire timedtext after CC-on, then prefer that body.
            for _ in 0..<6 {
                if Task.isCancelled { return }
                if let pending = pendingCapturedBody, pending.count > 20 {
                    pendingCapturedBody = nil
                    subs = SubtitleExtractor.parseCaptionBody(pending)
                    if !subs.isEmpty { break }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            if subs.isEmpty {
                // Up to 3 full fetch attempts — intermittent PoToken / race after ads.
                for attempt in 0..<3 {
                    if Task.isCancelled { return }
                    _ = try? await webView.evaluateJavaScript("window.__tbEnsureCaptionsOn && window.__tbEnsureCaptionsOn('en')")
                    if attempt > 0 {
                        pendingCapturedBody = nil
                        _ = try? await webView.evaluateJavaScript(
                            "window.__tbClearCaptionCapture && window.__tbClearCaptionCapture();"
                        )
                        try? await Task.sleep(nanoseconds: UInt64(800_000_000 * attempt))
                    }
                    subs = try await SubtitleExtractor.fetchSubtitles(from: track, videoID: videoID, using: webView)
                    if !subs.isEmpty { break }
                    if let pending = pendingCapturedBody {
                        pendingCapturedBody = nil
                        subs = SubtitleExtractor.parseCaptionBody(pending)
                        if !subs.isEmpty { break }
                    }
                }
            }

            guard !subs.isEmpty else {
                statusMessage = "字幕获取被 YouTube 拦截，请点 ↻ 重试（已默认开启 CC）"
                // Soft auto-retry a couple of times after player/CC settle — not an infinite loop.
                if captionFetchRetries < 2 {
                    captionFetchRetries += 1
                    let retryFor = videoID
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard let self, !Task.isCancelled else { return }
                        guard self.subtitles.isEmpty, self.lastLoadedVideoID == retryFor else { return }
                        await self.extractAndTranslate()
                    }
                }
                return
            }
            if Task.isCancelled { return }
            captionFetchRetries = 0
            subtitles = subs
            statusMessage = ""
            await pushSubtitlesToPage()
            startRealtimeTranslation()

            // Prime the current cue translation immediately (immersive).
            if let playhead = await currentPlaybackTime() {
                let center = indexNear(time: playhead)
                if shouldTranslateIndex(center) {
                    scheduleRealtimeCueTranslation(for: center)
                }
            }
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
            let rawEnd = sub.start + max(sub.duration, 0.001)
            let end: Double
            if i + 1 < subtitles.count {
                // Never spill into the next cue — that desyncs display vs speech.
                end = min(rawEnd, subtitles[i + 1].start)
            } else {
                end = rawEnd
            }
            let safeEnd = end > sub.start ? end : (sub.start + 0.05)
            return PageSubtitle(
                s: sub.start,
                e: safeEnd,
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

    private func shouldTranslateIndex(_ index: Int) -> Bool {
        guard needsTranslation(index) else { return false }
        return !translatingIndices.contains(index)
    }

    /// Read the in-page video clock so realtime / prefetch follow seeks.
    private func currentPlaybackTime() async -> Double? {
        guard let webView else { return nil }
        let js = """
        (function() {
          var p = document.getElementById('movie_player')
            || document.getElementById('shorts-player')
            || document.querySelector('.html5-video-player');
          try {
            if (p && typeof p.getCurrentTime === 'function') {
              var t = p.getCurrentTime();
              if (typeof t === 'number' && isFinite(t) && t >= 0) return t;
            }
          } catch (e) {}
          var v = document.querySelector('video.html5-main-video') || document.querySelector('video');
          return v ? v.currentTime : -1;
        })()
        """
        guard let t = try? await webView.evaluateJavaScript(js) as? Double, t >= 0 else { return nil }
        return t
    }

    private func indexNear(time: Double) -> Int {
        if let i = currentIndex, subtitles.indices.contains(i) { return i }
        // Match page-side [start, end) windows (end clipped to next start).
        for i in subtitles.indices {
            let start = subtitles[i].start
            let rawEnd = start + max(subtitles[i].duration, 0.001)
            let end = i + 1 < subtitles.count ? min(rawEnd, subtitles[i + 1].start) : rawEnd
            if time >= start && time < max(end, start + 0.001) { return i }
        }
        if let i = subtitles.lastIndex(where: { $0.start <= time }) {
            return i
        }
        return 0
    }

    /// Current line (+ maybe the next) for minimum-latency realtime translation.
    private func realtimeChunk(center: Int) -> [Int]? {
        var indices: [Int] = []
        if shouldTranslateIndex(center) { indices.append(center) }
        let next = center + 1
        if next < subtitles.count, shouldTranslateIndex(next) {
            indices.append(next)
        }
        // Also cover a cue that just started 1 behind if still on screen overlap.
        let prev = center - 1
        if prev >= 0, shouldTranslateIndex(prev), indices.count < 3 {
            indices.insert(prev, at: 0)
        }
        return indices.isEmpty ? nil : indices
    }

    /// Contiguous untranslated cues inside the rolling lookahead window only.
    private func prefetchChunk(center: Int, playhead: Double, maxCount: Int, cueWindow: Int, secondsWindow: Double) -> [Int]? {
        let windowEndIndex = min(subtitles.count, center + cueWindow)
        let windowEndTime = playhead + secondsWindow
        // Immersive: skip realtime cue itself; only prefetch following cues.
        let startRangeStart = min(center + 1, subtitles.count)
        guard startRangeStart < windowEndIndex,
              let start = (startRangeStart..<windowEndIndex).first(where: { shouldTranslateIndex($0) }) else {
            return nil
        }
        // Don't prefetch far beyond the time window either.
        if subtitles[start].start > windowEndTime { return nil }

        var indices = [start]
        var i = start + 1
        while indices.count < maxCount,
              i < windowEndIndex,
              shouldTranslateIndex(i),
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

        // Start immersive realtime translation for the currently playing cue.
        if let playhead = await currentPlaybackTime() {
            let center = indexNear(time: playhead)
            if shouldTranslateIndex(center) {
                scheduleRealtimeCueTranslation(for: center)
            }
        }
    }

    private func startRealtimeTranslation() {
        guard !apiKey.isEmpty else {
            statusMessage = "请在设置中填写 \(provider.rawValue) 的 API Key"
            tabsManager?.showSettings = true
            return
        }
        guard !subtitles.isEmpty else { return }
        translationTask?.cancel()
        realtimeTask?.cancel()
        translatingIndices.removeAll()
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
            model: model
        )

        // Prefetch only (realtime cue translation is triggered by `tbActiveIndex`).
        let prefetchBatch = 8
        let prefetchCues = 20          // ~rolling cue window ahead of playhead
        let prefetchSeconds: Double = 75

        while !Task.isCancelled, translationEpoch == epoch {
            let playhead = await currentPlaybackTime()
                ?? currentIndex.map { subtitles[$0].start }
                ?? 0
            let center = indexNear(time: playhead)

            // Prefetch — only within the rolling ahead window.
            if let indices = prefetchChunk(
                center: center,
                playhead: playhead,
                maxCount: prefetchBatch,
                cueWindow: prefetchCues,
                secondsWindow: prefetchSeconds
            ) {
                isTranslating = true
                let ok = await translateIndices(indices, service: service, epoch: epoch)
                if !ok { return }
                continue
            }

            // Window satisfied — idle briefly; playhead advance / seek wakes more work.
            isTranslating = false
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        if translationEpoch == epoch {
            isTranslating = false
            translationTask = nil
        }
    }

    private func scheduleRealtimeCueTranslation(for center: Int) {
        guard shouldTranslateIndex(center) else { return }
        let epoch = translationEpoch
        let service = TranslationService(
            provider: provider,
            apiKey: apiKey,
            model: model
        )

        realtimeTask?.cancel()
        realtimeTask = Task { [weak self] in
            guard let self else { return }
            guard self.translationEpoch == epoch else { return }
            guard let indices = self.realtimeChunk(center: center) else { return }
            let ok = await self.translateIndices(indices, service: service, epoch: epoch)
            if !ok { return }
        }
    }

    @discardableResult
    private func translateIndices(_ indices: [Int], service: TranslationService, epoch: Int) async -> Bool {
        guard !indices.isEmpty else { return true }
        // Mark in-flight so realtime/prefetch won't duplicate the same cue.
        translatingIndices.formUnion(indices)
        defer { translatingIndices.subtract(indices) }

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
        realtimeTask?.cancel()
        translatingIndices.removeAll()
        translationEpoch &+= 1
        webView?.reload()
    }
    func stopLoading() { webView?.stopLoading() }
}
