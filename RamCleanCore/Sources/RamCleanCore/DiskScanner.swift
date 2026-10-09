import CoreServices
import Foundation

/// Something on disk worth a look, and why.
public struct DiskItem: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, CaseIterable, Codable {
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

public struct DiskReport: Equatable, Sendable, Codable {
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
    /// Ask Spotlight for large files and code projects instead of walking the home folder
    /// (seconds instead of many minutes). Falls back to walking if Spotlight can't answer.
    public var useSpotlight = true
    /// Stay out of Desktop, Documents and Downloads. Reading them can raise a macOS permission
    /// prompt that blocks the scan until someone answers, so background scans set this until
    /// you've run a scan yourself. Spotlight's large-file results there still count (no access needed).
    public var avoidProtectedFolders = false
    var protectedFolders: [String] {
        ["Desktop", "Documents", "Downloads"].map { Self.realPath(home.appendingPathComponent($0).path) + "/" }
    }
    func isProtected(_ path: String) -> Bool {
        avoidProtectedFolders && protectedFolders.contains { Self.realPath(path).hasPrefix($0) || Self.realPath(path) + "/" == $0 }
    }
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

        progress("developer and app caches", items)
        // Gather every cache candidate first, then measure them all in parallel.
        var candidates: [(url: URL, make: (Int64) -> DiskItem)] = []
        for k in Self.known {
            let url = home.appendingPathComponent(k.path)
            guard exists(url) else { continue }
            candidates.append((url, { DiskItem(name: k.name, path: url.path, bytes: $0, kind: .cache, reason: k.reason,
                                               caution: k.caution, canTrash: k.canTrash) }))
        }
        for (folder, reason) in [("Library/Caches", "App cache; the app rebuilds it as needed"),
                                 (".cache", "Tool cache (e.g. downloaded models or packages); downloaded again when needed")] {
            let parent = home.appendingPathComponent(folder)
            for child in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                candidates.append((child, { DiskItem(name: Self.prettyCacheName(child.lastPathComponent), path: child.path,
                                                     bytes: $0, kind: .cache, reason: reason) }))
            }
        }
        let sizes = Self.allocatedSizes(candidates.map(\.url), isCancelled: isCancelled)
        for (c, size) in zip(candidates, sizes) where size >= minCacheBytes {
            items.append(c.make(size))
            claimed.append(c.url.path)
        }

        progress("apps you don't use", items)
        items += unusedApps(isCancelled: isCancelled)

        progress("old downloads", items)
        let downloads = avoidProtectedFolders ? [] : oldDownloads()
        items += downloads

        progress("large files and projects", items)
        let skipFiles = Set(downloads.map(\.path))
        let found = (useSpotlight ? spotlightSearch(excluding: claimed, skipFiles: skipFiles) : nil)
            ?? walkHome(excluding: claimed, skipFiles: skipFiles, isCancelled: isCancelled)
        items += found.largeFiles
        progress("build files in old projects", items)
        items += buildArtifacts(in: found.projects.filter { !isProtected($0) }, isCancelled: isCancelled)

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
                if Self.artifacts[url.lastPathComponent] != nil || skip.contains(Self.realPath(url.path)) || isProtected(url.path) {
                    e.skipDescendants()
                }
                continue
            }
            if Self.projectMarkers.contains(url.lastPathComponent) { projects.insert(url.deletingLastPathComponent().path) }
            guard v.isRegularFile == true, let size = v.totalFileAllocatedSize.map(Int64.init), size >= largeFileBytes,
                  !skipFilesReal.contains(url.path) else { continue }
            let opened = [v.contentAccessDate, v.contentModificationDate].compactMap { $0 }.max()
            if let item = largeFileItem(url, size: size, opened: opened) { found.append(item) }
        }
        return (Array(found.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(maxLargeFiles)), projects)
    }

    /// A large-file entry, or nil if it's active work (opened or changed within `activeDays`).
    func largeFileItem(_ url: URL, size: Int64, opened: Date?) -> DiskItem? {
        if isActive(opened) { return nil }
        let stale = (daysSince(opened) ?? 0) >= staleDays
        var reason = Self.largeFileReason(url, lastOpened: opened, now: now)
        if stale { reason += ". Not needed day to day: move it to an external drive or cloud storage" }
        return DiskItem(name: url.lastPathComponent, path: url.path, bytes: size, kind: .largeFile,
                        reason: reason, lastOpened: opened, suggestMove: stale)
    }

    /// Large files and code projects straight from Spotlight's index. Nil when Spotlight
    /// can't run the query (indexing off), so the caller walks the folder instead.
    func spotlightSearch(excluding claimed: [String], skipFiles: Set<String>) -> (largeFiles: [DiskItem], projects: Set<String>)? {
        let homePath = Self.realPath(home.path)
        let library = homePath + "/Library/", apps = homePath + "/Applications/"
        let claimedDirs = claimed.map { Self.realPath($0) + "/" }
        func usable(_ path: String) -> Bool {
            guard path.hasPrefix(homePath + "/"), !path.hasPrefix(library), !path.hasPrefix(apps),
                  !claimedDirs.contains(where: path.hasPrefix) else { return false }
            let parts = path.dropFirst(homePath.count + 1).split(separator: "/")
            return !parts.contains { $0.hasPrefix(".") || Self.artifacts[String($0)] != nil }
        }

        let sizeQuery = "kMDItemFSSize >= \(largeFileBytes)"
        guard let big = Spotlight.query(sizeQuery, scope: home) else { return nil }
        var files: [DiskItem] = []
        let bigPaths = big.compactMap { Spotlight.string($0, kMDItemPath) }
        for (item, path) in zip(big, big.map { Spotlight.string($0, kMDItemPath) }) {
            guard let path, usable(path), !skipFiles.contains(path),
                  !bigPaths.contains(where: { $0 != path && path.hasPrefix($0 + "/") }) else { continue } // inside a bigger bundle
            let size = (Spotlight.number(item, "kMDItemPhysicalSize" as CFString) ?? Spotlight.number(item, kMDItemFSSize)).map(Int64.init) ?? 0
            guard size >= largeFileBytes else { continue }
            let opened = [Spotlight.date(item, kMDItemLastUsedDate), Spotlight.date(item, kMDItemFSContentChangeDate)].compactMap { $0 }.max()
            if let d = largeFileItem(URL(fileURLWithPath: path), size: size, opened: opened) { files.append(d) }
        }

        let markerQuery = Self.projectMarkers.map { "kMDItemFSName == \"\($0)\"" }.joined(separator: " || ")
        guard let markers = Spotlight.query(markerQuery, scope: home) else { return nil }
        let projects = Set(markers.compactMap { Spotlight.string($0, kMDItemPath) }.filter(usable)
            .map { ($0 as NSString).deletingLastPathComponent })
        return (Array(files.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(maxLargeFiles)), projects)
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
        let fm = FileManager.default
        var candidates: [(dir: URL, make: (Int64) -> DiskItem)] = []
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
                let idle = daysSince(activity).map { "\(HumanFormat.duration(minutes: $0 * 1440)) ago" } ?? "a long time ago"
                candidates.append((dir, { DiskItem(name: "\(root.lastPathComponent) › \(folder)", path: dir.path, bytes: $0, kind: .buildArtifact,
                                                   reason: "Project last changed \(idle). These are build or dependency files; they come back with \(rebuild)",
                                                   lastOpened: activity) }))
            }
        }
        let sizes = Self.allocatedSizes(candidates.map(\.dir), isCancelled: isCancelled)
        return zip(candidates, sizes).filter { $0.1 >= minArtifactBytes }.map { $0.0.make($0.1) }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
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
                out.append(DiskItem(name: app.deletingPathExtension().lastPathComponent, path: app.path, bytes: nil, kind: .unusedApp,
                                    reason: "Not opened in \(HumanFormat.duration(minutes: days * 1440)). Uninstall it by moving it to the Trash",
                                    caution: "Its settings in ~/Library stay behind; reinstall from the developer or the App Store if you need it again",
                                    lastOpened: used))
            }
        }
        let sizes = Self.allocatedSizes(out.map { URL(fileURLWithPath: $0.path) }, isCancelled: isCancelled)
        for i in out.indices { out[i].bytes = sizes[i] }
        return out.filter { ($0.bytes ?? 0) >= minAppBytes }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    /// Big things in ~/Downloads you haven't opened or changed in `staleDays`.
    func oldDownloads() -> [DiskItem] {
        let dir = home.appendingPathComponent("Downloads")
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var old: [(url: URL, touched: Date?)] = []
        for url in entries {
            let v = try? url.resourceValues(forKeys: keys)
            let touched = [v?.contentAccessDate, v?.contentModificationDate].compactMap { $0 }.max()
            guard let days = daysSince(touched), days >= staleDays else { continue }
            old.append((url, touched))
        }
        let sizes = Self.allocatedSizes(old.map(\.url), isCancelled: { false })
        return zip(old, sizes).filter { $0.1 >= oldDownloadBytes }.map { o, size in
            DiskItem(name: o.url.lastPathComponent, path: o.url.path, bytes: size, kind: .oldDownload,
                     reason: Self.largeFileReason(o.url, lastOpened: o.touched, now: now),
                     lastOpened: o.touched, suggestMove: size >= largeFileBytes)
        }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
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

    /// Space a file or folder takes on disk, using fts (the same walk `du` does): about
    /// twice as fast as Foundation's enumerator because it doesn't build an object per file.
    public static func allocatedSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        url.path.withCString { p in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(p), nil]
            defer { free(paths[0]) }
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            while let ent = fts_read(fts) {
                if Int32(ent.pointee.fts_info) == FTS_F, let st = ent.pointee.fts_statp {
                    total += Int64(st.pointee.st_blocks) * 512
                }
            }
        }
        return total
    }

    /// Sizes many folders at once, several at a time.
    static func allocatedSizes(_ urls: [URL], isCancelled: () -> Bool) -> [Int64] {
        var sizes = [Int64](repeating: 0, count: urls.count)
        guard !urls.isEmpty, !isCancelled() else { return sizes }
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let size = allocatedSize(urls[i])
            lock.lock(); sizes[i] = size; lock.unlock()
        }
        return sizes
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

/// Thin wrapper over Spotlight's synchronous query API.
enum Spotlight {
    /// The matching items, or nil if Spotlight couldn't run the query.
    static func query(_ text: String, scope: URL) -> [MDItem]? {
        guard let q = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil) else { return nil }
        MDQuerySetSearchScope(q, [scope.path] as CFArray, 0)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        return (0..<MDQueryGetResultCount(q)).compactMap { i in
            MDQueryGetResultAtIndex(q, i).map { Unmanaged<MDItem>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    static func string(_ item: MDItem, _ key: CFString) -> String? { MDItemCopyAttribute(item, key) as? String }
    static func number(_ item: MDItem, _ key: CFString) -> Double? { (MDItemCopyAttribute(item, key) as? NSNumber)?.doubleValue }
    static func date(_ item: MDItem, _ key: CFString) -> Date? { MDItemCopyAttribute(item, key) as? Date }
}
