import SwiftUI
import WebKit
import UIKit

struct BrowserView: UIViewRepresentable {
    @ObservedObject var tab: Tab
    var onOpenLinkInNewTab: (URL) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, onOpenLinkInNewTab: onOpenLinkInNewTab)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        if tab.isPrivate {
            config.websiteDataStore = .nonPersistent()
        }

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "tbUrlChanged")
        contentController.add(context.coordinator, name: "tbActiveIndex")
        contentController.add(context.coordinator, name: "tbCaptionBody")
        contentController.addUserScript(WKUserScript(
            source: SubtitleExtractor.bilingualOverlayJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        contentController.addUserScript(WKUserScript(
            source: YouTubeAdBlock.skipAdsJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController = contentController
        // Prefer desktop layout so www.youtube.com shows quality menu (with Safari UA below).
        config.defaultWebpagePreferences.preferredContentMode = .desktop

        let webView = WKWebView(frame: .zero, configuration: config)
        // Must look like real Safari/WebKit — a fake Chrome UA makes Google Sign-In show
        // “此浏览器可能不安全 / This browser or app may not be secure”.
        webView.customUserAgent = Self.safariDesktopUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .systemBackground
        webView.isOpaque = true
        tab.webView = webView
        context.coordinator.observe(webView)

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        context.coordinator.refreshControl = refreshControl

        Task { @MainActor in
            await YouTubeAdBlock.installContentRules(into: webView.configuration.userContentController)
        }

        let startURL = Self.normalizedYouTubeURL(from: tab.urlText).flatMap(URL.init(string:))
            ?? URL(string: tab.urlText)
        if let startURL {
            webView.load(URLRequest(url: startURL))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Desktop Safari UA matches WKWebView's WebKit engine (unlike Chrome UA) and still
    /// unlocks the classic watch player / quality menu on www.youtube.com.
    static let safariDesktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    /// m.youtube → www; /shorts/ID → /watch?v=ID (full player: quality + captions).
    static func normalizedYouTubeURL(from raw: String) -> String? {
        guard let url = URL(string: raw), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let host = (comps.host ?? "").lowercased()
        guard host.contains("youtube.com") || host.contains("youtu.be") || host.contains("youtube-nocookie.com") else {
            return nil
        }

        var changed = false
        if host.hasPrefix("m.") || host == "m.youtube.com" || host == "mobile.youtube.com" {
            comps.host = "www.youtube.com"
            changed = true
        }
        if host.contains("youtu.be") {
            let id = url.path.split(separator: "/").first.map(String.init)
            if let id, !id.isEmpty {
                comps.scheme = "https"
                comps.host = "www.youtube.com"
                comps.path = "/watch"
                comps.queryItems = [URLQueryItem(name: "v", value: id)]
                return comps.url?.absoluteString
            }
        }

        let parts = comps.path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "shorts" {
            let id = parts[1].split(separator: "?").first.map(String.init) ?? parts[1]
            comps.scheme = comps.scheme ?? "https"
            comps.host = "www.youtube.com"
            comps.path = "/watch"
            comps.queryItems = [URLQueryItem(name: "v", value: id)]
            changed = true
        }

        return changed ? comps.url?.absoluteString : nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let tab: Tab
        let onOpenLinkInNewTab: (URL) -> Void
        weak var refreshControl: UIRefreshControl?
        private var observations: [NSKeyValueObservation] = []

        init(tab: Tab, onOpenLinkInNewTab: @escaping (URL) -> Void) {
            self.tab = tab
            self.onOpenLinkInNewTab = onOpenLinkInNewTab
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url, options: [.new]) { [weak self] _, change in
                    guard let self, let url = change.newValue ?? nil else { return }
                    Task { @MainActor in self.tab.onURLChanged(url) }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    let value = webView.estimatedProgress
                    Task { @MainActor in self?.tab.estimatedProgress = value }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                    let value = webView.canGoBack
                    Task { @MainActor in self?.tab.canGoBack = value }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                    let value = webView.canGoForward
                    Task { @MainActor in self?.tab.canGoForward = value }
                },
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    let value = webView.title ?? ""
                    Task { @MainActor in self?.tab.pageTitle = value }
                },
            ]
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let rewritten = BrowserView.normalizedYouTubeURL(from: url.absoluteString),
               rewritten != url.absoluteString,
               let newURL = URL(string: rewritten) {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: newURL))
                return
            }
            decisionHandler(.allow)
        }

        /// Google Sign-In and many OAuth flows open a popup (`target=_blank`). Load it in-place.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            presentAlert(alert, from: webView) { completionHandler() }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
            presentAlert(alert, from: webView) { completionHandler(false) }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            presentAlert(alert, from: webView) { completionHandler(nil) }
        }

        private func presentAlert(
            _ alert: UIAlertController,
            from webView: WKWebView,
            onUnavailable: @escaping () -> Void
        ) {
            var responder: UIResponder? = webView
            while let current = responder {
                if let vc = current as? UIViewController {
                    vc.present(alert, animated: true)
                    return
                }
                responder = current.next
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController {
                var top = root
                while let presented = top.presentedViewController { top = presented }
                top.present(alert, animated: true)
                return
            }
            onUnavailable()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                tab.onURLChanged(webView.url)
                refreshControl?.endRefreshing()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in refreshControl?.endRefreshing() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in refreshControl?.endRefreshing() }
        }

        @objc func handleRefresh() {
            Task { @MainActor in tab.reload() }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "tbUrlChanged":
                guard let urlString = message.body as? String, let url = URL(string: urlString) else { return }
                Task { @MainActor in tab.onURLChanged(url) }
            case "tbActiveIndex":
                guard let index = message.body as? Int else { return }
                Task { @MainActor in tab.onActiveIndexChanged(index) }
            case "tbCaptionBody":
                if let dict = message.body as? [String: Any],
                   let body = dict["body"] as? String, body.count > 20 {
                    Task { @MainActor in tab.onCapturedCaptionBody(body) }
                }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
            completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
        ) {
            guard let linkURL = elementInfo.linkURL else {
                completionHandler(nil)
                return
            }
            let menuConfig = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [onOpenLinkInNewTab] _ in
                let openAction = UIAction(title: "在新标签页中打开", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    onOpenLinkInNewTab(linkURL)
                }
                let copyAction = UIAction(title: "复制链接", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = linkURL
                }
                return UIMenu(title: linkURL.absoluteString, children: [openAction, copyAction])
            }
            completionHandler(menuConfig)
        }
    }
}
