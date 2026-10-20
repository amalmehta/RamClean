import Foundation

/// The three things RamClean watches with thresholds.
public enum Resource: String, Codable, CaseIterable, Sendable {
    case memory, cpu, disk

    public var title: String {
        switch self {
        case .memory: return "Memory"
        case .cpu: return "CPU"
        case .disk: return "Disk"
        }
    }
}

/// Decides when memory, CPU or disk has crossed its threshold and an alert is due.
///
/// - CPU must stay over its line for `cpuAlertMinutes` so a short spike doesn't fire.
/// - While a resource stays over, it alerts again at most every `alertRepeatMinutes`.
/// - Once it drops 3 points below the line it's "recovered", and the next crossing alerts right away.
/// - Snoozing silences one resource until the given time.
public struct ThresholdMonitor {
    public var prefs: Preferences
    private struct State { var overSince: Date?; var lastAlert: Date?; var snoozedUntil: Date? }
    private var states: [Resource: State] = [:]
    static let hysteresis = 3.0

    public init(prefs: Preferences) { self.prefs = prefs }

    /// 0–100: how "full" the resource is.
    public static func level(_ r: Resource, _ s: SystemSnapshot) -> Double {
        switch r {
        case .memory: return s.pressure == .critical ? 100 : s.memoryUsedFraction * 100
        case .cpu: return s.cpuPercent
        case .disk: return (1 - s.diskFreeFraction) * 100
        }
    }

    public func threshold(_ r: Resource) -> Double {
        switch r {
        case .memory: return prefs.memoryAlertPercent
        case .cpu: return prefs.cpuAlertPercent
        case .disk: return prefs.diskAlertUsedPercent
        }
    }

    public mutating func snooze(_ r: Resource, until date: Date) {
        states[r, default: State()].snoozedUntil = date
    }

    /// Feed every sample in; returns the resources whose alert is due now.
    public mutating func update(_ s: SystemSnapshot, now: Date) -> [Resource] {
        guard prefs.alertsEnabled else { return [] }
        var due: [Resource] = []
        for r in Resource.allCases {
            var st = states[r] ?? State()
            let level = Self.level(r, s), line = threshold(r)
            if level >= line {
                st.overSince = st.overSince ?? now
            } else {
                st.overSince = nil
                if level < line - Self.hysteresis { st.lastAlert = nil } // recovered: re-arm
            }
            if let since = st.overSince {
                let sustained = now.timeIntervalSince(since) >= (r == .cpu ? prefs.cpuAlertMinutes * 60 : 0)
                let repeatOK = st.lastAlert.map { now.timeIntervalSince($0) >= prefs.alertRepeatMinutes * 60 } ?? true
                let awake = st.snoozedUntil.map { now >= $0 } ?? true
                if sustained && repeatOK && awake {
                    st.lastAlert = now
                    due.append(r)
                }
            }
            states[r] = st
        }
        return due
    }
}

/// The one-tap fix offered as a notification button.
public struct AlertAction: Equatable, Sendable {
    public enum Kind: String, Sendable { case quit, trash, restart }
    public var kind: Kind
    /// App key for `.quit` and `.restart`, file path for `.trash`.
    public var target: String
    public var label: String
}

/// What an alert notification says.
public struct AlertContent: Equatable, Sendable {
    public var resource: Resource
    public var title: String
    public var body: String
    public var action: AlertAction?
}

/// Turns a crossed threshold into a notification with concrete recommendations.
public enum AlertRecommender {
    static func pct(_ x: Double) -> String { "\(Int(x.rounded()))%" }

    /// Apps worth quitting: not protected, deadweight first, then the biggest.
    static func quittable(_ list: [Assessment], by key: (Assessment) -> Double, minimum: Double) -> [Assessment] {
        list.filter { a in
            guard a.group.kind == .app, key(a) >= minimum else { return false }
            if case .protected = a.verdict { return false }
            return true
        }
        .sorted { (a, b) in
            if a.isSuggestable != b.isSuggestable { return a.isSuggestable }
            return key(a) > key(b)
        }
    }

    /// "idle 3 h" style hint for an app, skipping the protection reason.
    static func why(_ a: Assessment) -> String {
        a.reasons.first { !$0.contains("%") }?.lowercased() ?? ""
    }

    /// `grown` names apps whose memory has swelled since they started; restarting the biggest
    /// is offered when nothing idle is worth quitting.
    public static func memory(_ s: SystemSnapshot, _ list: [Assessment], grown: [String: MemoryGrowth.Growth] = [:]) -> AlertContent {
        let title = "Memory is \(pct(s.memoryUsedFraction * 100)) full"
        var body = "\(HumanFormat.bytes(s.usedMemory)) of \(HumanFormat.bytes(s.totalMemory)) used"
        if s.pressure != .normal { body += ", pressure \(s.pressure.label.lowercased())" }
        body += ". "
        let picks = Array(quittable(list, by: { $0.group.memoryMB }, minimum: 100).prefix(2))
        if picks.isEmpty {
            if let (a, g) = list.compactMap({ a in grown[a.group.habitKey].map { (a, $0) } }).max(by: { $0.1.freed < $1.1.freed }) {
                body += "Nothing idle is worth quitting, but \(a.group.name) has grown from \(HumanFormat.bytes(g.from)) to \(HumanFormat.bytes(g.to)) since it started. Restarting it would free about \(HumanFormat.bytes(g.freed))."
                return AlertContent(resource: .memory, title: title, body: body,
                                    action: AlertAction(kind: .restart, target: a.group.habitKey, label: "Restart \(a.group.name)"))
            }
            if let big = list.filter({ $0.group.kind == .app }).max(by: { $0.group.memoryBytes < $1.group.memoryBytes }) {
                body += "Nothing idle is worth quitting; the biggest is \(big.group.name) (\(HumanFormat.bytes(big.group.memoryBytes)), \(why(big)))."
            }
            return AlertContent(resource: .memory, title: title, body: body, action: nil)
        }
        let freed = picks.reduce(UInt64(0)) { $0 + $1.group.memoryBytes }
        body += "Quit " + picks.map { "\($0.group.name) (\(HumanFormat.bytes($0.group.memoryBytes)), \(why($0)))" }.joined(separator: " and ")
        body += " to free about \(HumanFormat.bytes(freed))."
        let top = picks[0]
        return AlertContent(resource: .memory, title: title, body: body,
                            action: AlertAction(kind: .quit, target: top.group.habitKey, label: "Quit \(top.group.name)"))
    }

    public static func cpu(_ s: SystemSnapshot, _ list: [Assessment]) -> AlertContent {
        let title = "CPU is at \(pct(s.cpuPercent))"
        let picks = Array(quittable(list, by: { $0.cpuAverage }, minimum: 10).prefix(2))
        if picks.isEmpty {
            var body = "Nothing idle is using much CPU."
            if let busy = list.max(by: { $0.cpuAverage < $1.cpuAverage }), busy.cpuAverage >= 5 {
                var reason = ""
                if case .protected(let r) = busy.verdict { reason = ", \(r.text.lowercased())" }
                body = "Busiest: \(busy.group.name) (\(pct(busy.cpuAverage)) CPU\(reason)). Nothing idle is worth quitting."
            }
            return AlertContent(resource: .cpu, title: title, body: body, action: nil)
        }
        let body = "Quit " + picks.map { "\($0.group.name) (\(pct($0.cpuAverage)) CPU, \(why($0)))" }.joined(separator: " or ") + " to cool things down."
        let top = picks[0]
        return AlertContent(resource: .cpu, title: title, body: body,
                            action: AlertAction(kind: .quit, target: top.group.habitKey, label: "Quit \(top.group.name)"))
    }

    /// The early warning: the disk isn't over its line yet, but will be in `days` at this rate.
    public static func diskForecast(_ s: SystemSnapshot, _ report: DiskReport?, days: Double, lossPerDay: Double) -> AlertContent {
        var content = disk(s, report)
        let when = days < 1.5 ? "about a day" : "about \(Int(days.rounded())) days"
        content.title = "Disk will be full in \(when)"
        content.body = "Free space is shrinking by \(HumanFormat.bytes(UInt64(lossPerDay))) a day. " + content.body
        return content
    }

    public static func disk(_ s: SystemSnapshot, _ report: DiskReport?) -> AlertContent {
        let title = "Disk is \(pct((1 - s.diskFreeFraction) * 100)) full"
        var body = "Only \(HumanFormat.bytes(UInt64(max(0, s.diskFree)))) free. "
        guard let report else {
            return AlertContent(resource: .disk, title: title, body: body + "Open RamClean to see what to clear.", action: nil)
        }
        func size(_ i: DiskItem) -> String { HumanFormat.bytes(UInt64(max(0, i.bytes ?? 0))) }
        // Rebuildable things first: caches, and build files in projects you've stopped working on.
        let rebuildable = (report.items(.cache) + report.items(.buildArtifact)).filter(\.canTrash)
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        let clear = rebuildable.prefix(2)
        let apps = report.items(.unusedApp).prefix(2)
        let moves = (report.items(.largeFile) + report.items(.oldDownload)).filter(\.suggestMove)
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(2)
        var parts: [String] = []
        if !clear.isEmpty {
            parts.append("Clear " + clear.map { "\($0.name) (\(size($0)))" }.joined(separator: ", ") + ", which rebuild on their own")
        }
        if !apps.isEmpty {
            parts.append("uninstall " + apps.map { "\($0.name) (\(size($0)), unused for months)" }.joined(separator: ", "))
        }
        if !moves.isEmpty {
            parts.append("move " + moves.map { "\($0.name) (\(size($0)))" }.joined(separator: ", ") + " to an external drive")
        }
        if let trash = report.items(.trash).first, let b = trash.bytes, b > 0 {
            parts.append("empty the Trash (\(HumanFormat.bytes(UInt64(b))))")
        }
        body += parts.isEmpty ? "No big caches or old files found; see RamClean for large files." : parts.joined(separator: "; ") + "."
        let action = clear.first.map { AlertAction(kind: .trash, target: $0.path, label: "Trash \($0.name)") }
        return AlertContent(resource: .disk, title: title, body: body, action: action)
    }
}
