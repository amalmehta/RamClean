import Foundation

/// Quitting an app yourself (Cmd-Q, the Dock) that you weren't using is a "deadweight"
/// answer you didn't have to tap: these rules decide when one counts.
public enum ManualQuit {
    /// The `TrainingExample.source` of these answers.
    public static let source = "manual quit"
    /// In front at any point in this long before quitting, it was in use: you were done with it, not rid of it.
    public static let inUseWindow: TimeInterval = 60
    /// A stint in front this short, ending in the quit, is you switching to it to press Cmd-Q, not using it.
    public static let switchToQuitGrace: TimeInterval = 10

    /// Protections that say RamClean would never quit the app whatever your habits. The ones
    /// about use (in front, used recently, still learning) are left to `ForegroundLog`.
    public static func isStanding(_ reason: ProtectionReason) -> Bool {
        switch reason {
        case .frontmost, .recentlyUsed, .learning: return false
        case .system, .itself, .alwaysKeep, .busy, .busyWork, .hostsCommandLine, .menuBarUtility, .commandLine, .background: return true
        }
    }

    /// Whether an app that just exited should be learned from as a manual quit.
    /// - Parameters:
    ///   - isRegular: a Dock app (`activationPolicy == .regular`).
    ///   - quitByRamClean: RamClean asked it to quit or restart, or is waiting to force quit it.
    ///   - alwaysKept: on your always-keep list now.
    ///   - verdict: the app's last assessment, or nil when RamClean never assessed it.
    ///   - wasInUse: `ForegroundLog.wasInUse` for it.
    public static func shouldLearn(isRegular: Bool, quitByRamClean: Bool, alwaysKept: Bool,
                                   verdict: Verdict?, wasInUse: Bool) -> Bool {
        guard isRegular, !quitByRamClean, !alwaysKept, !wasInUse, let verdict else { return false }
        if case .protected(let reason) = verdict, isStanding(reason) { return false }
        return true
    }

    /// True when a manual quit of `key` was already learned today. One per app per day, so
    /// quitting the same apps every evening doesn't bury the few "keep" answers you tap.
    public static func learnedToday(_ key: String, in examples: [TrainingExample], now: Date,
                                    calendar: Calendar = .current) -> Bool {
        examples.contains { $0.source == source && $0.features.bundleID == key && calendar.isDate($0.date, inSameDayAs: now) }
    }
}

/// Manual quits learned in the last half hour. Reopening the app that soon means you
/// wanted it after all (restarting it to fix a glitch, say), so the answer flips to "keep",
/// just as it does after RamClean's own quits.
public struct RecentManualQuits: Sendable {
    private var quits: [String: Date] = [:]

    public init() {}

    public mutating func learned(_ key: String, at date: Date) { quits[key] = date }

    /// The app launched: returns when its manual quit was learned if that was within
    /// `KillLabeler.regretWindow`, and stops following it either way.
    public mutating func reopened(_ key: String, at now: Date) -> Date? {
        guard let at = quits.removeValue(forKey: key), now.timeIntervalSince(at) <= KillLabeler.regretWindow else { return nil }
        return at
    }
}

/// When each app was last in front, so a quit can tell whether you were using the app.
public struct ForegroundLog: Sendable {
    public struct Stint: Equatable, Sendable {
        public var start: Date
        public var end: Date?
    }

    /// The last two stints in front per app, most recent last.
    public private(set) var stints: [String: [Stint]] = [:]
    private var current: String?

    public init() {}

    /// `key` came to the front, sending whatever was there to the back.
    public mutating func activated(_ key: String, at now: Date) {
        guard key != current else { return }
        if let c = current, var list = stints[c], list.last?.end == nil {
            list[list.count - 1].end = now
            stints[c] = list
        }
        current = key
        stints[key, default: []].append(Stint(start: now, end: nil))
        if stints[key]!.count > 2 { stints[key]!.removeFirst() }
    }

    /// True when `key` was in front within `ManualQuit.inUseWindow` of `now`, not counting a
    /// short last stint that only switched to it to quit it. macOS brings the next app forward
    /// as one quits, sometimes before the quit is reported, so a stint's end is no sign of use.
    public func wasInUse(_ key: String, at now: Date) -> Bool {
        var list = stints[key] ?? []
        if let last = list.last, (last.end ?? now).timeIntervalSince(last.start) < ManualQuit.switchToQuitGrace,
           now.timeIntervalSince(last.end ?? now) < ManualQuit.switchToQuitGrace {
            list.removeLast()
        }
        return list.contains { now.timeIntervalSince($0.end ?? now) < ManualQuit.inUseWindow }
    }

    /// The app exited: stop following it.
    public mutating func forget(_ key: String) {
        stints[key] = nil
        if current == key { current = nil }
    }
}
