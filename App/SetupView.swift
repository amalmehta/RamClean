import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Shown once, the first time the window opens: the three things RamClean needs from you
/// to keep watching and asking, and where what it learns is kept.
struct SetupView: View {
    static let doneKey = "RamCleanSetupDone"
    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var login = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var trusted = AXIsProcessTrusted()
    /// Re-checked every second, so each row turns to "On" as soon as you allow it in System Settings.
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up RamClean").font(.title2.weight(.semibold))
                    Text("It spots apps holding memory you aren't using and asks before quitting any. Three things help it work.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                row("power", "Open at login",
                    "RamClean only watches and learns while it's running, so this keeps it going after a restart.") {
                    Toggle("", isOn: Binding(get: { login == .enabled || login == .requiresApproval }, set: setOpenAtLogin))
                        .toggleStyle(.switch).labelsHidden()
                }
                if login == .requiresApproval {
                    note("macOS needs your OK in Login Items.") { Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() } }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8) }
                Divider()
                row("bell.badge", "Notifications",
                    "How it asks \"Quit?\" when memory is tight. Without them, suggestions only show in the menu bar.") {
                    switch notifications {
                    case .authorized, .provisional: on
                    default: Button("Open Settings…") { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                    }
                }
                Divider()
                row("doc.badge.ellipsis", "Spot unsaved changes",
                    "With Accessibility access, it asks before quitting an app that has unsaved documents. Optional.") {
                    if trusted { on } else {
                        Button("Allow…") {
                            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        }
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text("Your habits and answers stay on this Mac, in \(model.dataDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). You can see or delete them in Settings → Data.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("All of these are in Settings (⌘,) later.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await refresh() }
        .onReceive(recheck) { _ in Task { await refresh() } }
        .onDisappear { UserDefaults.standard.set(true, forKey: Self.doneKey) }
    }

    private var on: some View { Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon) }

    private func row<Trailing: View>(_ symbol: String, _ title: String, _ detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(14)
    }

    private func note<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14).padding(.bottom, 10).padding(.leading, 38)
    }

    private func refresh() async {
        trusted = AXIsProcessTrusted()
        login = SMAppService.mainApp.status
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        login = SMAppService.mainApp.status
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        dismiss()
    }
}

/// Turns Open at login on or off; returns what went wrong, if anything.
enum LoginItem {
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't \(on ? "turn on" : "turn off") Open at login: \(error.localizedDescription)"
        }
    }
}
