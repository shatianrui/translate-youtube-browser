import UIKit

/// Only exists to report the current OrientationLock mask to UIKit — SwiftUI's WindowGroup has
/// no hook of its own for `supportedInterfaceOrientationsFor:`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
