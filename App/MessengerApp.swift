import SwiftUI
import UIKit
import UserNotifications

/// Strapify Messenger for iPhone: a native shell around messenger.strapify.com.au.
/// Everything on screen is the live web messenger, so a messenger deploy updates the app
/// with no new build. The shell only adds what a web page cannot do well on iOS:
/// Apple push notifications, opening the right conversation from a notification, and
/// camera/microphone for huddles without a second prompt.
@main
struct MessengerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WebScreen()
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

enum Config {
    static let origin = URL(string: "https://messenger.strapify.com.au")!
    static let start = URL(string: "https://messenger.strapify.com.au/messenger")!
    static let ownHost = "messenger.strapify.com.au"
    static let tokenKey = "apnsDeviceToken"

    /// Pages that stay inside the app; every other link opens in Safari.
    static func isOwnHost(_ url: URL) -> Bool {
        url.host?.lowercased() == ownHost
    }
}

extension Notification.Name {
    /// Posted with userInfo["url"] (URL) when a notification tap should open a conversation.
    static let openMessengerURL = Notification.Name("openMessengerURL")
    /// Posted with userInfo["token"] (String) when Apple hands over a device token.
    static let apnsToken = Notification.Name("apnsToken")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// A tap that launched the app before the web view existed; the web view reads it once.
    static var pendingURL: URL?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Config.tokenKey)
        NotificationCenter.default.post(name: .apnsToken, object: nil, userInfo: ["token": token])
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: %@", error.localizedDescription)
    }

    /// Show banners while the app is open too: the server already decides who needs one.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["url"] as? String ?? "/messenger"
        if let url = URL(string: path, relativeTo: Config.origin)?.absoluteURL, Config.isOwnHost(url) {
            AppDelegate.pendingURL = url
            NotificationCenter.default.post(name: .openMessengerURL, object: nil, userInfo: ["url": url])
        }
        completionHandler()
    }
}
