import RamCleanCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let apps = model.assessments.filter { $0.group.kind == .app }
        let dead = apps.filter(\.isSuggestable)
        VStack(alignment: .leading, spacing: 12) {
            if let s = model.system {
                UsageBar(title: "Memory", value: s.memoryUsedFraction,
                         detail: "\(Format.bytes(s.usedMemory)) of \(Format.bytes(s.totalMemory)) · pressure \(s.pressure.label)",
                         tint: memoryTint(s))
                // Disk only earns a line here when it needs attention: filling within a week, or near its alert line.
                let used = (1 - s.diskFreeFraction) * 100
                if (model.diskFullInDays ?? .infinity) <= 7 || used >= model.prefs.diskAlertUsedPercent - 5 {
                    UsageBar(title: "Disk", value: 1 - s.diskFreeFraction,
                             detail: "\(Format.bytes(UInt64(max(0, s.diskFree)))) free"
                                + (model.diskFullInDays.map { " · full in ~\(max(1, Int($0.rounded()))) days at this rate" } ?? ""),
                             tint: .red)
                }
            }
            let swollen = apps.filter { model.grown[$0.group.habitKey] != nil && !model.quitting.contains($0.group.habitKey) }
                .sorted { model.grown[$0.group.habitKey]!.freed > model.grown[$1.group.habitKey]!.freed }
            if !swollen.isEmpty {
                Text("Restart to free memory").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(swollen.prefix(3)) { a in
                    let g = model.grown[a.group.habitKey]!
                    HStack(spacing: 8) {
                        AppIcon(path: a.group.bundlePath, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.group.name).lineLimit(1)
                            Text(GrowthText.short(g)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        RestartButton(name: a.group.name, key: a.group.habitKey, growth: g)
                    }
                }
            }
            Text(dead.isEmpty ? "Biggest apps" : "Looks like deadweight").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach((dead.isEmpty ? Array(apps.prefix(5)) : Array(dead.prefix(5)))) { a in
                HStack(spacing: 8) {
                    AppIcon(path: a.group.bundlePath, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.group.name).lineLimit(1)
                        Text(caption(a)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Format.bytes(a.group.memoryBytes)).font(.caption).monospacedDigit()
                    if model.quitting.contains(a.group.habitKey) {
                        QuittingLabel()
                    } else if a.isSuggestable {
                        Button("Quit") { model.quit(key: a.group.habitKey, source: "menu bar") }.controlSize(.small)
                            .accessibilityLabel("Quit \(a.group.name)")
                    }
                }
            }
            let waiting = dead.filter { !model.quitting.contains($0.group.habitKey) }
            if waiting.count >= 2 {
                let total = waiting.reduce(UInt64(0)) { $0 + $1.group.memoryBytes }
                Button("Quit all \(waiting.count) · frees about \(Format.bytes(total))") { model.quitAll(waiting) }
                .controlSize(.small)
                .help("Quits every app RamClean thinks is deadweight, including any not shown above")
            }
            Divider()
            if let until = model.pausedUntil, model.notificationsPaused {
                Button("Resume notifications (paused until \(until.formatted(date: .omitted, time: .shortened)))") { model.resumeNotifications() }
                    .buttonStyle(.borderless)
            } else {
                Button("Pause notifications for 1 hour") { model.pauseNotifications(for: 3600) }
                    .buttonStyle(.borderless)
                    .help("Hold suggestions and alerts, say during a call or a presentation")
            }
            HStack {
                Button("Open RamClean") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit RamClean")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func caption(_ a: Assessment) -> String {
        switch a.verdict {
        case .protected(let r): return r.text
        case .deadweight: return "Idle \(Format.duration(minutes: a.features.minutesSinceActive)) · deadweight \(Int(a.score * 100))%"
        case .keep: return "Keep · score \(Int(a.score * 100))%"
        }
    }
}
