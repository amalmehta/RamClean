import Foundation

/// The numbers the model sees for one app at one moment.
public struct FeatureVector: Codable, Equatable, Sendable {
    public var bundleID: String
    public var memoryMB: Double
    public var cpuPercent: Double
    public var minutesSinceActive: Double
    public var foregroundMinutesToday: Double
    public var avgDailyMinutes14d: Double
    public var daysUsed14d: Double
    public var launches7d: Double
    public var hourOfDay: Double
    public var isWeekend: Double
    public var playingAudio: Double
    public var timesKept: Double
    public var timesQuit: Double

    public static let numericKeys = [
        "memoryMB", "cpuPercent", "minutesSinceActive", "foregroundMinutesToday", "avgDailyMinutes14d",
        "daysUsed14d", "launches7d", "hourOfDay", "isWeekend", "playingAudio", "timesKept", "timesQuit",
    ]

    public var numericValues: [String: Double] {
        [
            "memoryMB": memoryMB, "cpuPercent": cpuPercent, "minutesSinceActive": minutesSinceActive,
            "foregroundMinutesToday": foregroundMinutesToday, "avgDailyMinutes14d": avgDailyMinutes14d,
            "daysUsed14d": daysUsed14d, "launches7d": launches7d, "hourOfDay": hourOfDay, "isWeekend": isWeekend,
            "playingAudio": playingAudio, "timesKept": timesKept, "timesQuit": timesQuit,
        ]
    }

    public static func make(group: AppGroup, stats: HabitStats, cpuAverage: Double, playingAudio: Bool,
                            now: Date, calendar: Calendar = .current) -> FeatureVector {
        FeatureVector(
            bundleID: group.habitKey,
            memoryMB: group.memoryMB,
            cpuPercent: cpuAverage,
            minutesSinceActive: stats.minutesSinceActive,
            foregroundMinutesToday: stats.foregroundMinutesToday,
            avgDailyMinutes14d: stats.avgDailyMinutes14d,
            daysUsed14d: Double(stats.daysUsed14d),
            launches7d: Double(stats.launches7d),
            hourOfDay: Double(calendar.component(.hour, from: now)),
            isWeekend: calendar.isDateInWeekend(now) ? 1 : 0,
            playingAudio: playingAudio ? 1 : 0,
            timesKept: Double(stats.timesKept + stats.regrets),
            timesQuit: Double(stats.timesQuit))
    }
}

/// The rule-of-thumb score used before the model has enough of your answers
/// to train, and blended with it afterwards. 0 = keep, 1 = deadweight.
public enum HeuristicScorer {
    public static func score(_ f: FeatureVector) -> Double {
        func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
        // Idle 15 min → 0, idle 6 h → 1, on a log scale.
        let idle = clamp(log(max(f.minutesSinceActive, 1) / 15) / log(360.0 / 15))
        // Apps you use a lot, or on many days, are worth keeping warm.
        let habit = clamp(f.avgDailyMinutes14d / 60) * 0.6 + clamp(f.daysUsed14d / 10) * 0.4
        var p = 0.15 + 0.8 * idle - 0.45 * habit
        if f.playingAudio > 0 { p -= 0.5 }
        // Your past answers about this app pull the score toward them.
        let answers = f.timesKept + f.timesQuit
        if answers > 0 {
            let quitRate = f.timesQuit / answers
            let weight = 0.5 * clamp(answers / 5)
            p = p * (1 - weight) + quitRate * weight
        }
        return clamp(p, 0.01, 0.99)
    }
}
