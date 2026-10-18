import Foundation

/// What the app layer knows about a running app (from NSRunningApplication),
/// kept as a plain struct so grouping is testable without AppKit.
public struct RunningAppInfo: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var bundlePath: String?
    /// Regular = has a Dock icon. Accessory/background apps are menu bar utilities and agents.
    public var isRegular: Bool

    public init(pid: Int32, bundleID: String?, name: String, bundlePath: String?, isRegular: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.bundlePath = bundlePath; self.isRegular = isRegular
    }
}

public enum GroupKind: String, Codable, Sendable {
    case app            // Dock app — the only kind RamClean suggests quitting
    case menuBar        // accessory / background-only app
    case commandLine    // a process started from a terminal
    case background     // anything else this user owns (agents, helpers launchd restarts)
}

/// An app together with all its helper processes (e.g. Chrome + every "Google Chrome Helper").
public struct AppGroup: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: GroupKind
    public var name: String
    public var bundleID: String?
    public var bundlePath: String?
    public var mainPID: Int32?
    public var pids: [Int32]
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    /// Non-shell commands running in terminal sessions inside this app (e.g. "claude" in Terminal).
    public var hostedCommands: [String]
    public var hostedCPUPercent: Double

    /// The key habits and training examples are stored under.
    public var habitKey: String { AppKey.key(bundleID: bundleID, bundlePath: bundlePath) ?? id }
    public var memoryMB: Double { Double(memoryBytes) / 1_048_576 }
}

/// How RamClean names and files an app. Most apps go by their bundle ID, but a framework's
/// stock runtime gives every app built on it the same one (each `electron .` run of a project
/// is "com.github.Electron"), so those go by where they live instead.
public enum AppKey {
    public static let sharedBundleIDs: Set<String> = ["com.github.Electron", "org.nwjs.nwjs"]

    public static func key(bundleID: String?, bundlePath: String?) -> String? {
        if let id = bundleID, !sharedBundleIDs.contains(id) { return id }
        return bundlePath ?? bundleID
    }

    /// The project a dev runtime was started from: the folder holding its `node_modules`.
    public static func project(bundlePath: String?) -> String? {
        guard let p = bundlePath, let r = p.range(of: "/node_modules/") else { return nil }
        let folder = (String(p[..<r.lowerBound]) as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        return folder.isEmpty ? nil : folder
    }

    /// "Electron (trip_planner)" for a dev runtime, so two projects don't look like one app.
    public static func name(_ name: String, bundleID: String?, bundlePath: String?) -> String {
        guard bundleID.map(sharedBundleIDs.contains) ?? true, let project = project(bundlePath: bundlePath) else { return name }
        return "\(name) (\(project))"
    }
}

public enum AppGrouper {
    public static let shells: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu",
        "login", "tmux", "screen", "ssh-agent",
    ]

    /// The outermost `.app` bundle a binary lives in, so helpers nested inside
    /// `Foo.app/Contents/Frameworks/Foo Helper.app` still group under Foo.app.
    public static func bundlePath(for path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    public static func group(_ processes: [ProcessSnapshot], apps: [RunningAppInfo]) -> [AppGroup] {
        var appByPID: [Int32: RunningAppInfo] = [:]
        var appByPath: [String: RunningAppInfo] = [:]
        for app in apps {
            appByPID[app.pid] = app
            if let p = app.bundlePath, appByPath[p] == nil || app.isRegular { appByPath[p] = app }
        }

        var groups: [String: AppGroup] = [:]
        var keyByPID: [Int32: String] = [:]

        for proc in processes {
            let bundle = bundlePath(for: proc.path)
            let key: String
            var kind: GroupKind
            var info: RunningAppInfo?
            if let app = appByPID[proc.pid] {
                key = app.bundlePath ?? "pid:\(proc.pid)"; info = app; kind = app.isRegular ? .app : .menuBar
            } else if let bundle, let app = appByPath[bundle] {
                key = bundle; info = app; kind = app.isRegular ? .app : .menuBar
            } else if proc.hasTTY {
                key = "cli:\(proc.name)"; kind = .commandLine
            } else if let bundle {
                key = bundle; kind = .background
            } else {
                key = "proc:\(proc.name)"; kind = .background
            }
            keyByPID[proc.pid] = key

            var g = groups[key] ?? AppGroup(
                id: key, kind: kind,
                name: AppKey.name(info?.name ?? (bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? proc.name),
                                  bundleID: info?.bundleID, bundlePath: info?.bundlePath ?? bundle),
                bundleID: info?.bundleID, bundlePath: info?.bundlePath ?? bundle,
                mainPID: info?.pid, pids: [], memoryBytes: 0, cpuPercent: 0,
                hostedCommands: [], hostedCPUPercent: 0)
            g.pids.append(proc.pid)
            g.memoryBytes += proc.footprintBytes
            g.cpuPercent += proc.cpuPercent
            groups[key] = g
        }

        // Attach terminal work to the app that hosts it: Terminal → login → zsh → claude.
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for proc in processes where proc.hasTTY && !shells.contains(proc.name) {
            var cursor = proc.ppid
            for _ in 0..<32 {
                guard cursor > 1, let parent = byPID[cursor] else { break }
                if let key = keyByPID[parent.pid], let host = groups[key], host.kind == .app || host.kind == .menuBar {
                    if !host.hostedCommands.contains(proc.name) { groups[key]!.hostedCommands.append(proc.name) }
                    groups[key]!.hostedCPUPercent += proc.cpuPercent
                    break
                }
                cursor = parent.ppid
            }
        }

        return groups.values.sorted { $0.memoryBytes > $1.memoryBytes }
    }
}
