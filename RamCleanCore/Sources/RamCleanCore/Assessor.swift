import Foundation

public enum Verdict: Equatable, Sendable {
    case protected(ProtectionReason)
    case deadweight
    case keep
}

/// RamClean's opinion of one app right now.
public struct Assessment: Identifiable, Equatable, Sendable {
    public var group: AppGroup
    public var features: FeatureVector
    public var score: Double
    public var usedModel: Bool
    public var verdict: Verdict
    public var cpuAverage: Double
    /// False when the app hasn't been in front since RamClean started watching.
    public var everActive: Bool = true
    /// Days in the last 7 you had it in front for at least a minute.
    public var daysUsed7d: Int = 0
    /// Your recent answers about it, oldest first.
    public var recentAnswers: [HabitAnswer] = []
    public var id: String { group.id }

    public var isSuggestable: Bool { verdict == .deadweight }
}

/// Turns grouped processes + habits + protections + the model into verdicts.
public struct Assessor {
    public var prefs: Preferences
    public var frontmostKey: String?
    public var selfBundleID: String?
    public var audioPIDs: Set<Int32>
    public var cpuAverages: [String: Double]
    public var now: Date

    public init(prefs: Preferences, frontmostKey: String?, selfBundleID: String?, audioPIDs: Set<Int32>,
                cpuAverages: [String: Double], now: Date) {
        self.prefs = prefs; self.frontmostKey = frontmostKey; self.selfBundleID = selfBundleID
        self.audioPIDs = audioPIDs; self.cpuAverages = cpuAverages; self.now = now
    }

    public func assess(_ groups: [AppGroup], stats: (String) -> HabitStats,
                       score: (FeatureVector) -> (value: Double, usedModel: Bool)) -> [Assessment] {
        groups.map { g in
            let s = stats(g.habitKey)
            let cpu = cpuAverages[g.id] ?? (g.cpuPercent + g.hostedCPUPercent)
            let playing = g.pids.contains(where: audioPIDs.contains)
            let f = FeatureVector.make(group: g, stats: s, cpuAverage: cpu, playingAudio: playing, now: now)
            let ctx = ProtectionContext(prefs: prefs, frontmostKey: frontmostKey, selfBundleID: selfBundleID,
                                        audioPIDs: audioPIDs, cpuAverage: cpu, minutesSinceActive: s.minutesSinceActive,
                                        everActive: s.everActive)
            let reason = ProtectionRules.reason(for: g, ctx)
            // Only apps that could be suggested need the model: a prediction for each of the
            // hundreds of background processes was most of the time spent on every check.
            let (value, usedModel) = reason == nil ? score(f) : (HeuristicScorer.score(f), false)
            let verdict: Verdict = reason.map { .protected($0) } ?? (value >= prefs.deadweightThreshold ? .deadweight : .keep)
            return Assessment(group: g, features: f, score: value, usedModel: usedModel, verdict: verdict, cpuAverage: cpu,
                              everActive: s.everActive, daysUsed7d: s.daysUsed7d, recentAnswers: s.recentAnswers)
        }
    }
}

/// Decides whether to send a notification now, and about which app.
public struct SuggestionPolicy {
    public var prefs: Preferences

    public init(prefs: Preferences) { self.prefs = prefs }

    public func memoryIsTight(_ s: SystemSnapshot) -> Bool {
        s.pressure != .normal || s.memoryUsedFraction * 100 >= prefs.memoryTriggerPercent
    }

    public func pick(from assessments: [Assessment], system: SystemSnapshot, lastNotified: [String: Date],
                     lastAnyNotification: Date?, now: Date) -> Assessment? {
        guard prefs.notificationsEnabled else { return nil }
        if let last = lastAnyNotification, now.timeIntervalSince(last) < prefs.minMinutesBetweenNotifications * 60 { return nil }
        let tight = memoryIsTight(system)
        let candidates = assessments.filter { a in
            guard a.isSuggestable else { return false }
            if let last = lastNotified[a.group.habitKey], now.timeIntervalSince(last) < prefs.cooldownHours * 3600 { return false }
            let bigEnough = tight && a.group.memoryMB >= prefs.minAppMemoryMB
            let cpuHog = a.cpuAverage >= prefs.cpuHogPercent
            return bigEnough || cpuHog
        }
        return candidates.max { $0.group.memoryMB * $0.score < $1.group.memoryMB * $1.score }
    }
}

/// Rolling CPU averages per group, so a single spike doesn't count as "busy".
public struct CPUHistory {
    private var samples: [String: [Double]] = [:]
    public var window: Int

    public init(window: Int = 12) { self.window = window }

    public mutating func record(_ groups: [AppGroup]) -> [String: Double] {
        var seen = Set<String>()
        for g in groups {
            seen.insert(g.id)
            var s = samples[g.id] ?? []
            s.append(g.cpuPercent + g.hostedCPUPercent)
            if s.count > window { s.removeFirst(s.count - window) }
            samples[g.id] = s
        }
        samples = samples.filter { seen.contains($0.key) }
        return samples.mapValues { $0.reduce(0, +) / Double($0.count) }
    }
}
