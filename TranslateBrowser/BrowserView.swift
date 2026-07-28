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
        config.mediaTypesRequiringUserActionForPlayback = []
        // Let YouTube's fullscreen button use the standards Fullscreen API on the player's own
        // DOM container (which our injected script redirects it to) instead of falling back to
        // a separate native full-screen video controller that would cover our caption overlay.
        config.preferences.isElementFullscreenEnabled = true
        // Private tabs get an ephemeral, non-persistent data store: no cookies, cache, or
        // history survive once the tab is closed, matching Safari's private browsing.
        if tab.isPrivate {
            config.websiteDataStore = .nonPersistent()
        }

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "tbUrlChanged")
        contentController.add(context.coordinator, name: "tbActiveIndex")
        contentController.addUserScript(WKUserScript(
            source: SubtitleExtractor.bilingualOverlayJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
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
