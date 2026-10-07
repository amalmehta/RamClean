import RamCleanCore
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview", habits = "Habits", activity = "Activity Log", model = "Model"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .habits: return "chart.bar.xaxis"
        case .activity: return "list.bullet.rectangle"
        case .model: return "brain"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: SidebarItem = .overview
    @State private var showFeedback = false

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
            .safeAreaInset(edge: .bottom) {
                // Small, out-of-the-way feedback tab.
                Button { showFeedback = true } label: {
                    Label("Feedback", systemImage: "bubble.left").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            Group {
                switch section {
                case .overview: OverviewView()
                case .habits: HabitsView()
                case .activity: ActivityView()
                case .model: ModelView()
                }
            }
            .navigationTitle(section.rawValue)
            .toolbar {
                ToolbarItemGroup {
                    Button { StableOrder.overview.invalidate(); model.tick() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Check now")
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .help("Settings (⌘,)")
                }
            }
        }
        .sheet(isPresented: $showFeedback) { FeedbackView() }
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var showOthers = false
    @State private var order = StableOrder.overview

    var body: some View {
        let apps = order.arrange(model.assessments.filter { $0.group.kind == .app })
        let others = model.assessments.filter { $0.group.kind != .app }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                gauges
                summary(apps)
                VStack(spacing: 0) {
                    ForEach(apps) { a in
                        AppRow(assessment: a)
                        Divider().opacity(0.5)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                // Rows don't reshuffle under the pointer, so a click always hits the app you aimed at.
                .onHover { order.frozen = $0 }

                DisclosureGroup(isExpanded: $showOthers) {
                    VStack(spacing: 0) {
                        ForEach(others.prefix(40)) { a in
                            AppRow(assessment: a)
                            Divider().opacity(0.5)
                        }
                    }
                } label: {
                    Text("Menu bar apps, command-line tools and background processes (\(others.count)) — shown, not suggested")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private var gauges: some View {
        if let s = model.system {
            HStack(spacing: 12) {
                UsageBar(title: "Memory", value: s.memoryUsedFraction,
                         detail: "\(Format.bytes(s.usedMemory)) of \(Format.bytes(s.totalMemory)) · pressure \(s.pressure.label) · swap \(Format.bytes(s.swapUsed))",
                         tint: memoryTint(s))
                UsageBar(title: "CPU", value: s.cpuPercent / 100, detail: "All cores", tint: .blue)
                UsageBar(title: "Disk used", value: 1 - s.diskFreeFraction,
                         detail: "\(Format.bytes(UInt64(max(0, s.diskFree)))) free of \(Format.bytes(UInt64(max(0, s.diskTotal))))",
                         tint: s.diskFreeFraction * 100 < model.prefs.diskWarningPercent ? .red : .purple)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func summary(_ apps: [Assessment]) -> some View {
        let dead = apps.filter(\.isSuggestable)
        let reclaim = dead.reduce(UInt64(0)) { $0 + $1.group.memoryBytes }
        return HStack {
            Image(systemName: dead.isEmpty ? "checkmark.seal.fill" : "moon.zzz.fill")
                .foregroundStyle(dead.isEmpty ? .green : .orange)
            if dead.isEmpty {
                Text("Nothing looks like deadweight right now.")
            } else {
                Text("\(dead.count) app\(dead.count == 1 ? "" : "s") look\(dead.count == 1 ? "s" : "") like deadweight — quitting would free about \(Format.bytes(reclaim)).")
            }
            Spacer()
            Text(model.modelStatus.isTrained ? "Model: trained on \(model.modelStatus.examples) answers" : "Model: learning (\(model.modelStatus.examples) answers so far)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct AppRow: View {
    @EnvironmentObject var model: AppModel
    var assessment: Assessment

    var body: some View {
        let g = assessment.group
        HStack(spacing: 12) {
            AppIcon(path: g.bundlePath)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(Format.bytes(g.memoryBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text("\(Int(assessment.cpuAverage.rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            VerdictBadge(assessment: assessment).frame(width: 230, alignment: .leading)
            actions.frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var subtitle: String {
        let f = assessment.features
        if assessment.group.kind == .commandLine || assessment.group.kind == .background {
            return "\(assessment.group.pids.count) process\(assessment.group.pids.count == 1 ? "" : "es")"
        }
        var parts = [assessment.everActive
            ? "last used \(Format.duration(minutes: f.minutesSinceActive)) ago"
            : "not used since RamClean started watching"]
        if f.avgDailyMinutes14d >= 1 { parts.append("\(Int(f.avgDailyMinutes14d)) min/day") }
        if assessment.group.pids.count > 1 { parts.append("\(assessment.group.pids.count) processes") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        let key = assessment.group.habitKey
        if case .protected = assessment.verdict {
            Color.clear.frame(height: 1)
        } else if model.awaitingForceQuit.contains(key) {
            Button("Force Quit", role: .destructive) { model.forceQuit(key: key) }.controlSize(.small)
                .accessibilityLabel("Force Quit \(assessment.group.name)")
        } else {
            HStack(spacing: 6) {
                Button("Quit") { model.quit(key: key, source: "window") }
                    .controlSize(.small)
                    .accessibilityLabel("Quit \(assessment.group.name)")
                    .help("Quit \(assessment.group.name) and teach RamClean it was deadweight")
                Button { model.keep(key: key, always: false, source: "window") } label: { Image(systemName: "hand.thumbsup") }
                    .controlSize(.small)
                    .accessibilityLabel("Keep \(assessment.group.name)")
                    .help("Keep it — teaches RamClean this app is worth keeping")
            }
        }
    }
}

/// Keeps row order steady so a click always lands on the app you aimed at: rows
/// re-sort by memory at most once a minute, never while the pointer is over the
/// list, and right away when you press Refresh. New apps go to the end until then.
/// A class, so updating it during a render doesn't trigger another render.
final class StableOrder {
    static let overview = StableOrder()
    var frozen = false
    private var ids: [String] = []
    private var sortedAt = Date.distantPast

    func invalidate() { sortedAt = .distantPast }

    func arrange(_ items: [Assessment], now: Date = Date()) -> [Assessment] {
        if !frozen, ids.isEmpty || now.timeIntervalSince(sortedAt) >= 60 {
            ids = items.map(\.id)
            sortedAt = now
            return items
        }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }
}
