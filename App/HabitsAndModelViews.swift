import RamCleanCore
import SwiftUI

struct HabitsView: View {
    @EnvironmentObject var model: AppModel

    private struct Row: Identifiable {
        var id: String
        var name: String
        var today: Double
        var avg: Double
        var days: Int
        var lastUsed: Double
        var kept: Int
        var quit: Int
        var regrets: Int
    }

    var body: some View {
        let now = Date()
        let rows = model.habits.map { h -> Row in
            let s = model.habitStore.stats(for: h.key, now: now)
            return Row(id: h.key, name: h.name, today: s.foregroundMinutesToday, avg: s.avgDailyMinutes14d, days: s.daysUsed14d,
                       lastUsed: s.minutesSinceActive, kept: s.timesKept, quit: s.timesQuit, regrets: s.regrets)
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("How long each app is in front while you're at the Mac, over the last 14 days. Kept / quit are your answers to RamClean.")
                .font(.callout).foregroundStyle(.secondary).padding([.horizontal, .top], 20).padding(.bottom, 10)
            Table(rows) {
                TableColumn("App", value: \.name)
                TableColumn("Today") { Text(Format.duration(minutes: $0.today)).monospacedDigit() }.width(80)
                TableColumn("Avg / day") { Text("\(Int($0.avg)) min").monospacedDigit() }.width(80)
                TableColumn("Days used (of 14)") { Text("\($0.days)").monospacedDigit() }.width(120)
                TableColumn("Last used") { Text($0.lastUsed >= 20_000 ? "—" : "\(Format.duration(minutes: $0.lastUsed)) ago") }.width(110)
                TableColumn("Kept") { Text("\($0.kept)").monospacedDigit() }.width(45)
                TableColumn("Quit") { Text("\($0.quit)").monospacedDigit() }.width(45)
                TableColumn("Reopened") { Text("\($0.regrets)").monospacedDigit() }.width(70)
            }
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(model.events.reversed()) { e in
            HStack(spacing: 10) {
                Image(systemName: symbol(e.kind)).foregroundStyle(color(e.kind)).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(title(e.kind)) \(e.name)")
                    if let d = e.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(e.date, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.events.isEmpty { ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle", description: Text("Launches, quits, suggestions and your answers appear here.")) }
        }
    }

    private func title(_ k: HabitEventKind) -> String {
        switch k {
        case .activated: return "Switched to"
        case .launched: return "Opened"
        case .terminated: return "Closed"
        case .suggested: return "Suggested quitting"
        case .quitBySuggestion: return "You quit"
        case .kept: return "You kept"
        case .alwaysKept: return "Always keep:"
        case .forceQuit: return "Force quit"
        case .regretRelaunch: return "You reopened"
        case .stayedClosed: return "Stayed closed:"
        case .neverQuit: return "Didn't quit:"
        case .restarted: return "Restarted"
        case .diskWarning: return "Low space:"
        case .movedToTrash: return "Moved to Trash:"
        case .movedOffMac: return "Moved off this Mac:"
        case .thresholdAlert: return "Alert:"
        }
    }
    private func symbol(_ k: HabitEventKind) -> String {
        switch k {
        case .launched: return "arrow.up.forward.app"
        case .terminated: return "xmark.app"
        case .suggested: return "bell"
        case .quitBySuggestion, .forceQuit: return "moon.zzz.fill"
        case .kept, .alwaysKept: return "hand.thumbsup.fill"
        case .regretRelaunch: return "arrow.uturn.backward"
        case .stayedClosed: return "checkmark.circle"
        case .neverQuit: return "xmark.circle"
        case .restarted: return "arrow.clockwise.circle"
        case .activated: return "macwindow"
        case .diskWarning: return "internaldrive"
        case .movedToTrash: return "trash"
        case .movedOffMac: return "externaldrive"
        case .thresholdAlert: return "exclamationmark.triangle"
        }
    }
    private func color(_ k: HabitEventKind) -> Color {
        switch k {
        case .quitBySuggestion, .forceQuit, .suggested: return .orange
        case .kept, .alwaysKept: return .green
        case .regretRelaunch, .diskWarning, .thresholdAlert: return .red
        default: return .secondary
        }
    }
}

struct ModelView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        let s = model.modelStatus
        Form {
            Section("Status") {
                LabeledContent("State") {
                    HStack {
                        if model.isTraining { ProgressView().controlSize(.small) }
                        Text(s.isTrained ? "Trained" : "Learning").foregroundStyle(s.isTrained ? .green : .orange)
                    }
                }
                LabeledContent("Your answers", value: "\(s.examples)  (\(s.deadweightExamples) quit · \(s.keepExamples) kept)")
                LabeledContent("Held-out accuracy", value: s.holdoutAccuracy.map { "\(Int($0 * 100))%" } ?? "Needs 20+ answers")
                LabeledContent("Model's share of the score", value: "\(Int(s.modelWeight * 100))%")
                if let t = s.trainedAt { LabeledContent("Last trained", value: t.formatted(date: .abbreviated, time: .shortened)) }
                Text(s.message).font(.caption).foregroundStyle(.secondary)
            }
            Section("How it learns") {
                Text("""
                Every time you tap **Quit** or **Keep** — in a notification, the menu bar or this window — RamClean saves the app's numbers at that moment with your answer. \
                If you reopen an app within 30 minutes of RamClean quitting it, that answer flips to "keep".

                A Create ML boosted-tree classifier trains on those answers on this Mac (nothing leaves it). Until there are \(DeadweightModel.minExamples)+ answers with at least \(DeadweightModel.minPerClass) of each kind, \
                RamClean uses rules of thumb; after that it blends the two, trusting the model more as answers pile up (up to 85%).

                Protections always win over the score: apps you're using, apps playing audio, terminals running commands (like Claude Code), busy work tools, and anything on your always-keep list are never suggested.
                """).font(.callout)
                Text("Features: " + FeatureVector.numericKeys.joined(separator: ", ") + ", app").font(.caption).foregroundStyle(.secondary)
            }
            Section("Recent answers") {
                if model.model.examples.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(Array(model.model.examples.suffix(15).reversed().enumerated()), id: \.offset) { _, e in
                    HStack {
                        Text(model.habitStore.habits[e.features.bundleID]?.name ?? e.features.bundleID)
                        Spacer()
                        Text("idle \(Format.duration(minutes: e.features.minutesSinceActive)) · \(Int(e.features.memoryMB)) MB").font(.caption).foregroundStyle(.secondary)
                        Text(e.label == .deadweight ? "Quit" : "Kept").foregroundStyle(e.label == .deadweight ? .orange : .green).frame(width: 40)
                    }
                }
            }
            Section {
                HStack {
                    Button("Retrain now") { model.retrain() }.disabled(model.isTraining)
                    Spacer()
                    Button("Reset model…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete every answer and start learning from scratch?", isPresented: $confirmReset) {
            Button("Reset model", role: .destructive) { model.resetModel() }
        }
    }
}
