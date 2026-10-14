import UIKit

/// The one thing SwiftUI cannot hand the app: the APNs device token, which
/// iOS delivers only to an application delegate (agrent-ios#272).
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrar.shared.adopt(deviceToken)
    }

    /// Logged and nothing else: the next launch asks again, and nothing the
    /// person sees depends on a token yet.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Log.auth.info("no APNs token: \(Log.summary(for: error), privacy: .public)")
    }
}
