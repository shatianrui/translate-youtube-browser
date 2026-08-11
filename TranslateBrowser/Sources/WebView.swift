import SwiftUI
import WebKit

/// 把视图模型持有的 WKWebView 嵌入 SwiftUI。
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
