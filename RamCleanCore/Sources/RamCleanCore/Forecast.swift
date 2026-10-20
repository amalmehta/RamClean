import Foundation

/// Free disk space over the last two weeks, so RamClean can warn days before the disk fills
/// rather than only once it's nearly full. Saved to `disk-history.json`.
public struct DiskHistory: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public var date: Date
        public var free: Int64
    }

    public private(set) var samples: [Sample] = []
    /// One sample per this long is plenty for a trend measured in days.
    static let spacing: TimeInterval = 30 * 60
    static let keep: TimeInterval = 14 * 86_400
    /// The trend uses this much recent history...
    static let trendWindow: TimeInterval = 3 * 86_400
    /// ...and needs at least this much of it before it says anything.
    static let minimumSpan: TimeInterval = 12 * 3600
    /// Losing less than this a day is noise (logs, caches settling), not a trend.
    static let minimumLossPerDay: Double = 250 * 1_048_576

    public init() {}

    public init(contentsOf url: URL) {
        if let data = try? Data(contentsOf: url), let saved = try? HabitStore.decoder.decode(DiskHistory.self, from: data) { self = saved }
    }

    /// Adds a sample if the last one is at least `spacing` old. Returns true when it did.
    @discardableResult
    public mutating func record(free: Int64, at now: Date) -> Bool {
        if let last = samples.last, now.timeIntervalSince(last.date) < Self.spacing { return false }
        samples.append(Sample(date: now, free: free))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.keep }
        return true
    }

    /// How fast free space is shrinking, in bytes a day, from a least-squares line through
    /// the last three days. Nil when there's too little history or space isn't shrinking.
    public func lossPerDay(now: Date) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.date) <= Self.trendWindow }
        guard let first = recent.first, let last = recent.last,
              last.date.timeIntervalSince(first.date) >= Self.minimumSpan else { return nil }
        let xs = recent.map { $0.date.timeIntervalSince(first.date) / 86_400 }, ys = recent.map { Double($0.free) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        return -slope >= Self.minimumLossPerDay ? -slope : nil
    }

    /// Days until free space falls to `floor` bytes at the current rate, or nil when it isn't
    /// shrinking (or is already below the floor, which the threshold alert covers).
    public func daysUntil(free floor: Int64, now: Date) -> Double? {
        guard let loss = lossPerDay(now: now), let current = samples.last?.free, current > floor else { return nil }
        return Double(current - floor) / loss
    }

    public func save(to url: URL) {
        if let data = try? HabitStore.encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// Apps whose memory has swelled since they started: a browser after a long session, or an
/// app that leaks. Restarting one frees the growth without giving the app up.
public struct MemoryGrowth: Sendable {
    public struct Growth: Equatable, Sendable {
        /// The smallest the app has been since RamClean saw it start (or first saw it).
        public var from: UInt64
        public var to: UInt64
        public var since: Date
        public var freed: UInt64 { to > from ? to - from : 0 }
    }

    private struct Low { var pid: Int32?; var bytes: UInt64; var at: Date; var firstSeen: Date }
    private var lows: [String: Low] = [:]
    /// Grown by at least this much...
    static let minimumGrowth: UInt64 = 1 << 30
    /// ...and to at least this many times its low point...
    static let minimumRatio: Double = 2
    /// ...after being watched at least this long, so a freshly opened app settling isn't "growth".
    static let minimumWatch: TimeInterval = 30 * 60

    public init() {}

    /// Updates each Dock app's low point. A new main process means the app restarted, so its
    /// low point starts over; apps that are gone are forgotten.
    public mutating func record(_ groups: [AppGroup], now: Date) {
        var seen = Set<String>()
        for g in groups where g.kind == .app {
            let key = g.habitKey
            seen.insert(key)
            if var low = lows[key], low.pid == g.mainPID {
                if g.memoryBytes < low.bytes { low.bytes = g.memoryBytes; low.at = now }
                lows[key] = low
            } else {
                lows[key] = Low(pid: g.mainPID, bytes: g.memoryBytes, at: now, firstSeen: now)
            }
        }
        lows = lows.filter { seen.contains($0.key) }
    }

    public func growth(of g: AppGroup, now: Date) -> Growth? {
        guard g.kind == .app, let low = lows[g.habitKey], low.pid == g.mainPID,
              now.timeIntervalSince(low.firstSeen) >= Self.minimumWatch,
              g.memoryBytes >= low.bytes + Self.minimumGrowth,
              Double(g.memoryBytes) >= Double(max(low.bytes, 1)) * Self.minimumRatio else { return nil }
        return Growth(from: low.bytes, to: g.memoryBytes, since: low.at)
    }
}
