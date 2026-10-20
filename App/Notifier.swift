import Foundation
import RamCleanCore
import UserNotifications

/// Sends the "Quit X?" notifications and routes your button taps back to the app.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        case quit = "QUIT", keep = "KEEP", alwaysKeep = "ALWAYS_KEEP", forceQuit = "FORCE_QUIT", open = "OPEN"
        case relaunch = "RELAUNCH"
        case alertFix = "ALERT_FIX", alertShow = "ALERT_SHOW", alertSnooze = "ALERT_SNOOZE"
    }

    private static let suggestionCategory = "SUGGESTION"
    private static let forceCategory = "FORCE"
    private static let quitDoneCategory = "QUIT_DONE"
    private static let infoCategory = "INFO"
    private static func fixCategory(_ r: Resource) -> String { "ALERT_WITH_FIX_\(r.rawValue.uppercased())" }
    private static let alertCategory = "ALERT"

    /// The ram picture on each kind of notification, from App/NotificationArt
    /// (drawn by scripts/make-notification-art.swift).
    private enum Art: String {
        case idle = "notif-idle", stuck = "notif-stuck", quitDone = "notif-quit-done", problem = "notif-problem"
        case memory = "notif-memory", cpu = "notif-cpu", disk = "notif-disk"

        init(_ r: Resource) {
            switch r {
            case .memory: self = .memory
            case .cpu: self = .cpu
            case .disk: self = .disk
            }
        }
    }

    /// Each alert's one-tap fix label ("Quit Spotify", "Trash uv"), so an older alert keeps
    /// its own button when a newer one arrives.
    private var fixTitles: [Resource: String] = [:]

    /// Called with the button tapped and the notification's userInfo.
    var onAction: ((Action, [AnyHashable: Any]) -> Void)?
    @MainActor private(set) var authorized = false

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// A category's buttons are fixed, so each resource with a fix gets its own category,
    /// re-registered with its current label just before its alert goes out.
    private func registerCategories() {
        let show = UNNotificationAction(identifier: Action.alertShow.rawValue, title: "Show recommendations", options: [.foreground])
        let snooze = UNNotificationAction(identifier: Action.alertSnooze.rawValue, title: "Snooze 1 hour", options: [])
        let fixed: [UNNotificationCategory] = [
            UNNotificationCategory(identifier: Self.suggestionCategory, actions: [
                UNNotificationAction(identifier: Action.quit.rawValue, title: "Quit", options: []),
                UNNotificationAction(identifier: Action.keep.rawValue, title: "Keep running", options: []),
                UNNotificationAction(identifier: Action.alwaysKeep.rawValue, title: "Always keep", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.forceCategory, actions: [
                UNNotificationAction(identifier: Action.forceQuit.rawValue, title: "Force Quit", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.quitDoneCategory, actions: [
                UNNotificationAction(identifier: Action.relaunch.rawValue, title: "Relaunch", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.infoCategory, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.alertCategory, actions: [show, snooze], intentIdentifiers: []),
        ]
        let fixes = fixTitles.map { resource, title in
            UNNotificationCategory(identifier: Self.fixCategory(resource), actions: [
                UNNotificationAction(identifier: Action.alertFix.rawValue, title: title, options: []), show, snooze,
            ], intentIdentifiers: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(fixed + fixes))
    }

    /// A threshold alert: what crossed the line, what to do, and a one-tap fix when there is one.
    func alert(_ content: AlertContent) {
        var info: [String: String] = ["resource": content.resource.rawValue]
        if let a = content.action {
            fixTitles[content.resource] = a.label
            registerCategories()
            info["fixKind"] = a.kind.rawValue
            info["fixTarget"] = a.target
        }
        let n = UNMutableNotificationContent()
        n.title = content.title
        n.body = content.body
        n.categoryIdentifier = content.action == nil ? Self.alertCategory : Self.fixCategory(content.resource)
        n.userInfo = info
        n.threadIdentifier = Self.alertCategory
        n.sound = .default
        n.attachments = Self.attachments(Art(content.resource))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alert-\(content.resource.rawValue)", content: n, trigger: nil))
    }

    func suggest(key: String, name: String, body: String) {
        send(id: "suggest-\(key)", title: "Quit \(name)?", body: body, category: Self.suggestionCategory, key: key, art: .idle)
    }

    func offerForceQuit(key: String, name: String) {
        send(id: "force-\(key)", title: "\(name) didn't quit", body: "It may be waiting on a dialog or stuck. Force quitting loses unsaved work.",
             category: Self.forceCategory, key: key, art: .stuck)
    }

    /// The app RamClean quit is gone; one tap brings it back if that was a mistake.
    func quitDone(key: String, name: String, body: String) {
        withdraw(["force-\(key)", "suggest-\(key)"])
        send(id: "quit-done-\(key)", title: "Quit \(name)", body: body, category: Self.quitDoneCategory, key: key, art: .quitDone)
    }

    func withdraw(_ ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Something RamClean tried on your behalf didn't work.
    func problem(_ title: String, _ detail: String) {
        send(id: "problem-\(UUID().uuidString)", title: title, body: detail, category: Self.infoCategory, key: "problem", art: .problem)
    }

    func sendTest() {
        send(id: "test", title: "RamClean notifications work", body: "Suggestions will look like this, with Quit / Keep running / Always keep buttons.",
             category: Self.suggestionCategory, key: "test", art: .idle)
    }

    private func send(id: String, title: String, body: String, category: String, key: String, art: Art) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        // Stack by kind in Notification Center, so a Quit all reads as one group of "Quit …".
        content.threadIdentifier = category
        content.userInfo = ["key": key]
        content.sound = nil
        content.attachments = Self.attachments(art)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The system moves an attachment's file into its own store, so each send gets a fresh copy.
    private static func attachments(_ art: Art) -> [UNNotificationAttachment] {
        guard let src = Bundle.main.url(forResource: art.rawValue, withExtension: "png") else { return [] }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(art.rawValue).png")
        guard (try? FileManager.default.copyItem(at: src, to: copy)) != nil,
              let a = try? UNNotificationAttachment(identifier: art.rawValue, url: copy) else { return [] }
        return [a]
    }

    // Show banners even while RamClean is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = Action(rawValue: response.actionIdentifier) ?? .open
        Task { @MainActor in
            if info["key"] as? String != "test" || action == .open { self.onAction?(action, info) }
            completionHandler()
        }
    }
}
