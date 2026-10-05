import Foundation
import UserNotifications

/// Az értesítések kezelése: az „Újraindítás most” gomb, és hogy az értesítés akkor is megjelenjen,
/// ha a Paperboy épp előtérben van.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let restartCategory = "tablet-restart"
    private static let restartAction = "restart-now"

    var onRestartRequested: (() -> Void)?

    func activate() {
        // `swift run`-nál nincs alkalmazáscsomag, ott az értesítési központ nem használható.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let restart = UNNotificationAction(identifier: Self.restartAction, title: "Újraindítás most")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.restartCategory, actions: [restart], intentIdentifiers: []),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.restartAction {
            DispatchQueue.main.async { self.onRestartRequested?() }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
