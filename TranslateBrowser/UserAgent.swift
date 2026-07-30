import Foundation

enum UserAgent {
    /// iPhone Safari. Used for page loads (so sites serve the phone layout) and for the
    /// out-of-webview caption downloads, which must look like the same client that the page
    /// itself is — YouTube rejects timedtext requests whose UA disagrees with the session.
    static let mobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
}
