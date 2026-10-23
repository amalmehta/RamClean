import Foundation

/// An app and what your answers about it have taught RamClean.
public struct LearnedApp: Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var label: Label
    /// Among its last few answers (the ones the model and the "why" use).
    public var quits: Int
    public var keeps: Int
    public var id: String { key }
}

/// An app RamClean treated one way at the start of the week and the other way at the end.
public struct LabelFlip: Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var from: Label
    public var to: Label
    public var id: String { key }
}

/// A week of the habit log, added up: what quitting and cleaning freed, how you answered,
/// and what the model has learned from it.
public struct WeeklySummary: Equatable, Sendable {
    public var interval: DateInterval
    /// Memory the apps were using when you quit them. Quits that never happened don't count.
    public var memoryFreed: UInt64 = 0
    public var quits = 0
    /// Space freed by moving to the Trash, cleanup commands and moving files off the Mac.
    public var diskReclaimed: UInt64 = 0
    public var diskItems = 0
    /// Quit answers (suggestion or a Quit button) vs. Keep and Always keep answers.
    public var accepted = 0
    public var dismissed = 0
    /// Apps reopened soon after RamClean quit them.
    public var reopened = 0
    /// The apps it most clearly treats as deadweight, and as worth keeping, at the end of the week.
    public var deadweight: [LearnedApp] = []
    public var keepers: [LearnedApp] = []
    public var flipped: [LabelFlip] = []

    public static let topCount = 5

    public init(interval: DateInterval) { self.interval = interval }

    /// Nothing happened worth telling you about.
    public var isEmpty: Bool {
        quits == 0 && diskItems == 0 && accepted == 0 && dismissed == 0 && flipped.isEmpty
    }

    /// Adds up `events` (the whole habit log, oldest first) for the week in `interval`.
    /// What the model has learned depends on every answer up to a point, so earlier events
    /// matter too; only the counts are limited to the week.
    public static func make(events: [HabitEvent], interval: DateInterval) -> WeeklySummary {
        var s = WeeklySummary(interval: interval)
        let inWeek = { (e: HabitEvent) in e.date >= interval.start && e.date < interval.end }

        for (i, e) in events.enumerated() where inWeek(e) {
            switch e.kind {
            case .quitBySuggestion:
                s.accepted += 1
                if !neverQuit(events, after: i) {
                    s.quits += 1
                    s.memoryFreed += e.bytes ?? 0
                }
            case .kept, .alwaysKept: s.dismissed += 1
            case .regretRelaunch: s.reopened += 1
            case .movedToTrash, .cleanedUp, .movedOffMac:
                s.diskItems += 1
                s.diskReclaimed += e.bytes ?? 0
            default: break
            }
        }

        let before = learned(events.filter { $0.date < interval.start })
        let after = learned(events.filter { $0.date < interval.end })
        let ranked = after.values.sorted { a, b in
            let (ma, mb) = (abs(a.quits - a.keeps), abs(b.quits - b.keeps))
            if ma != mb { return ma > mb }
            if a.quits + a.keeps != b.quits + b.keeps { return a.quits + a.keeps > b.quits + b.keeps }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        s.deadweight = Array(ranked.filter { $0.label == .deadweight }.prefix(topCount))
        s.keepers = Array(ranked.filter { $0.label == .keep }.prefix(topCount))
        s.flipped = after.values.compactMap { now -> LabelFlip? in
            guard let was = before[now.key], was.label != now.label else { return nil }
            return LabelFlip(key: now.key, name: now.name, from: was.label, to: now.label)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return s
    }

    /// Replays your answers the way the habit store and the model take them: a quick reopen
    /// turns the last quit into a keep, a quit that never happened is taken back, a reset
    /// forgets them all, and only the last few count. An app leans the way most of them go;
    /// a tie goes to the latest.
    static func learned(_ events: [HabitEvent]) -> [String: LearnedApp] {
        var answers: [String: [HabitAnswer]] = [:]
        var names: [String: String] = [:]
        for e in events {
            var a = answers[e.key] ?? []
            switch e.kind {
            case .kept, .alwaysKept: a.append(.kept)
            case .quitBySuggestion: a.append(.quit)
            case .regretRelaunch:
                if a.last == .quit { a[a.count - 1] = .kept } else { a.append(.kept) }
            case .neverQuit:
                if a.last == .quit { a.removeLast() }
            case .forgotten: a = []
            default: continue
            }
            answers[e.key] = Array(a.suffix(keepAnswers))
            names[e.key] = e.name
        }
        var out: [String: LearnedApp] = [:]
        for (key, a) in answers {
            guard let last = a.last else { continue }
            let quits = a.filter { $0 == .quit }.count, keeps = a.count - quits
            let label: Label = quits == keeps ? (last == .quit ? .deadweight : .keep) : (quits > keeps ? .deadweight : .keep)
            out[key] = LearnedApp(key: key, name: names[key] ?? key, label: label, quits: quits, keeps: keeps)
        }
        return out
    }

    /// Matches HabitStore's own limit on remembered answers.
    static let keepAnswers = 10

    /// True when the quit at `index` was followed by "didn't quit" before it was otherwise settled.
    private static func neverQuit(_ events: [HabitEvent], after index: Int) -> Bool {
        let key = events[index].key
        for e in events[(index + 1)...] where e.key == key {
            switch e.kind {
            case .neverQuit: return true
            case .stayedClosed, .regretRelaunch, .quitBySuggestion: return false
            default: continue
            }
        }
        return false
    }

    // MARK: - Weeks and the Monday notification

    /// The Monday-to-Monday week that `date` falls in.
    public static func week(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        var cal = calendar
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }

    /// The week before the one `date` falls in.
    public static func week(before date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = week(containing: date, calendar: calendar).start
        return week(containing: start.addingTimeInterval(-1), calendar: calendar)
    }

    /// Hour on Monday morning when last week's summary goes out.
    public static let notificationHour = 9

    /// Whether last week's summary is due: it's Monday 9:00 or later this week, and none has
    /// gone out since. A Mac asleep on Monday morning gets it at its next check that week.
    public static func notificationDue(now: Date, lastSent: Date, calendar: Calendar = .current) -> Bool {
        let monday = week(containing: now, calendar: calendar).start
        guard let sendAt = calendar.date(byAdding: .hour, value: notificationHour, to: monday) else { return false }
        return now >= sendAt && lastSent < sendAt
    }

    /// Title and body of the Monday notification.
    public var notificationText: (title: String, body: String) {
        var parts: [String] = []
        if quits > 0 { parts.append("Freed \(Self.bytes(memoryFreed)) of memory over \(quits) quit\(quits == 1 ? "" : "s")") }
        if diskItems > 0 { parts.append("\(parts.isEmpty ? "Reclaimed" : "reclaimed") \(Self.bytes(diskReclaimed)) of disk") }
        var sentences = parts.isEmpty ? [] : [parts.joined(separator: " and ") + "."]
        let answered = accepted + dismissed
        if answered > 0 { sentences.append("You took \(accepted) of \(answered) suggestion\(answered == 1 ? "" : "s").") }
        if let f = flipped.first {
            sentences.append("Changed its mind about \(f.name)" + (flipped.count > 1 ? " and \(flipped.count - 1) more." : "."))
        }
        return ("Your week with RamClean", sentences.joined(separator: " "))
    }

    public static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }
}
