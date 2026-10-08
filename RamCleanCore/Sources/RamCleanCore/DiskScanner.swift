import CoreServices
import Foundation

/// Something on disk worth a look, and why.
public struct DiskItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case cache, buildArtifact, unusedApp, oldDownload, largeFile, trash

        public var title: String {
            switch self {
            case .cache: return "Rebuildable caches"
            case .buildArtifact: return "Build files in projects you've stopped working on"
            case .unusedApp: return "Apps you don't use anymore"
            case .oldDownload: return "Old downloads"
            case .largeFile: return "Large files"
            case .trash: return "Trash"
            }
        }
    }

    public var name: String
    public var path: String
    /// Allocated size on disk; nil when macOS wouldn't let RamClean measure it.
    public var bytes: Int64?
    public var kind: Kind
    public var reason: String
    /// Shown in orange: something to check before removing it.
    public var caution: String?
    /// False for things RamClean only advises on (Trash, simulator devices).
    public var canTrash: Bool
    public var lastOpened: Date?
    /// Not opened in a long time: worth moving to an external drive or cloud storage.
    public var suggestMove: Bool
    public var id: String { path }

    public init(name: String, path: String, bytes: Int64?, kind: Kind, reason: String, caution: String? = nil,
                canTrash: Bool = true, lastOpened: Date? = nil, suggestMove: Bool = false) {
        self.name = name; self.path = path; self.bytes = bytes; self.kind = kind; self.reason = reason
        self.caution = caution; self.canTrash = canTrash; self.lastOpened = lastOpened; self.suggestMove = suggestMove
    }
}

public struct DiskReport: Equatable, Sendable {
    public var items: [DiskItem]
    public var scannedAt: Date

    public init(items: [DiskItem], scannedAt: Date) { self.items = items; self.scannedAt = scannedAt }

    /// What moving every trashable item to the Trash would free (once the Trash is emptied).
    public var reclaimableBytes: Int64 {
        items.filter(\.canTrash).reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    public func items(_ kind: DiskItem.Kind) -> [DiskItem] { items.filter { $0.kind == kind } }
}

/// Finds space RamClean can recommend freeing. It only reads; removing anything is
/// a separate, confirmed action in the app.
///
/// Live work is never suggested: projects with changes in the last `activeDays`,
/// build folders written to in that time (a build in progress), and files opened
/// or changed recently are all skipped.
public struct DiskScanner {
    public var home: URL
    public var minCacheBytes: Int64 = 200 * 1_048_576
    public var largeFileBytes: Int64 = 1_073_741_824
    public var maxLargeFiles = 30
    /// Not opened for this long = no use anymore (apps, downloads, large files to move off).
    public var staleDays: Double = 90
    /// Touched within this long = active work, never suggested.
    public var activeDays: Double = 30
    public var minArtifactBytes: Int64 = 50 * 1_048_576
    public var oldDownloadBytes: Int64 = 50 * 1_048_576
    public var minAppBytes: Int64 = 20 * 1_048_576
    public var appFolders: [URL]
    /// Apps never suggested for removal (your always-keep list and work tools), by bundle ID.
    public var isKept: (String) -> Bool = { _ in false }
    /// Bundle paths of apps running right now.
    public var runningAppPaths: Set<String> = []
    /// When an app was last opened (Spotlight's record); replaceable for tests.
    public var appLastUsed: (URL) -> Date? = DiskScanner.spotlightLastUsed
    public var now = Date()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        appFolders = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public static func spotlightLastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    func daysSince(_ d: Date?) -> Double? { d.map { now.timeIntervalSince($0) / 86_400 } }
    func isActive(_ d: Date?) -> Bool { (daysSince(d) ?? .infinity) < activeDays }

    struct Known {
        var path: String
        var name: String
        var reason: String
        var caution: String? = nil
        var canTrash = true
    }

    /// Developer and tool caches that are safe to remove because they come back on their own.
    static let known: [Known] = [
        Known(path: "Library/Developer/Xcode/DerivedData", name: "Xcode build data", reason: "Rebuilt the next time you build in Xcode"),
        Known(path: "Library/Developer/Xcode/Archives", name: "Xcode archives", reason: "Old app builds you archived",
              caution: "Keep any you may need to re-submit or to read crash reports"),
        Known(path: "Library/Developer/Xcode/iOS DeviceSupport", name: "iOS device support", reason: "Debug symbols; downloaded again when you connect that device"),
        Known(path: "Library/Developer/Xcode/watchOS DeviceSupport", name: "watchOS device support", reason: "Debug symbols; downloaded again when you connect that device"),
        Known(path: "Library/Developer/Xcode/macOS DeviceSupport", name: "macOS device support", reason: "Debug symbols; downloaded again when needed"),
        Known(path: "Library/Developer/CoreSimulator/Caches", name: "Simulator caches", reason: "Rebuilt automatically"),
        Known(path: "Library/Developer/CoreSimulator/Devices", name: "Simulator devices",
              reason: "Remove unused simulators in Xcode › Window › Devices and Simulators, or run: xcrun simctl delete unavailable",
              canTrash: false),
        Known(path: ".npm/_cacache", name: "npm cache", reason: "Downloaded again when needed"),
        Known(path: ".gradle/caches", name: "Gradle cache", reason: "Downloaded again when needed"),
        Known(path: ".cargo/registry", name: "Cargo registry cache", reason: "Downloaded again when needed"),
    ]

    /// `progress` gets the step being scanned and everything found so far, so results can show as they arrive.
    public func scan(progress: (String, [DiskItem]) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) -> DiskReport {
        var items: [DiskItem] = []
        var claimed: [String] = []

        progress("developer caches", items)
        for k in Self.known {
            let url = home.appendingPathComponent(k.path)
            guard exists(url), !isCancelled() else { continue }
            let size = Self.allocatedSize(url)
            guard size >= minCacheBytes else { continue }
            items.append(DiskItem(name: k.name, path: url.path, bytes: size, kind: .cache, reason: k.reason,
                                  caution: k.caution, canTrash: k.canTrash))
            claimed.append(url.path)
        }

        progress("app caches", items)
        for (folder, reason) in [("Library/Caches", "App cache; the app rebuilds it as needed"),
                                 (".cache", "Tool cache (e.g. downloaded models or packages); downloaded again when needed")] {
            let parent = home.appendingPathComponent(folder)
            let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            for child in children where !isCancelled() {
                let size = Self.allocatedSize(child)
                guard size >= minCacheBytes else { continue }
                items.append(DiskItem(name: Self.prettyCacheName(child.lastPathComponent), path: child.path, bytes: size,
                                      kind: .cache, reason: reason))
                claimed.append(child.path)
            }
        }

        progress("apps you don't use", items)
        items += unusedApps(isCancelled: isCancelled)

        progress("old downloads", items)
        let downloads = oldDownloads()
        items += downloads

        progress("projects and large files in your home folder", items)
        let walk = walkHome(excluding: claimed, skipFiles: Set(downloads.map(\.path)), isCancelled: isCancelled)
        items += walk.largeFiles
        progress("build files in old projects", items)
        items += buildArtifacts(in: walk.projects, isCancelled: isCancelled)

        progress("the Trash", items)
        let trash = home.appendingPathComponent(".Trash")
        if exists(trash) {
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil
            let size = readable ? Self.allocatedSize(trash) : nil
            if size == nil || size! > 0 {
                items.append(DiskItem(name: "Trash", path: trash.path, bytes: size, kind: .trash,
                                      reason: size == nil
                                        ? "macOS doesn't let RamClean measure the Trash. Empty it in Finder to free its space."
                                        : "Files you've already deleted still take space until you empty the Trash in Finder.",
                                      canTrash: false))
            }
        }

        let sorted = items.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        return DiskReport(items: sorted, scannedAt: Date())
    }

    /// Folders that hold rebuildable build or dependency output, and how to get them back.
    static let artifacts: [String: String] = [
        "node_modules": "npm install", ".venv": "recreating the virtual environment", "venv": "recreating the virtual environment",
        "target": "the next cargo or maven build", ".build": "swift build", "build": "the next build", "dist": "the next build",
        ".next": "next build", ".gradle": "the next gradle build", "Pods": "pod install", "DerivedData": "the next Xcode build",
    ]
    /// Files that mark a folder as a code project.
    static let projectMarkers: Set<String> = [
        "package.json", "Cargo.toml", "Package.swift", "pyproject.toml", "requirements.txt", "setup.py", "pom.xml",
        "build.gradle", "build.gradle.kts", "Podfile", "go.mod", "Gemfile", "project.yml",
    ]

    /// One pass over the home folder (outside ~/Library): large files, plus every project root seen.
    func walkHome(excluding claimed: [String], skipFiles: Set<String>, isCancelled: () -> Bool) -> (largeFiles: [DiskItem], projects: Set<String>) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        // Compare resolved paths: the enumerator reports them with symlinks resolved.
        let root = URL(fileURLWithPath: Self.realPath(home.path), isDirectory: true)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return ([], []) }
        let skip = Set((claimed.map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Library"), home.appendingPathComponent("Applications")])
            .map { Self.realPath($0.path) })
        let skipFilesReal = Set(skipFiles.map(Self.realPath))
        var found: [DiskItem] = []
        var projects = Set<String>()
        for case let url as URL in e {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                // Don't wander through dependency trees: they're judged as a whole later.
                if Self.artifacts[url.lastPathComponent] != nil || skip.contains(Self.realPath(url.path)) { e.skipDescendants() }
                continue
            }
            if Self.projectMarkers.contains(url.lastPathComponent) { projects.insert(url.deletingLastPathComponent().path) }
            guard v.isRegularFile == true, let size = v.totalFileAllocatedSize.map(Int64.init), size >= largeFileBytes,
                  !skipFilesReal.contains(url.path) else { continue }
            let opened = [v.contentAccessDate, v.contentModificationDate].compactMap { $0 }.max()
            if isActive(opened) { continue } // you're working with it
            let stale = (daysSince(opened) ?? 0) >= staleDays
            var reason = Self.largeFileReason(url, lastOpened: opened, now: now)
            if stale { reason += ". Not needed day to day: move it to an external drive or cloud storage" }
            found.append(DiskItem(name: url.lastPathComponent, path: url.path, bytes: size, kind: .largeFile,
                                  reason: reason, lastOpened: opened, suggestMove: stale))
        }
        return (Array(found.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(maxLargeFiles)), projects)
    }

    /// The newest change anywhere near the top of a project (its files, and git's index/HEAD).
    func lastActivity(ofProject root: URL) -> Date? {
        let fm = FileManager.default
        var dates: [Date] = []
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for c in children where Self.artifacts[c.lastPathComponent] == nil {
            if let d = try? c.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { dates.append(d) }
        }
        for g in [".git/index", ".git/HEAD", ".git/FETCH_HEAD"] {
            if let d = try? fm.attributesOfItem(atPath: root.appendingPathComponent(g).path)[.modificationDate] as? Date { dates.append(d) }
        }
        return dates.max()
    }

    /// Dependency and build folders inside projects you haven't touched in `activeDays`.
    func buildArtifacts(in projects: Set<String>, isCancelled: () -> Bool) -> [DiskItem] {
        var out: [DiskItem] = []
        let fm = FileManager.default
        for path in projects.sorted() where !isCancelled() {
            let root = URL(fileURLWithPath: path)
            let activity = lastActivity(ofProject: root)
            if isActive(activity) { continue } // live project
            for (folder, rebuild) in Self.artifacts {
                let dir = root.appendingPathComponent(folder)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let written = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if isActive(written) { continue } // a build may be running
                let size = Self.allocatedSize(dir)
                guard size >= minArtifactBytes else { continue }
                let idle = daysSince(activity).map { "\(HumanFormat.duration(minutes: $0 * 1440)) ago" } ?? "a long time ago"
                out.append(DiskItem(name: "\(root.lastPathComponent) › \(folder)", path: dir.path, bytes: size, kind: .buildArtifact,
                                    reason: "Project last changed \(idle). These are build or dependency files; they come back with \(rebuild)",
                                    lastOpened: activity))
            }
        }
        return out.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    /// Apps in /Applications not opened in `staleDays`, by Spotlight's record. Apple apps,
    /// running apps, protected apps and apps with no record are left alone.
    func unusedApps(isCancelled: () -> Bool) -> [DiskItem] {
        var out: [DiskItem] = []
        let running = Set(runningAppPaths.map(Self.realPath))
        for folder in appFolders {
            let apps = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
            for app in apps where !isCancelled() {
                guard !running.contains(Self.realPath(app.path)),
                      let id = Bundle(url: app)?.bundleIdentifier, !id.hasPrefix("com.apple."), !isKept(id),
                      let used = appLastUsed(app), let days = daysSince(used), days >= staleDays else { continue }
                let size = Self.allocatedSize(app)
                guard size >= minAppBytes else { continue }
                out.append(DiskItem(name: app.deletingPathExtension().lastPathComponent, path: app.path, bytes: size, kind: .unusedApp,
                                    reason: "Not opened in \(HumanFormat.duration(minutes: days * 1440)). Uninstall it by moving it to the Trash",
                                    caution: "Its settings in ~/Library stay behind; reinstall from the developer or the App Store if you need it again",
                                    lastOpened: used))
            }
        }
        return out.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    /// Big things in ~/Downloads you haven't opened or changed in `staleDays`.
    func oldDownloads() -> [DiskItem] {
        let dir = home.appendingPathComponent("Downloads")
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var out: [DiskItem] = []
        for url in entries {
            let v = try? url.resourceValues(forKeys: keys)
            let touched = [v?.contentAccessDate, v?.contentModificationDate].compactMap { $0 }.max()
            guard let days = daysSince(touched), days >= staleDays else { continue }
            let size = Self.allocatedSize(url)
            guard size >= oldDownloadBytes else { continue }
            out.append(DiskItem(name: url.lastPathComponent, path: url.path, bytes: size, kind: .oldDownload,
                                reason: Self.largeFileReason(url, lastOpened: touched, now: now),
                                lastOpened: touched, suggestMove: size >= largeFileBytes))
        }
        return out.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    static func largeFileReason(_ url: URL, lastOpened: Date?, now: Date = Date()) -> String {
        let ext = url.pathExtension.lowercased()
        var kind: String
        switch ext {
        case "dmg", "pkg", "iso", "xip": kind = "Installer; usually safe to remove once installed"
        case "zip", "tar", "gz", "tgz", "7z", "rar": kind = "Archive; safe to remove if you've extracted it"
        case "mov", "mp4", "m4v", "mkv", "avi": kind = "Video"
        case "vmdk", "vdi", "qcow2", "img": kind = "Disk image or virtual machine"
        default: kind = "Large file"
        }
        if let d = lastOpened {
            let days = Int(now.timeIntervalSince(d) / 86_400)
            kind += days >= 1 ? " · last opened \(HumanFormat.duration(minutes: Double(days) * 1440)) ago" : " · opened today"
        }
        return kind
    }

    /// "com.spotify.client" → "Spotify", "Google" → "Google".
    static func prettyCacheName(_ folder: String) -> String {
        let parts = folder.split(separator: ".")
        guard parts.count >= 3, ["com", "org", "net", "io", "dev", "app"].contains(parts[0]) else { return folder }
        let name = parts[1...].joined(separator: " ")
        return name.prefix(1).uppercased() + name.dropFirst() + " cache"
    }

    /// Fully resolved path (unlike Foundation's resolvingSymlinksInPath, keeps /private).
    static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public static func allocatedSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                    errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

/// Plain-English durations shared by the app and the reasons text.
public enum HumanFormat {
    public static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    public static func duration(minutes m: Double) -> String {
        if m < 1 { return "under a minute" }
        if m < 60 { return "\(Int(m)) min" }
        if m < 60 * 48 { return String(format: "%.1f h", m / 60).replacingOccurrences(of: ".0 h", with: " h") }
        if m < 60 * 24 * 60 { return "\(Int(m / 1440)) days" }
        return "\(Int(m / 43_200)) months"
    }
}

extension Assessment {
    /// Why RamClean thinks what it does, in short phrases for the recommendation lists.
    public var reasons: [String] {
        var r: [String] = []
        var saysWhenUsed = false
        if case .protected(let reason) = verdict {
            r.append(reason.text)
            switch reason {
            case .frontmost, .recentlyUsed, .learning: saysWhenUsed = true
            default: break
            }
        }
        let f = features
        if group.kind == .app {
            if saysWhenUsed {
                // The protection reason already says when it was used.
            } else if everActive {
                r.append(f.minutesSinceActive < 1 ? "In use" : "Idle \(HumanFormat.duration(minutes: f.minutesSinceActive))")
            } else {
                r.append("Not used since RamClean started watching")
            }
            if f.avgDailyMinutes14d >= 1 {
                r.append("~\(Int(f.avgDailyMinutes14d)) min a day")
            } else if everActive {
                r.append("Rarely used (\(Int(f.daysUsed14d)) of 14 days)")
            }
        }
        if cpuAverage >= 5 { r.append("\(Int(cpuAverage.rounded()))% CPU") }
        if f.timesQuit > 0 { r.append("You quit it \(Int(f.timesQuit))× before") }
        if f.timesKept > 0 { r.append("You kept it \(Int(f.timesKept))× before") }
        return r
    }
}
