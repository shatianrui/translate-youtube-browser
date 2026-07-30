import UIKit
import Combine

/// Drives landscape video playback: the moment the page's video element enters fullscreen we
/// lock the app to landscape and force an immediate rotation (so playback goes landscape right
/// away, matching the YouTube app, instead of waiting for the user to physically turn the
/// phone). Exiting fullscreen releases the lock back to free rotation.
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
