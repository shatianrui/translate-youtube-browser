import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    @ObservedObject var viewModel: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Let YouTube's fullscreen button use the standards Fullscreen API on the player's own
        // DOM container (which our injected script redirects it to) instead of falling back to
        // a separate native full-screen video controller that would cover our caption overlay.
        config.preferences.isElementFullscreenEnabled = true

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
        webView.allowsBackForwardNavigationGestures = true
        viewModel.webView = webView
        context.coordinator.observeURL(of: webView)
        if let url = URL(string: viewModel.urlText) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let viewModel: BrowserViewModel
        private var urlObservation: NSKeyValueObservation?

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }

        /// YouTube is a single-page app: navigating between videos happens via the History API
        /// (no full page load), so WKNavigationDelegate.didFinish never fires again after the
        /// first load. WKWebView.url is KVO-observable and does update on History API pushes,
        /// so that's the reliable signal for "the user is now watching a different video." The
        /// injected script's "tbUrlChanged" message is a second, redundant signal for the same
        /// event, in case a given YouTube build's pushState usage doesn't trip WKWebView's KVO.
        func observeURL(of webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let self, let url = change.newValue ?? nil else { return }
                Task { @MainActor in
                    self.viewModel.onURLChanged(url)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.onURLChanged(webView.url)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "tbUrlChanged":
                guard let urlString = message.body as? String, let url = URL(string: urlString) else { return }
                Task { @MainActor in viewModel.onURLChanged(url) }
            case "tbActiveIndex":
                guard let index = message.body as? Int else { return }
                Task { @MainActor in viewModel.onActiveIndexChanged(index) }
            default:
                break
            }
        }
    }
}
