import Foundation

/// Why an automatic clean is running now.
public enum AutoCleanTrigger: String, Codable, Sendable {
    /// The regular run, every `autoCleanHours`.
    case scheduled
    /// Memory reached the suggest line (or macOS reports pressure) between runs.
    case memoryTight
    /// Free space is on course to reach the disk alert line within `AutoCleanPolicy.forecastDays`.
    case diskForecast
}

/// What one automatic clean should do.
public struct AutoCleanPlan: Equatable, Sendable {
    public var quitApps: Bool
    public var clearBuildFolders: Bool
    public var trigger: AutoCleanTrigger
}

/// When the last automatic cleans ran, per half, so an early memory clean doesn't hold
/// back the disk half or the other way round. Saved by the app between launches.
public struct AutoCleanClock: Codable, Equatable, Sendable {
    public var lastScheduled: Date?
    public var lastApps: Date?
    public var lastDisk: Date?

    public init(lastScheduled: Date? = nil, lastApps: Date? = nil, lastDisk: Date? = nil) {
        self.lastScheduled = lastScheduled; self.lastApps = lastApps; self.lastDisk = lastDisk
    }

    public mutating func ran(_ plan: AutoCleanPlan, at now: Date) {
        if plan.trigger == .scheduled { lastScheduled = now }
        if plan.quitApps { lastApps = now }
        if plan.clearBuildFolders { lastDisk = now }
    }
}

/// Decides when RamClean cleans up by itself and what it may touch. It only ever picks
/// things it would already suggest, with stricter rules, because nobody is asked first:
/// apps marked deadweight that you haven't had in front for a while, and the build folders
/// of projects you stopped working on (rebuildable, and moved to the Trash, not deleted).
public struct AutoCleanPolicy {
    public var prefs: Preferences

    /// An early clean (memory or disk forecast) waits at least this long after the last one
    /// of its half, so a Mac that stays tight isn't cleaned over and over.
    public static let earlyGap: TimeInterval = 3600
    /// The disk half runs early when the forecast says the alert line is this close.
    public static let forecastDays = 3.0

    public init(prefs: Preferences) { self.prefs = prefs }

    /// What to do now, or nil. A scheduled run does both halves; between runs, tight memory
    /// brings the app half forward and a disk forecast brings the disk half forward.
    public func due(clock: AutoCleanClock, system: SystemSnapshot, diskFullInDays: Double?, now: Date) -> AutoCleanPlan? {
        guard prefs.autoCleanEnabled else { return nil }
        let every = max(1, prefs.autoCleanHours) * 3600
        if clock.lastScheduled.map({ now.timeIntervalSince($0) >= every }) ?? true {
            return AutoCleanPlan(quitApps: true, clearBuildFolders: true, trigger: .scheduled)
        }
        func rested(_ last: Date?) -> Bool { last.map { now.timeIntervalSince($0) >= Self.earlyGap } ?? true }
        if SuggestionPolicy(prefs: prefs).memoryIsTight(system), rested(clock.lastApps) {
            return AutoCleanPlan(quitApps: true, clearBuildFolders: false, trigger: .memoryTight)
        }
        if let days = diskFullInDays, days <= Self.forecastDays, rested(clock.lastDisk) {
            return AutoCleanPlan(quitApps: false, clearBuildFolders: true, trigger: .diskForecast)
        }
        return nil
    }

    /// Apps it may quit with nobody asked: Dock apps judged deadweight (which already rules out
    /// every protected app: in front, playing audio, building, hosting Claude, always keep, used
    /// recently), not in front for `autoCleanIdleMinutes`, and big enough to be worth it.
    /// The app checks for unsaved changes just before quitting, since that needs Accessibility.
    public func appsToQuit(_ assessments: [Assessment]) -> [Assessment] {
        assessments.filter { a in
            a.group.kind == .app && a.verdict == .deadweight
                && a.features.minutesSinceActive >= prefs.autoCleanIdleMinutes
                && a.group.memoryMB >= prefs.minAppMemoryMB
        }
        .sorted { $0.group.memoryBytes > $1.group.memoryBytes }
    }

    /// Build and dependency folders of projects untouched for `activeDays`, with no caution:
    /// the same ones "Select All Safe" ticks in that section. They come back with a build or
    /// an install, and go to the Trash, so nothing is lost. Each folder is looked at again
    /// right before: one that's gone, or was written to within `activeDays` (a build started
    /// since the scan), is left alone.
    public func foldersToTrash(_ report: DiskReport, now: Date) -> [DiskItem] {
        report.safeToClear.filter { item in
            guard item.kind == .buildArtifact,
                  let values = try? URL(fileURLWithPath: item.path).resourceValues(forKeys: [.contentModificationDateKey]),
                  let written = values.contentModificationDate else { return false }
            return now.timeIntervalSince(written) >= prefs.activeDays * 86_400
        }
    }
}

/// The one notification after an automatic clean.
public enum AutoCleanSummary {
    /// Nil when nothing was done, so a run that found nothing stays quiet.
    public static func text(quit: [(name: String, bytes: UInt64)], trashed: [DiskItem],
                            trigger: AutoCleanTrigger) -> (title: String, body: String)? {
        guard !quit.isEmpty || !trashed.isEmpty else { return nil }
        let memory = quit.reduce(UInt64(0)) { $0 + $1.bytes }
        let disk = trashed.reduce(Int64(0)) { $0 + max(0, $1.bytes ?? 0) }
        var freed: [String] = []
        if memory > 0 { freed.append("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: memory), countStyle: .memory)) of memory") }
        if disk > 0 { freed.append("\(HumanFormat.bytes(UInt64(disk))) of disk") }
        let title = freed.isEmpty ? "Cleaned up" : "Freed " + freed.joined(separator: " and ")
        var parts: [String] = []
        if !quit.isEmpty { parts.append("Quit " + list(quit.map(\.name)) + " (idle, marked deadweight)") }
        if !trashed.isEmpty {
            let n = trashed.count
            parts.append("moved \(n) old project build folder\(n == 1 ? "" : "s") to the Trash")
        }
        var body = parts.joined(separator: "; ")
        body = body.prefix(1).uppercased() + body.dropFirst() + "."
        switch trigger {
        case .scheduled: break
        case .memoryTight: body = "Memory was getting tight. " + body
        case .diskForecast: body = "The disk was on course to fill. " + body
        }
        return (title, body)
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}
