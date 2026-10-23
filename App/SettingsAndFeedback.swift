import AppKit
import RamCleanCore
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable { case general, thresholds, protection, data, licence }

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ThresholdSettings().tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }.tag(SettingsTab.thresholds)
            ProtectionSettings().tabItem { Label("Protection", systemImage: "lock.shield") }.tag(SettingsTab.protection)
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }.tag(SettingsTab.data)
            LicenceSettings().tabItem { Label("Licence", systemImage: "key") }.tag(SettingsTab.licence)
        }
        .frame(width: 560, height: 470)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = Updater.shared
    /// Re-checked every second, so the row flips to "On" as soon as you grant access.
    @State private var trusted = AXIsProcessTrusted()
    @State private var login = SMAppService.mainApp.status
    @State private var loginError: String?
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Toggle("Open at login", isOn: Binding(get: { login == .enabled || login == .requiresApproval }, set: setOpenAtLogin))
            if login == .requiresApproval {
                LabeledContent("macOS needs your OK to open RamClean at login") {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Send notifications suggesting apps to quit", isOn: $model.prefs.notificationsEnabled)
            Toggle("Send a summary of last week on Monday mornings", isOn: $model.prefs.weeklySummaryEnabled)
            Button("Send a test notification") { model.notifier.sendTest() }
            Picker("Check every", selection: $model.prefs.checkInterval) {
                ForEach([5.0, 10, 15, 30, 60, 120], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
            Text("In Low Power Mode, RamClean checks at most once a minute.").font(.caption).foregroundStyle(.secondary)
            Picker("Offer Force Quit after", selection: $model.prefs.forceQuitAfterSeconds) {
                ForEach([5.0, 8, 10, 15, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
            Text("RamClean asks apps to quit politely first. If one is still running after this long, it offers Force Quit (which loses unsaved work).")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Spot unsaved changes before quitting") {
                if trusted {
                    Text("On").foregroundStyle(.secondary)
                } else {
                    Button("Allow Accessibility…") {
                        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    }
                }
            }
            Text("RamClean always asks before quitting the app you're using. With Accessibility access it also asks before quitting an app with unsaved documents.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                .disabled(!updater.isConfigured)
            LabeledContent(updater.isConfigured ? "Updates are signed and checked against RamClean's update feed" : "Updates aren't set up in this copy yet") {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
        }
        .formStyle(.grouped)
        .onReceive(recheck) { _ in
            trusted = AXIsProcessTrusted()
            login = SMAppService.mainApp.status
        }
    }

    /// RamClean only watches while it's running, so opening at login keeps its habit
    /// data and alerts going after a restart.
    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't \(on ? "turn on" : "turn off") Open at login: \(error.localizedDescription)"
        }
        login = SMAppService.mainApp.status
    }
}

private struct ThresholdSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("When to suggest") {
                slider("Memory used at least", $model.prefs.memoryTriggerPercent, 50...95, 5, "%")
                slider("App uses at least", $model.prefs.minAppMemoryMB, 100...3000, 100, " MB")
                slider("Or idle app CPU at least", $model.prefs.cpuHogPercent, 20...200, 10, "%")
                slider("Deadweight score at least", Binding(get: { model.prefs.deadweightThreshold * 100 },
                                                            set: { model.prefs.deadweightThreshold = $0 / 100 }), 50...95, 5, "%")
            }
            Section("How often") {
                slider("Ask about the same app at most every", $model.prefs.cooldownHours, 1...24, 1, " h")
                slider("At most one suggestion every", $model.prefs.minMinutesBetweenNotifications, 1...60, 1, " min")
            }
            Section("Alerts: notify with what to quit, clear or move") {
                Toggle("Alert when memory, CPU or disk crosses its threshold", isOn: $model.prefs.alertsEnabled)
                slider("Memory used at least", $model.prefs.memoryAlertPercent, 50...99, 1, "%")
                slider("CPU at least", $model.prefs.cpuAlertPercent, 50...100, 1, "%")
                LabeledContent("…for at least") {
                    Stepper("\(Int(model.prefs.cpuAlertMinutes)) min", value: $model.prefs.cpuAlertMinutes, in: 1...15)
                }
                slider("Disk used at least", $model.prefs.diskAlertUsedPercent, 80...100, 1, "%")
                Picker("While still over, remind every", selection: $model.prefs.alertRepeatMinutes) {
                    ForEach([15.0, 30, 60, 120, 240], id: \.self) { Text($0 < 60 ? "\(Int($0)) min" : "\(Int($0 / 60)) h").tag($0) }
                }
            }
            Section("What counts as unused") {
                LabeledContent("Not opened for") {
                    Stepper("\(Int(model.prefs.staleDays)) days", value: $model.prefs.staleDays, in: 30...365, step: 15)
                }
                LabeledContent("Active work if touched within") {
                    Stepper("\(Int(model.prefs.activeDays)) days", value: $model.prefs.activeDays, in: 7...90, step: 7)
                }
                Text("Apps, downloads and big files you haven't opened in that long are suggested for removal or moving off the Mac. Projects and files changed recently, and build folders being written to, are never suggested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 180)
                Text("\(Int(value.wrappedValue))\(unit)").monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
}

private struct ProtectionSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newWorkTool = ""

    var body: some View {
        Form {
            Section("Never suggest") {
                slider
                Toggle("Apps that are busy working (Xcode building, Claude generating, …)", isOn: $model.prefs.protectBusyWorkTools)
                LabeledContent("Busy means CPU above") {
                    Stepper("\(Int(model.prefs.busyCPUPercent))%", value: $model.prefs.busyCPUPercent, in: 5...100, step: 5)
                }
                Toggle("Menu bar utilities", isOn: Binding(get: { !model.prefs.includeMenuBarApps }, set: { model.prefs.includeMenuBarApps = !$0 }))
                Text("Apps playing audio, the app in front, terminals running a command, and macOS itself are always protected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Always keep") {
                if model.prefs.alwaysKeep.isEmpty { Text("Tap “Always keep” on a notification to add an app here.").foregroundStyle(.secondary) }
                ForEach(model.prefs.alwaysKeep, id: \.self) { id in
                    HStack {
                        Text(model.habitStore.habits[id]?.name ?? id)
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.prefs.alwaysKeep.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Work tools (bundle IDs; * matches a prefix)") {
                ForEach(model.prefs.workTools, id: \.self) { id in
                    HStack {
                        Text(id).font(.callout.monospaced())
                        Spacer()
                        Button { model.prefs.workTools.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("com.example.App", text: $newWorkTool).onSubmit(addWorkTool)
                    Button("Add", action: addWorkTool).disabled(newWorkTool.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Restore defaults") { model.prefs.workTools = Preferences.defaultWorkTools }
            }
        }
        .formStyle(.grouped)
    }

    private var slider: some View {
        LabeledContent("Apps used in the last") {
            Stepper("\(Int(model.prefs.recentUseMinutes)) min", value: $model.prefs.recentUseMinutes, in: 0...240, step: 5)
        }
    }

    private func addWorkTool() {
        let id = newWorkTool.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !model.prefs.workTools.contains(id) else { return }
        model.prefs.workTools.append(id)
        newWorkTool = ""
    }
}

private struct DataSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Stored on this Mac only") {
                LabeledContent("Folder", value: model.dataDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Text("habits.json (usage per app per day), events.jsonl (activity log), training.jsonl (your answers), feedback.jsonl.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.dataDirectory]) }
            }
            Section {
                Button("Clear habit history…", role: .destructive) { confirmClear = true }
                Button("Reset preferences to defaults") { model.prefs = Preferences() }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all recorded habits and the activity log?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { model.clearHabits() }
        }
    }
}

/// Trial days left, licensed, offline or expired; Buy; and the licence key.
private struct LicenceSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var message: String?
    @State private var busy = false
    @State private var confirmDeactivate = false
    @State private var deactivateFailed = false

    var body: some View {
        let state = model.licence, config = model.licensing.config
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: LicenceBadge.symbol(state)).font(.title).foregroundStyle(LicenceBadge.tint(state))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title).font(.headline)
                        Text(state.detail(config)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !state.isLicensed {
                    Button("Buy \(config.name) – \(config.price)") { model.buy() }.buttonStyle(.borderedProminent)
                }
                if let problem = model.licenceProblem {
                    Text(problem).font(.callout).foregroundStyle(.orange)
                }
            }
            if let r = model.licenceRecord {
                Section("Licence key") {
                    LabeledContent("Key", value: r.maskedKey)
                    if let email = r.customerEmail { LabeledContent("Registered to", value: email) }
                    LabeledContent("Last checked", value: r.lastValidated.formatted(date: .abbreviated, time: .shortened))
                    HStack {
                        Button("Check Now") { run { await model.checkLicence(); return nil } }
                        Spacer()
                        Button("Deactivate on This Mac…") { confirmDeactivate = true }
                    }
                    .disabled(busy)
                    if deactivateFailed {
                        Button("Remove the Key from This Mac Anyway", role: .destructive) {
                            model.forgetLicence()
                            deactivateFailed = false
                            message = nil
                        }
                    }
                    Text("Deactivating frees this Mac's activation, so you can use the key on another Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Licence key") {
                    TextField("Key", text: $key, prompt: Text("Paste the key from your receipt email"))
                        .font(.body.monospaced())
                        .onSubmit(activate)
                    Button("Activate", action: activate).disabled(busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Activating sends the key and this Mac's name to Lemon Squeezy, the licence server. RamClean re-checks the key about once a day and keeps working offline for \(config.offlineGraceDays) days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.red) }
            Link("Website, privacy and refunds", destination: config.websiteURL).font(.caption)
        }
        .formStyle(.grouped)
        .confirmationDialog("Deactivate RamClean on this Mac?", isPresented: $confirmDeactivate) {
            Button("Deactivate", role: .destructive) {
                run {
                    let error = await model.deactivateLicence()
                    deactivateFailed = error != nil
                    return error
                }
            }
        } message: {
            Text("Quitting apps, clearing space and learning will need a licence again on this Mac.")
        }
    }

    private func activate() {
        let k = key
        run {
            let error = await model.activateLicence(k)
            if error == nil { key = "" }
            return error
        }
    }

    private func run(_ work: @escaping @MainActor () async -> String?) {
        busy = true
        message = nil
        Task {
            message = await work()
            busy = false
        }
    }
}

struct FeedbackView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "Idea"
    @State private var text = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Feedback").font(.title2.weight(.semibold))
            Picker("", selection: $kind) {
                ForEach(["Idea", "Wrong suggestion", "Bug", "Other"], id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if saved {
                Label("Saved to feedback.jsonl in RamClean's data folder.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
            HStack {
                Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([model.dataDirectory.appendingPathComponent("feedback.jsonl")]) }
                    .buttonStyle(.link)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let entry: [String: String] = [
            "date": ISO8601DateFormatter().string(from: Date()), "kind": kind, "text": text,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = model.dataDirectory.appendingPathComponent("feedback.jsonl")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
        text = ""
        saved = true
    }
}
