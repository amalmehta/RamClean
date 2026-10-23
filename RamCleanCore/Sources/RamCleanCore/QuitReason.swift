import Foundation

/// How you answered RamClean about an app: quit it, or kept it running.
public enum HabitAnswer: String, Codable, Equatable, Sendable { case quit, kept }

/// The one-sentence "why" on every quit suggestion, shared by the notification body and the
/// main window row: "Idle 3 days, 2.1 GB, you quit it the last 4 times."
public enum QuitReason {
    /// Longer than this wraps past two lines of a notification, so the least telling parts go.
    public static let maxLength = 80

    /// `growth` is the app's memory swell since it started, if it has one.
    public static func text(for a: Assessment, growth: MemoryGrowth.Growth? = nil, now: Date = Date()) -> String {
        let f = a.features
        var parts: [String] = []
        if !a.everActive {
            parts.append("Not used since RamClean started")
        } else if f.minutesSinceActive < 1 {
            parts.append("In use")
        } else {
            parts.append("Idle \(HumanFormat.duration(minutes: f.minutesSinceActive))")
        }
        var memory = HumanFormat.bytes(a.group.memoryBytes)
        if let g = growth, g.freed > 0 {
            let minutes = now.timeIntervalSince(g.since) / 60
            memory += " (up \(HumanFormat.bytes(g.freed))" + (minutes >= 1 ? " in \(HumanFormat.duration(minutes: minutes)))" : ")")
        }
        if a.cpuAverage >= 10 { memory += ", \(Int(a.cpuAverage.rounded()))% CPU" }
        parts.append(memory)
        if let answers = answers(a.recentAnswers) { parts.append(answers) }
        if let use = weeklyUse(a) { parts.append(use) }
        var text = sentence(parts)
        while parts.count > 2, text.count > maxLength {
            parts.removeLast()
            text = sentence(parts)
        }
        return text
    }

    /// "you quit it the last 4 times": the run of matching answers at the end.
    static func answers(_ history: [HabitAnswer]) -> String? {
        guard let last = history.last else { return nil }
        let run = history.reversed().prefix { $0 == last }.count
        let verb = last == .quit ? "quit" : "kept"
        return run == 1 ? "you \(verb) it last time" : "you \(verb) it the last \(run) times"
    }

    /// How many of the last 7 days you used it, unless the idle time already says it.
    static func weeklyUse(_ a: Assessment) -> String? {
        if !a.everActive { return a.recentAnswers.isEmpty ? "no history yet" : nil }
        if a.features.minutesSinceActive >= 7 * 1440 { return nil }
        switch a.daysUsed7d {
        case 0: return "barely used this week"
        case 7...: return "used every day this week"
        case let n: return "used \(n) of the last 7 days"
        }
    }

    private static func sentence(_ parts: [String]) -> String { parts.joined(separator: ", ") + "." }
}
