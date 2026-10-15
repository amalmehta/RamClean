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
            Divider()
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
