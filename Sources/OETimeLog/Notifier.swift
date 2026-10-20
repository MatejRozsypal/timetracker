import Foundation
import UserNotifications

/// Quiet banners for the fallback nudge and the end-of-day sweep. The panel and
/// the menu bar icon are the primary prompts; notifications are a bonus because
/// Focus modes can mute them.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String { case nudge, sweep }

    /// Reply text typed into the banner (nudge only), or nil when the banner was clicked.
    var onNudge: ((String?) -> Void)?
    var onSweep: (() -> Void)?

    private let center = UNUserNotificationCenter.current()

    func setUp() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: "reply", title: "Log it", options: [],
            textInputButtonTitle: "Save", textInputPlaceholder: "dob meta review g")
        let nudge = UNNotificationCategory(identifier: Kind.nudge.rawValue, actions: [reply], intentIdentifiers: [])
        let sweep = UNNotificationCategory(identifier: Kind.sweep.rawValue, actions: [], intentIdentifiers: [])
        center.setNotificationCategories([nudge, sweep])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ kind: Kind, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = kind.rawValue
        let req = UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil)
        center.add(req)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        DispatchQueue.main.async {
            if category == Kind.sweep.rawValue { self.onSweep?() } else { self.onNudge?(text) }
        }
        completionHandler()
    }
}
