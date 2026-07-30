import UIKit

/// Keeps orientation state per UIWindowScene so a fullscreen video in one iPad window cannot
/// rotate or constrain another browser window.
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    private var masks: [String: UIInterfaceOrientationMask] = [:]

    private init() {}

    func mask(for scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        guard let scene else { return .allButUpsideDown }
        return masks[scene.session.persistentIdentifier] ?? .allButUpsideDown
    }

    func setFullscreen(_ isFullscreen: Bool, in scene: UIWindowScene?) {
        guard let scene else { return }
        let mask: UIInterfaceOrientationMask = isFullscreen ? .landscape : .allButUpsideDown
        masks[scene.session.persistentIdentifier] = mask
        let rootVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController
        rootVC?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}
