import UIKit
import Combine

/// Synchronizes the app's orientation policy with YouTube playback. Native iOS video fullscreen
/// is intentionally left to WKWebView; this class only forces the containing app to landscape.
@MainActor
final class OrientationLock: ObservableObject {
    static let shared = OrientationLock()

    @Published private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown

    private init() {}

    func setFullscreen(_ isFullscreen: Bool) {
        mask = isFullscreen ? .landscape : .allButUpsideDown
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let rootVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController
        rootVC?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}
