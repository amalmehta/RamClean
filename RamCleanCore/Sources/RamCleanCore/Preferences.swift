import Foundation

/// Every setting in one place. The Settings window edits this; the engine reads it.
public struct Preferences: Codable, Equatable, Sendable {
    /// Seconds between checks.
    public var checkInterval: Double = 15
    public var notificationsEnabled = true
    /// Only suggest quitting when memory used is at least this percent (or pressure is elevated).
    public var memoryTriggerPercent: Double = 80
    /// Ignore apps smaller than this.
    public var minAppMemoryMB: Double = 400
    /// An app counts as deadweight when the model's score is at least this.
    public var deadweightThreshold: Double = 0.7
    /// Apps you used within this many minutes are protected.
    public var recentUseMinutes: Double = 20
    /// Don't ask about the same app again for this many hours.
    public var cooldownHours: Double = 4
    /// Minimum minutes between any two suggestions.
    public var minMinutesBetweenNotifications: Double = 10
    /// An idle app above this CPU (avg, % of one core) is worth suggesting even if memory is fine.
    public var cpuHogPercent: Double = 60
    /// A work tool above this CPU (avg) is treated as busy — building, generating, compiling.
    public var busyCPUPercent: Double = 15
    public var protectBusyWorkTools = true
    public var includeMenuBarApps = false
    /// Warn when free disk falls below this percent.
    public var diskWarningPercent: Double = 10
    /// Seconds to wait after a polite quit before offering Force Quit.
    public var forceQuitAfterSeconds: Double = 8
    public var alwaysKeep: [String] = []
    /// Bundle IDs treated as work tools. A trailing "*" matches a prefix.
    public var workTools: [String] = Preferences.defaultWorkTools

    public init() {}

    public static let defaultWorkTools = [
        "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.docker.docker",
        "com.jetbrains.*", "com.google.android.studio", "com.sublimetext.*", "dev.zed.Zed",
    ]

    public func matches(_ list: [String], _ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return list.contains { entry in
            entry.hasSuffix("*") ? id.hasPrefix(String(entry.dropLast())) : entry == id
        }
    }

    // Decode tolerantly so adding a setting never wipes the user's existing ones.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? cur }
        checkInterval = v(.checkInterval, checkInterval)
        notificationsEnabled = v(.notificationsEnabled, notificationsEnabled)
        memoryTriggerPercent = v(.memoryTriggerPercent, memoryTriggerPercent)
        minAppMemoryMB = v(.minAppMemoryMB, minAppMemoryMB)
        deadweightThreshold = v(.deadweightThreshold, deadweightThreshold)
        recentUseMinutes = v(.recentUseMinutes, recentUseMinutes)
        cooldownHours = v(.cooldownHours, cooldownHours)
        minMinutesBetweenNotifications = v(.minMinutesBetweenNotifications, minMinutesBetweenNotifications)
        cpuHogPercent = v(.cpuHogPercent, cpuHogPercent)
        busyCPUPercent = v(.busyCPUPercent, busyCPUPercent)
        protectBusyWorkTools = v(.protectBusyWorkTools, protectBusyWorkTools)
        includeMenuBarApps = v(.includeMenuBarApps, includeMenuBarApps)
        diskWarningPercent = v(.diskWarningPercent, diskWarningPercent)
        forceQuitAfterSeconds = v(.forceQuitAfterSeconds, forceQuitAfterSeconds)
        alwaysKeep = v(.alwaysKeep, alwaysKeep)
        workTools = v(.workTools, workTools)
    }
}
