import SwiftUI
import WebKit
import UIKit

struct BrowserView: UIViewRepresentable {
    @ObservedObject var tab: Tab
    var onOpenLinkInNewTab: (URL) -> Void = { _ in }

    /// Preserve iOS WKWebView's normal user agent outside YouTube, but request YouTube's
    /// mobile site when navigating there. This avoids forcing desktop Safari or changing
    /// how unrelated pages identify the in-app browser.
    private static let youTubeMobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func userAgent(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        return isYouTubeURL(host: host) ? youTubeMobileUserAgent : nil
    }

    private static func isYouTubeURL(host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com") ||
            host == "youtu.be" || host.hasSuffix(".youtu.be") ||
            host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, onOpenLinkInNewTab: onOpenLinkInNewTab)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Keep playback inside this embedded page. Element fullscreen can hand the player to a
        // separate native controller, which would hide the browser chrome and caption overlay.
        config.preferences.isElementFullscreenEnabled = false
        // Private tabs get an ephemeral, non-persistent data store: no cookies, cache, or
        // history survive once the tab is closed, matching Safari's private browsing.
        if tab.isPrivate {
            config.websiteDataStore = .nonPersistent()
        }

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "tbUrlChanged")
        contentController.add(context.coordinator, name: "tbActiveIndex")
        // Visible-caption fallback: only observes caption text that YouTube has already rendered
        // in this page after the user enables CC. It does not request any other endpoint.
        contentController.add(context.coordinator, name: "tbVisibleCaption")
        contentController.addUserScript(WKUserScript(
            source: SubtitleExtractor.bilingualOverlayJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = BrowserView.userAgent(for: URL(string: tab.urlText))
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        tab.webView = webView
        context.coordinator.observe(webView)

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        context.coordinator.refreshControl = refreshControl

        if let url = URL(string: tab.urlText) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let tab: Tab
        let onOpenLinkInNewTab: (URL) -> Void
        weak var refreshControl: UIRefreshControl?
        private var observations: [NSKeyValueObservation] = []

        init(tab: Tab, onOpenLinkInNewTab: @escaping (URL) -> Void) {
            self.tab = tab
            self.onOpenLinkInNewTab = onOpenLinkInNewTab
        }

        /// YouTube is a single-page app: navigating between videos happens via the History API
        /// (no full page load), so WKNavigationDelegate.didFinish never fires again after the
        /// first load. WKWebView.url is KVO-observable and does update on History API pushes,
        /// so that's the reliable signal for "the user is now watching a different video." The
        /// injected script's "tbUrlChanged" message is a second, redundant signal for the same
        /// event, in case a given YouTube build's pushState usage doesn't trip WKWebView's KVO.
        /// The other KVO paths drive the Safari-style chrome: progress bar, back/forward state,
        /// and the tab switcher's title.
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

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            webView.customUserAgent = BrowserView.userAgent(for: navigationAction.request.url)
            decisionHandler(.allow)
        }

        // Sites such as YouTube can use target=_blank or window.open for playback links. Do not
        // create a second web view; navigate the current embedded page instead.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            webView.load(navigationAction.request)
            return nil
        }

        @objc func handleRefresh() {
            Task { @MainActor in tab.webView?.reload() }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "tbUrlChanged":
                guard let urlString = message.body as? String, let url = URL(string: urlString) else { return }
                Task { @MainActor in tab.onURLChanged(url) }
            case "tbActiveIndex":
                guard let index = message.body as? Int else { return }
                Task { @MainActor in tab.onActiveIndexChanged(index) }
            case "tbVisibleCaption":
                guard let payload = VisibleCaptionPayload(message.body) else { return }
                Task { @MainActor in tab.onVisibleCaption(payload) }
            default:
                break
            }
        }

        // Safari-style long-press link menu: open in a new tab, or copy the link.
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
