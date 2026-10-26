import AppKit
import SwiftUI

@main
struct RamCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var updater = Updater.shared

    var body: some Scene {
        Window("RamClean", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 960, height: 640)

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                if !model.licensing.config.isFree { Button("Licence…") { model.showLicenceSettings() } }
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.start() }
    }

    // Keep watching from the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let used = Int((model.system?.memoryUsedFraction ?? 0) * 100)
        HStack(spacing: 3) {
            Image(systemName: model.system?.pressure == .normal || model.system == nil ? "memorychip" : "memorychip.fill")
            Text("\(used)%").monospacedDigit()
        }
        // The menu bar item is always alive, so it lends the model a way to open the window.
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            model.openSettings = { openSettings() }
        }
    }
}
