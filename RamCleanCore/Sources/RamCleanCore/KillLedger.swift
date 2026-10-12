import Foundation

/// How a kill turned out once its 30-minute window closed (or you reopened the app sooner).
public enum KillOutcome: String, Codable, Sendable {
    /// You reopened it within the window: the kill was a mistake.
    case relaunched
    /// It stayed closed for the whole window: the kill was right.
    case stayedClosed
    /// It never actually quit (you cancelled its save dialog, or it hung and you didn't force it).
    case neverQuit
}

/// One app RamClean quit for you, followed until we know whether you wanted it back.
public struct KillRecord: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    /// When you accepted the recommendation.
    public var killedAt: Date
    public var source: String
    public var memoryBytes: UInt64?
    /// When the app actually exited; nil while it's still shutting down (or refused to).
    public var terminatedAt: Date?
    public var forced = false

    public init(key: String, name: String, killedAt: Date, source: String, memoryBytes: UInt64? = nil) {
        self.key = key; self.name = name; self.killedAt = killedAt; self.source = source; self.memoryBytes = memoryBytes
    }
}

/// Turns what happened after a kill into a training label for the deadweight model.
public enum KillLabeler {
    /// Reopening an app within this long of RamClean quitting it means the quit was wrong.
    public static let regretWindow: TimeInterval = 30 * 60

    /// The outcome once it is known, or nil while the window is still open.
    /// `relaunchedAt` is the first launch of the app after the kill, if any.
    public static func outcome(_ r: KillRecord, relaunchedAt: Date?, now: Date) -> KillOutcome? {
        let deadline = r.killedAt.addingTimeInterval(regretWindow)
        if let at = relaunchedAt, at >= r.killedAt, at < deadline, r.terminatedAt != nil { return .relaunched }
        guard now >= deadline else { return nil }
        return r.terminatedAt == nil ? .neverQuit : .stayedClosed
    }

    /// A quick relaunch is a negative example (keep); staying closed confirms deadweight.
    /// A quit that never happened teaches nothing.
    public static func label(for outcome: KillOutcome) -> Label? {
        switch outcome {
        case .relaunched: return .keep
        case .stayedClosed: return .deadweight
        case .neverQuit: return nil
        }
    }
}

/// Kills still inside their regret window, saved to `kills.json` so a RamClean
/// restart doesn't forget them. Resolved kills leave the ledger; the caller writes
/// their outcome to the habit log and relabels the model.
public final class KillLedger {
    public private(set) var pending: [KillRecord] = []
    private let fileURL: URL

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("kills.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? HabitStore.decoder.decode([KillRecord].self, from: data) {
            pending = saved
        }
    }

    /// Starts following a kill. A newer kill of the same app replaces an older one.
    public func recordKill(_ r: KillRecord) {
        pending.removeAll { $0.key == r.key }
        pending.append(r)
        persist()
    }

    public func markForced(key: String) {
        guard let i = pending.lastIndex(where: { $0.key == key }) else { return }
        pending[i].forced = true
        persist()
    }

    /// The app exited. Returns the record the first time, so the caller can say it's done.
    @discardableResult
    public func noteTerminated(key: String, at now: Date) -> KillRecord? {
        guard let i = pending.lastIndex(where: { $0.key == key && $0.terminatedAt == nil }) else { return nil }
        pending[i].terminatedAt = now
        persist()
        return pending[i]
    }

    /// The app launched. If that resolves a kill as a regret, returns it and stops following it.
    public func noteLaunch(key: String, at now: Date) -> (record: KillRecord, outcome: KillOutcome)? {
        guard let i = pending.lastIndex(where: { $0.key == key }),
              let outcome = KillLabeler.outcome(pending[i], relaunchedAt: now, now: now), outcome == .relaunched else { return nil }
        let r = pending.remove(at: i)
        persist()
        return (r, outcome)
    }

    /// Resolves every kill whose window has closed without a relaunch.
    public func expire(now: Date) -> [(record: KillRecord, outcome: KillOutcome)] {
        var done: [(KillRecord, KillOutcome)] = []
        pending.removeAll { r in
            guard let o = KillLabeler.outcome(r, relaunchedAt: nil, now: now) else { return false }
            done.append((r, o))
            return true
        }
        if !done.isEmpty { persist() }
        return done
    }

    public func clear() {
        pending = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        if let data = try? HabitStore.encoder.encode(pending) { try? data.write(to: fileURL, options: .atomic) }
    }
}
