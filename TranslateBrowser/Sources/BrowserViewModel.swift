import Foundation
import WebKit

/// 翻译状态,用于界面上的状态指示。
enum TranslationStatus: Equatable {
    case idle
    case translating(done: Int, total: Int)
    case finished(total: Int)
    case failed(String)
}

@MainActor
final class BrowserViewModel: NSObject, ObservableObject {
    static let homeURL = URL(string: "https://m.youtube.com")!

    let webView: WKWebView

    @Published var addressText: String = ""
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var status: TranslationStatus = .idle

    private let translationService = TranslationService()
    private var translationTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let userScript = WKUserScript(source: SubtitleScript.source,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false,
                                      in: .page)
        configuration.userContentController.addUserScript(userScript)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        super.init()

        configuration.userContentController.add(WeakMessageHandler(self),
                                                contentWorld: .page,
                                                name: SubtitleScript.messageHandlerName)
        webView.navigationDelegate = self
        observeWebView()
        load(url: Self.homeURL)
    }

    // MARK: - 导航

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// 用户在地址栏提交:识别 URL 或转搜索。
    func submitAddress() {
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = Self.url(fromUserInput: text) {
            load(url: url)
        }
    }

    static func url(fromUserInput text: String) -> URL? {
        if text.contains(" ") || !text.contains(".") {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            return components.url
        }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            return URL(string: text)
        }
        return URL(string: "https://\(text)")
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func goHome() { load(url: Self.homeURL) }

    // MARK: - WKWebView 状态观察

    private func observeWebView() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.isLoading = webView.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.currentURL = webView.url
                    if let url = webView.url { self.addressText = url.absoluteString }
                }
            },
        ]
    }

    // MARK: - 字幕翻译

    private func handleCues(_ lines: [String], frame: WKFrameInfo) {
        translationTask?.cancel()
        status = .translating(done: 0, total: lines.count)

        translationTask = Task { [weak self] in
            guard let self else { return }
            let batchSize = 30
            let targetLanguage = AppSettings.targetLanguage
            var done = 0
            var index = 0
            while index < lines.count {
                if Task.isCancelled { return }
                let batch = Array(lines[index..<min(index + batchSize, lines.count)])
                do {
                    let translated = try await self.translationService
                        .translate(lines: batch, targetLanguage: targetLanguage)
                    if Task.isCancelled { return }
                    self.applyTranslations(translated, startIndex: index, frame: frame)
                    done += batch.count
                    self.status = .translating(done: done, total: lines.count)
                } catch is CancellationError {
                    return
                } catch {
                    self.status = .failed(error.localizedDescription)
                    return
                }
                index += batchSize
            }
            self.status = .finished(total: lines.count)
        }
    }

    private func applyTranslations(_ translated: [String], startIndex: Int, frame: WKFrameInfo) {
        guard let json = try? TranslationService.jsonString(from: translated) else { return }
        let js = "window.__tbApplyTranslations(\(startIndex), \(json));"
        webView.evaluateJavaScript(js, in: frame, in: .page) { _ in }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewModel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.translationTask?.cancel()
            self.status = .idle
        }
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserViewModel: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let name = body["name"] as? String else { return }
        let frame = message.frameInfo
        if name == "cues", let lines = body["payload"] as? [String], !lines.isEmpty {
            Task { @MainActor in self.handleCues(lines, frame: frame) }
        }
    }
}

/// WKUserContentController 会强持有 handler,用弱引用包装避免循环引用。
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler & AnyObject)?

    init(_ target: any WKScriptMessageHandler & AnyObject) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
