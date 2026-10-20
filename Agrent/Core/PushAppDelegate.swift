import UIKit
import UserNotifications

/// The one thing SwiftUI cannot hand the app: the APNs device token, which
/// iOS delivers only to an application delegate (agrent-ios#272). And the
/// notifications themselves, as their delegate (#368).
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The notification delegate, set before launch finishes: a tap that
    /// LAUNCHED the app is delivered to the delegate in place by then, and
    /// to no later one.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrar.shared.adopt(deviceToken)
    }

    /// Logged and nothing else: the next launch asks again, and nothing the
    /// person sees depends on a token yet. At `.error`, which iOS keeps:
    /// `.info` is dropped, and this line is what says why a phone never
    /// registered (#359).
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Log.auth.error("no APNs token: \(Log.summary(for: error), privacy: .public)")
    }

    /// One that arrives while the app is open is shown anyway: an
    /// assignment is something to act on, and the person may be looking at
    /// another tab. Without this, iOS shows nothing in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap opens what the notification names (`PushInbox`). Only the tap
    /// itself: a dismissal, if a category ever reports one, opens nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        // Read here, not across the hop: the user info isn't Sendable.
        let link = response.notification.request.content.userInfo["link"] as? String
        await MainActor.run { PushInbox.shared.receive(link: link) }
    }
}
