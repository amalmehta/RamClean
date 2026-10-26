import Foundation

/// What RamClean has learned about how you use one app.
public struct AppHabit: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var foregroundSecondsByDay: [String: Double] = [:]
    public var launchesByDay: [String: Int] = [:]
    public var lastActive: Date?
    public var firstSeen: Date
    public var timesKept = 0
    public var timesQuitBySuggestion = 0
    /// Times you reopened an app soon after RamClean quit it.
    public var regrets = 0
    /// Your last few answers, oldest first. Nil in habits saved before answers were kept.
    public var answers: [HabitAnswer]?

    public init(key: String, name: String, firstSeen: Date) {
        self.key = key; self.name = name; self.firstSeen = firstSeen
    }
}

public struct HabitStats: Equatable, Sendable {
    public var minutesSinceActive: Double
    public var foregroundMinutesToday: Double
    public var avgDailyMinutes14d: Double
    public var daysUsed14d: Int
    public var launches7d: Int
    public var timesKept: Int
    public var timesQuit: Int
    public var regrets: Int
    /// False until the app has been seen in front at least once since RamClean started watching.
    public var everActive: Bool = true
    public var daysUsed7d: Int = 0
    public var recentAnswers: [HabitAnswer] = []
}

public enum HabitEventKind: String, Codable, Sendable {
    case activated, launched, terminated, suggested, quitBySuggestion, kept, alwaysKept, forceQuit, regretRelaunch, stayedClosed, neverQuit, restarted, diskWarning, movedToTrash, movedOffMac, cleanedUp, thresholdAlert
    /// You reset what RamClean learned about the app: its earlier answers no longer count.
    case forgotten
    /// Undo after Move to Trash: the item went back where it was, so its space wasn't freed after all.
    case putBack
}

public struct HabitEvent: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var kind: HabitEventKind
    public var key: String
    public var name: String
    public var detail: String?
    /// Memory an app was using when you quit it, or disk space a cleanup freed. Nil in events
    /// logged before this was kept.
    public var bytes: UInt64?

    public init(date: Date, kind: HabitEventKind, key: String, name: String, detail: String? = nil, bytes: UInt64? = nil) {
        self.date = date; self.kind = kind; self.key = key; self.name = name; self.detail = detail; self.bytes = bytes
    }
}

/// The habit log. `habits.json` holds per-app daily usage; `events.jsonl` is an
/// append-only diary of launches, switches, suggestions and your answers.
public final class HabitStore {
    public private(set) var habits: [String: AppHabit] = [:]
    public private(set) var recentEvents: [HabitEvent] = []
    /// When RamClean started watching. An app never seen in front counts as idle
    /// since then — not "forever" — so a fresh install doesn't flag everything.
    public private(set) var trackingSince: Date
    public let directory: URL
    private let calendar: Calendar
    private var dirty = false
    private static let keepDays = 60
    private static let maxRecent = 500
    private static let keepAnswers = 10

    private var habitsURL: URL { directory.appendingPathComponent("habits.json") }
    private var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }
    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    public init(directory: URL, calendar: Calendar = .current, now: Date = Date()) {
        self.directory = directory
        self.calendar = calendar
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        trackingSince = now
        if let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
           let meta = try? Self.decoder.decode([String: Date].self, from: data), let since = meta["trackingSince"] {
            trackingSince = since
        } else {
            writeMeta()
        }
        if let data = try? Data(contentsOf: habitsURL),
           let decoded = try? Self.decoder.decode([String: AppHabit].self, from: data) {
            habits = decoded
        }
        loadRecentEvents()
    }

    public func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func touch(_ key: String, _ name: String, _ now: Date) {
        if habits[key] == nil { habits[key] = AppHabit(key: key, name: name, firstSeen: now) }
        if !name.isEmpty { habits[key]!.name = name }
        dirty = true
    }

    public func creditForeground(key: String, name: String, seconds: Double, at now: Date) {
        guard seconds > 0 else { return }
        touch(key, name, now)
        habits[key]!.foregroundSecondsByDay[dayKey(now), default: 0] += seconds
        habits[key]!.lastActive = now
    }

    public func markActive(key: String, name: String, at now: Date) {
        touch(key, name, now)
        habits[key]!.lastActive = now
    }

    public func recordLaunch(key: String, name: String, at now: Date) {
        touch(key, name, now)
        habits[key]!.launchesByDay[dayKey(now), default: 0] += 1
        log(.launched, key: key, name: name, at: now)
    }

    public func recordDecision(_ kind: HabitEventKind, key: String, name: String, detail: String? = nil, bytes: UInt64? = nil, at now: Date) {
        touch(key, name, now)
        var answers = habits[key]!.answers ?? []
        switch kind {
        case .kept, .alwaysKept:
            habits[key]!.timesKept += 1
            answers.append(.kept)
        case .quitBySuggestion:
            habits[key]!.timesQuitBySuggestion += 1
            answers.append(.quit)
        case .regretRelaunch:
            habits[key]!.regrets += 1
            // Reopening it soon after turns that quit into a keep, as it does for the model.
            if answers.last == .quit { answers[answers.count - 1] = .kept } else { answers.append(.kept) }
        default: break
        }
        habits[key]!.answers = Array(answers.suffix(Self.keepAnswers))
        log(kind, key: key, name: name, detail: detail, bytes: bytes, at: now)
    }

    /// Forgets your answers about one app, so it is judged afresh and relearned from new ones.
    /// Its usage history stays: that's what the app is doing, not what you told RamClean.
    public func forget(key: String, name: String, at now: Date) {
        if var h = habits[key] {
            h.answers = []; h.timesKept = 0; h.timesQuitBySuggestion = 0; h.regrets = 0
            habits[key] = h
            dirty = true
        }
        log(.forgotten, key: key, name: habits[key]?.name ?? name, detail: "Learned answers cleared", at: now)
    }

    public func log(_ kind: HabitEventKind, key: String, name: String, detail: String? = nil, bytes: UInt64? = nil, at now: Date) {
        let event = HabitEvent(date: now, kind: kind, key: key, name: name, detail: detail, bytes: bytes)
        recentEvents.append(event)
        if recentEvents.count > Self.maxRecent { recentEvents.removeFirst(recentEvents.count - Self.maxRecent) }
        if var line = try? Self.encoder.encode(event) {
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: eventsURL) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: eventsURL)
            }
        }
    }

    private func writeMeta() {
        if let data = try? Self.encoder.encode(["trackingSince": trackingSince]) { try? data.write(to: metaURL, options: .atomic) }
    }

    public func stats(for key: String, now: Date) -> HabitStats {
        let neverSeen = min(max(0, now.timeIntervalSince(trackingSince) / 60), 20_160)
        guard let h = habits[key] else {
            return HabitStats(minutesSinceActive: neverSeen, foregroundMinutesToday: 0, avgDailyMinutes14d: 0,
                              daysUsed14d: 0, launches7d: 0, timesKept: 0, timesQuit: 0, regrets: 0, everActive: false)
        }
        let days14 = (0..<14).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }.map(dayKey)
        let fg = days14.map { h.foregroundSecondsByDay[$0] ?? 0 }
        let launches = days14.prefix(7).map { h.launchesByDay[$0] ?? 0 }.reduce(0, +)
        let since = h.lastActive.map { max(0, now.timeIntervalSince($0) / 60) } ?? neverSeen
        return HabitStats(
            minutesSinceActive: min(since, 20_160),
            foregroundMinutesToday: fg[0] / 60,
            avgDailyMinutes14d: fg.reduce(0, +) / 60 / 14,
            daysUsed14d: fg.filter { $0 >= 60 }.count,
            launches7d: launches,
            timesKept: h.timesKept, timesQuit: h.timesQuitBySuggestion, regrets: h.regrets,
            everActive: h.lastActive != nil,
            daysUsed7d: fg.prefix(7).filter { $0 >= 60 }.count,
            recentAnswers: h.answers ?? [])
    }

    /// Writes habits.json if anything changed and drops days older than 60.
    public func save(now: Date = Date()) {
        guard dirty else { return }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) {
            let cut = dayKey(cutoff)
            for k in habits.keys {
                habits[k]!.foregroundSecondsByDay = habits[k]!.foregroundSecondsByDay.filter { $0.key >= cut }
                habits[k]!.launchesByDay = habits[k]!.launchesByDay.filter { $0.key >= cut }
            }
        }
        if let data = try? Self.encoder.encode(habits) { try? data.write(to: habitsURL, options: .atomic) }
        dirty = false
    }

    public func clear() {
        habits = [:]; recentEvents = []
        try? FileManager.default.removeItem(at: habitsURL)
        try? FileManager.default.removeItem(at: eventsURL)
        trackingSince = Date()
        writeMeta()
    }

    private func loadRecentEvents() {
        guard let data = try? Data(contentsOf: eventsURL) else { return }
        // Keep the log from growing without bound: rewrite to the newest half past 5 MB.
        var lines = data.split(separator: 0x0A)
        if data.count > 5_000_000 {
            lines = Array(lines.suffix(lines.count / 2))
            try? Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: eventsURL, options: .atomic)
        }
        recentEvents = lines.suffix(Self.maxRecent).compactMap { try? Self.decoder.decode(HabitEvent.self, from: Data($0)) }
    }

    /// Every event still in events.jsonl, oldest first: more than `recentEvents` keeps, for
    /// summaries that look back a week or more. Reads the file, so call off the main thread.
    public static func allEvents(in directory: URL) -> [HabitEvent] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("events.jsonl")) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HabitEvent.self, from: Data($0)) }
    }

    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
