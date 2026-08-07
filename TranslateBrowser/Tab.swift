import Foundation
import WebKit
import Combine
import SwiftUI
import os

/// One browser tab: its own WKWebView plus YouTube subtitle extraction/translation state.
@MainActor
final class Tab: ObservableObject, Identifiable {
    private static let logger = Logger(subsystem: "com.translatebrowser.app", category: "Translation")

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

    private func clearSubtitleState() {
        extractionTask?.cancel()
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
        let videoID = lastLoadedVideoID
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

        // Page tracks missing (or still loading): resolve via InnerTube ANDROID_VR.
        if tracks.isEmpty, let videoID {
            statusMessage = "正在通过备用通道获取字幕轨…"
            tracks = (try? await SubtitleExtractor.fetchTracksViaAndroidVR(videoID: videoID)) ?? []
        }

        guard !tracks.isEmpty else {
            statusMessage = "该视频没有可用字幕"
            return
        }

        let track = pickBestTrack(from: tracks)
        statusMessage = "正在下载字幕（\(track.languageCode)）…"

        do {
            let subs = try await SubtitleExtractor.fetchSubtitles(from: track, videoID: videoID, using: webView)
            guard !subs.isEmpty else {
                statusMessage = "字幕内容为空（可能被 YouTube 限制，请稍后重试）"
                return
            }
            if Task.isCancelled { return }
            subtitles = subs
            statusMessage = "已提取 \(subs.count) 条字幕，开始翻译…"
            await pushSubtitlesToPage()
            await translateAll()
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
        let d: Double
        let o: String
        let t: String
    }

    private func pushSubtitlesToPage() async {
        guard let webView else { return }
        // While a translation pass is running, show a "翻译中…" placeholder for cues that
        // haven't completed yet instead of leaving the translation line blank (which made the
        // overlay look like it was stuck showing only the English original).
        let placeholder = isTranslating ? "翻译中…" : ""
        let payload = subtitles.map {
            PageSubtitle(s: $0.start, d: $0.duration, o: $0.text, t: $0.translation ?? placeholder)
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
        let targetLang = self.targetLang
        isTranslating = true
        defer { isTranslating = false }
        let chunkSize = 20
        // Run a few chunks concurrently so translation streams in faster/smoother,
        // instead of waiting for each chunk's network round-trip one at a time.
        let maxConcurrent = 3
        let ranges = stride(from: 0, to: subtitles.count, by: chunkSize).map { start in
            (start, min(start + chunkSize, subtitles.count))
        }
        // Precompute the text for each chunk up front so the task-scheduling closure below
        // never needs to read the main-actor-isolated `subtitles` property itself.
        let textChunks: [[String]] = ranges.map { subtitles[$0.0..<$0.1].map(\.text) }
        var completedCount = 0
        var lastErrorMessage: String?

        // Runs one concurrency-limited pass over the given range indices, applying successful
        // translations directly to `subtitles` and returning the indices that still failed so
        // the caller can retry them.
        func runPass(_ rangeIndices: [Int]) async -> [Int] {
            var stillFailed: [Int] = []
            await withTaskGroup(of: (Int, Result<[String], Error>).self) { group in
                var iterator = rangeIndices.makeIterator()

                func startNext() {
                    guard let rangeIndex = iterator.next() else { return }
                    let texts = textChunks[rangeIndex]
                    group.addTask {
                        do {
                            let translated = try await service.translate(texts: texts, to: targetLang)
                            return (rangeIndex, .success(translated))
                        } catch {
                            return (rangeIndex, .failure(error))
                        }
                    }
                }

                for _ in 0..<maxConcurrent { startNext() }

                while let (rangeIndex, result) = await group.next() {
                    if Task.isCancelled { break }
                    let (start, end) = ranges[rangeIndex]
                    switch result {
                    case .success(let translated):
                        for i in start..<end {
                            let idx = i - start
                            if translated.indices.contains(idx) {
                                subtitles[i].translation = translated[idx]
                            }
                        }
                        completedCount += (end - start)
                        statusMessage = "已翻译 \(completedCount)/\(subtitles.count)"
                        await pushSubtitlesToPage()
                    case .failure(let error):
                        // Log full error detail (HTTP status/body for bad responses, or the
                        // underlying network error) so translation failures are diagnosable
                        // instead of silently leaving the English original on screen.
                        Self.logger.error("翻译分片 [\(start)-\(end)) 失败: \(String(describing: error), privacy: .public)")
                        lastErrorMessage = error.localizedDescription
                        stillFailed.append(rangeIndex)
                    }
                    startNext()
                }
            }
            return stillFailed
        }

        var failedRangeIndices = await runPass(Array(ranges.indices))

        // Automatically retry failed chunks once — most failures are transient (timeouts,
        // rate limiting) and a single retry clears them without user intervention.
        if !failedRangeIndices.isEmpty, !Task.isCancelled {
            statusMessage = "部分字幕翻译失败，正在重试…"
            failedRangeIndices = await runPass(failedRangeIndices)
        }

        guard !Task.isCancelled else { return }
        if !failedRangeIndices.isEmpty {
            // Mark still-failing cues explicitly instead of leaving `translation` nil, which
            // made the overlay fall back to showing only the (English) original with no
            // indication that translation had failed.
            var failedCount = 0
            for rangeIndex in failedRangeIndices {
                let (start, end) = ranges[rangeIndex]
                failedCount += (end - start)
                for i in start..<end where subtitles[i].translation == nil {
                    subtitles[i].translation = "⚠️ 翻译失败"
                }
            }
            statusMessage = "翻译完成，\(failedCount) 条失败: \(lastErrorMessage ?? "")"
        } else {
            statusMessage = "翻译完成（\(provider.rawValue)）"
        }
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
