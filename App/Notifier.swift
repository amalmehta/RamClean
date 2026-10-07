import Foundation
import UserNotifications

/// Sends the "Quit X?" notifications and routes your button taps back to the app.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        case quit = "QUIT", keep = "KEEP", alwaysKeep = "ALWAYS_KEEP", forceQuit = "FORCE_QUIT", open = "OPEN"
    }

    private static let suggestionCategory = "SUGGESTION"
    private static let forceCategory = "FORCE"
    private static let infoCategory = "INFO"

    var onAction: ((Action, String) -> Void)?
    @MainActor private(set) var authorized = false

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.suggestionCategory, actions: [
                UNNotificationAction(identifier: Action.quit.rawValue, title: "Quit", options: []),
                UNNotificationAction(identifier: Action.keep.rawValue, title: "Keep running", options: []),
                UNNotificationAction(identifier: Action.alwaysKeep.rawValue, title: "Always keep", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.forceCategory, actions: [
                UNNotificationAction(identifier: Action.forceQuit.rawValue, title: "Force Quit", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.infoCategory, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func suggest(key: String, name: String, body: String) {
        send(id: "suggest-\(key)", title: "Quit \(name)?", body: body, category: Self.suggestionCategory, key: key)
    }

    func offerForceQuit(key: String, name: String) {
        send(id: "force-\(key)", title: "\(name) didn't quit", body: "It may be waiting on a dialog or stuck. Force quitting loses unsaved work.",
             category: Self.forceCategory, key: key)
    }

    func diskWarning(free: String, percent: Int) {
        send(id: "disk", title: "Disk is nearly full", body: "Only \(free) free (\(percent)%). RamClean doesn't delete files — check Storage in System Settings.",
             category: Self.infoCategory, key: "disk")
    }

    func sendTest() {
        send(id: "test", title: "RamClean notifications work", body: "Suggestions will look like this, with Quit / Keep running / Always keep buttons.",
             category: Self.suggestionCategory, key: "test")
    }

    private func send(id: String, title: String, body: String, category: String, key: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = ["key": key]
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Show banners even while RamClean is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["key"] as? String ?? ""
        let action = Action(rawValue: response.actionIdentifier) ?? .open
        Task { @MainActor in
            if key != "test" && key != "disk" || action == .open { self.onAction?(action, key) }
            completionHandler()
        }
    }
}
