import UIKit

/// Exposes the dynamic orientation mask to UIKit. SwiftUI's WindowGroup alone does not provide
/// a supportedInterfaceOrientations hook.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
