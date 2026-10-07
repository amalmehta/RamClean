import Foundation

/// Why an app is off-limits right now. Protection always wins over the model.
public enum ProtectionReason: Equatable, Sendable {
    case system
    case itself
    case alwaysKeep
    case frontmost
    case recentlyUsed(minutes: Int)
    /// RamClean hasn't watched long enough to know whether you use it.
    case learning(minutes: Int)
    case playingAudio
    case busyWork(cpu: Int)
    case hostsCommandLine([String])
    case menuBarUtility
    case commandLine
    case background

    public var text: String {
        switch self {
        case .system: return "Part of macOS"
        case .itself: return "That's RamClean"
        case .alwaysKeep: return "On your always-keep list"
        case .frontmost: return "You're using it now"
        case .recentlyUsed(let m): return m <= 1 ? "Used a minute ago" : "Used \(m) min ago"
        case .learning(let m): return "Still learning (watched \(m) min)"
        case .playingAudio: return "Playing audio"
        case .busyWork(let cpu): return "Working (\(cpu)% CPU)"
        case .hostsCommandLine(let names): return "Running \(names.prefix(3).joined(separator: ", ")) in a terminal"
        case .menuBarUtility: return "Menu bar or background app"
        case .commandLine: return "Command-line tool in a terminal"
        case .background: return "Background process (macOS restarts it)"
        }
    }
}

public struct ProtectionContext {
    public var prefs: Preferences
    public var frontmostKey: String?
    public var selfBundleID: String?
    public var audioPIDs: Set<Int32>
    public var cpuAverage: Double
    public var minutesSinceActive: Double
    public var everActive: Bool

    public init(prefs: Preferences, frontmostKey: String?, selfBundleID: String?, audioPIDs: Set<Int32>,
                cpuAverage: Double, minutesSinceActive: Double, everActive: Bool = true) {
        self.prefs = prefs; self.frontmostKey = frontmostKey; self.selfBundleID = selfBundleID
        self.audioPIDs = audioPIDs; self.cpuAverage = cpuAverage; self.minutesSinceActive = minutesSinceActive
        self.everActive = everActive
    }
}

public enum ProtectionRules {
    public static let systemBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.loginwindow", "com.apple.Spotlight", "com.apple.notificationcenterui",
        "com.apple.WindowManager", "com.apple.systempreferences", "com.apple.ActivityMonitor",
    ]
    static let systemPathPrefixes = ["/System/Library/", "/usr/", "/Library/Apple/", "/sbin/", "/bin/"]

    public static func reason(for g: AppGroup, _ c: ProtectionContext) -> ProtectionReason? {
        switch g.kind {
        case .commandLine: return .commandLine
        case .background: return .background
        case .menuBar where !c.prefs.includeMenuBarApps: return .menuBarUtility
        default: break
        }
        if let id = g.bundleID {
            if id == c.selfBundleID { return .itself }
            if systemBundleIDs.contains(id) { return .system }
        }
        if let p = g.bundlePath, systemPathPrefixes.contains(where: p.hasPrefix) { return .system }
        if c.prefs.matches(c.prefs.alwaysKeep, g.bundleID) { return .alwaysKeep }
        if g.habitKey == c.frontmostKey { return .frontmost }
        if g.pids.contains(where: c.audioPIDs.contains) { return .playingAudio }
        if !g.hostedCommands.isEmpty { return .hostsCommandLine(g.hostedCommands) }
        if c.prefs.protectBusyWorkTools, c.prefs.matches(c.prefs.workTools, g.bundleID),
           c.cpuAverage >= c.prefs.busyCPUPercent {
            return .busyWork(cpu: Int(c.cpuAverage.rounded()))
        }
        if c.minutesSinceActive < c.prefs.recentUseMinutes {
            if !c.everActive { return .learning(minutes: Int(c.minutesSinceActive.rounded())) }
            return .recentlyUsed(minutes: Int(c.minutesSinceActive.rounded()))
        }
        return nil
    }
}
