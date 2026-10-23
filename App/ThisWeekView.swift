import AppKit
import RamCleanCore
import SwiftUI

/// The week so far (or last week): what quitting and cleaning freed, how you answered, and
/// which apps the model has learned to quit or keep, each with a way to make it relearn.
struct ThisWeekView: View {
    @EnvironmentObject var model: AppModel
    @State private var lastWeek = false
    @State private var summary: WeeklySummary?
    @State private var resetting: (key: String, name: String)?

    var body: some View {
        let interval = lastWeek ? WeeklySummary.week(before: Date()) : WeeklySummary.week(containing: Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("Week", selection: $lastWeek) {
                        Text("This week").tag(false)
                        Text("Last week").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Text(Self.range(interval)).font(.callout).foregroundStyle(.secondary)
                }
                if let s = summary {
                    tiles(s)
                    HStack(alignment: .top, spacing: 12) {
                        learnedList("Learned to quit", symbol: "moon.zzz.fill", tint: .orange, apps: s.deadweight,
                                    empty: "No app leans toward quitting yet.")
                        learnedList("Learned to keep", symbol: "hand.thumbsup.fill", tint: .green, apps: s.keepers,
                                    empty: "No app leans toward keeping yet.")
                    }
                    flips(s)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        // Recounted whenever the log gains an event (an answer, a cleanup, a reset).
        .task(id: "\(lastWeek)-\(model.events.last?.id.uuidString ?? "")") {
            summary = await model.weeklySummary(interval)
        }
        .confirmationDialog(resetting.map { "Forget what RamClean learned about \($0.name)?" } ?? "",
                            isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
                            presenting: resetting) { app in
            Button("Reset \(app.name)", role: .destructive) { model.resetApp(key: app.key, name: app.name) }
        } message: { _ in
            Text("Your earlier Quit and Keep answers about it are deleted. It's judged by rules of thumb until your next answers teach the model again.")
        }
    }

    private func tiles(_ s: WeeklySummary) -> some View {
        let answered = s.accepted + s.dismissed
        return HStack(spacing: 12) {
            Tile(title: "Memory freed", value: Self.size(s.memoryFreed, count: s.quits),
                 detail: s.quits == 0 ? "No quits yet" : "\(s.quits) app\(s.quits == 1 ? "" : "s") quit", symbol: "memorychip", tint: .orange)
            Tile(title: "Disk reclaimed", value: Self.size(s.diskReclaimed, count: s.diskItems),
                 detail: s.diskItems == 0 ? "Nothing cleared yet" : "\(s.diskItems) item\(s.diskItems == 1 ? "" : "s") cleared or moved",
                 symbol: "internaldrive", tint: .purple)
            Tile(title: "Suggestions", value: "\(s.accepted) taken · \(s.dismissed) kept",
                 detail: answered == 0 ? "No answers yet"
                    : "\(Int((Double(s.accepted) / Double(answered) * 100).rounded()))% taken"
                    + (s.reopened > 0 ? " · \(s.reopened) reopened soon after" : ""),
                 symbol: "bell", tint: .blue)
        }
    }

    private func learnedList(_ title: String, symbol: String, tint: Color, apps: [LearnedApp], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
            VStack(spacing: 0) {
                if apps.isEmpty {
                    Text(empty).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(apps) { a in
                    row(key: a.key, name: a.name, detail: Self.answers(a))
                    if a.id != apps.last?.id { Divider().opacity(0.5) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func flips(_ s: WeeklySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Changed its mind", systemImage: "arrow.left.arrow.right").font(.headline)
            VStack(spacing: 0) {
                if s.flipped.isEmpty {
                    Text("No app switched between quit and keep \(lastWeek ? "last" : "this") week.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(s.flipped) { f in
                    row(key: f.key, name: f.name, detail: "Was \(Self.word(f.from)), now \(Self.word(f.to))")
                    if f.id != s.flipped.last?.id { Divider().opacity(0.5) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(key: String, name: String, detail: String) -> some View {
        HStack(spacing: 12) {
            AppIcon(path: Self.path(key))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Wrong? Reset this app") { resetting = (key, name) }
                .controlSize(.small)
                .help("Forget your answers about \(name) so the model relearns it")
                .accessibilityLabel("Reset what RamClean learned about \(name)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private static func answers(_ a: LearnedApp) -> String {
        let total = a.quits + a.keeps
        return a.label == .deadweight ? "Quit \(a.quits) of last \(total)" : "Kept \(a.keeps) of last \(total)"
    }

    /// Events logged before sizes were kept add nothing, so a week of only those has no size to show.
    private static func size(_ bytes: UInt64, count: Int) -> String {
        bytes == 0 && count > 0 ? "Not measured" : Format.bytes(bytes)
    }

    private static func word(_ l: RamCleanCore.Label) -> String { l == .deadweight ? "quit" : "keep" }

    /// Habit keys are bundle IDs, or bundle paths for apps without one.
    private static func path(_ key: String) -> String? {
        key.hasPrefix("/") ? key : NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)?.path
    }

    private static func range(_ i: DateInterval) -> String {
        let end = min(Date(), i.end.addingTimeInterval(-1))
        return "\(i.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) – \(end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
    }
}

private struct Tile: View {
    var title: String
    var value: String
    var detail: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(tint)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
