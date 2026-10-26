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
    /// When it last changed (for a folder: the folder itself or anything directly inside it).
    public var lastModified: Date?
    /// The tool's own command that frees this space, full executable path first
    /// (e.g. `xcrun simctl delete unavailable`). Run instead of moving anything to the Trash.
    public var cleanupCommand: [String]?
    public var id: String { path }

    public init(name: String, path: String, bytes: Int64?, kind: Kind, reason: String, caution: String? = nil,
                canTrash: Bool = true, lastOpened: Date? = nil, suggestMove: Bool = false,
                lastModified: Date? = nil, cleanupCommand: [String]? = nil) {
        self.name = name; self.path = path; self.bytes = bytes; self.kind = kind; self.reason = reason
        self.caution = caution; self.canTrash = canTrash; self.lastOpened = lastOpened; self.suggestMove = suggestMove
        self.lastModified = lastModified; self.cleanupCommand = cleanupCommand
    }

    /// The cleanup command as you'd type it: "brew cleanup --prune=all".
    public var cleanupCommandText: String? {
        guard let c = cleanupCommand, let tool = c.first else { return nil }
        return ([(tool as NSString).lastPathComponent] + c.dropFirst()).joined(separator: " ")
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

    /// What running every item's cleanup command (brew cleanup, simctl delete unavailable) would free.
    public var commandBytes: Int64 {
        items.filter { $0.cleanupCommand != nil }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    public func items(_ kind: DiskItem.Kind) -> [DiskItem] { items.filter { $0.kind == kind } }

    /// This report without anything that has since been deleted or moved, so an older scan
    /// can still back an alert without recommending files that are gone.
    public func droppingMissing(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> DiskReport {
        DiskReport(items: items.filter { exists($0.path) }, scannedAt: scannedAt)
    }

    /// Something you can act on to win space: rebuildable or unused items you could trash or
    /// clear with a tool's own command, big old files to move off the Mac, and the Trash itself (empty it in Finder).
    static func isWin(_ i: DiskItem) -> Bool {
        (i.bytes ?? 0) > 0 && (i.canTrash && i.kind != .largeFile || i.cleanupCommand != nil || i.suggestMove || i.kind == .trash)
    }

    /// Space you could win per category, biggest first: the at-a-glance answer to "where's my space?".
    public var totals: [(kind: DiskItem.Kind, bytes: Int64, count: Int)] {
        DiskItem.Kind.allCases.compactMap { kind in
            let wins = items(kind).filter(Self.isWin)
            let bytes = wins.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
            return bytes > 0 ? (kind, bytes, wins.count) : nil
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// What comes back on its own and has nothing to check first: rebuildable caches and build
    /// files with no caution. These are what "Select all safe" picks.
    public var safeToClear: [DiskItem] {
        items.filter { $0.canTrash && $0.caution == nil && ($0.bytes ?? 0) > 0 && [.cache, .buildArtifact].contains($0.kind) }
    }

    /// The few single items that free the most space.
    public func biggestWins(_ n: Int = 3) -> [DiskItem] {
        Array(items.filter(Self.isWin).sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(n))
    }
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
    /// ~/Library/Caches holds a folder for nearly every app, so only the big ones are listed.
    public var minLibraryCacheBytes: Int64 = 500 * 1_048_576
    /// How many folders below the home folder to look for node_modules.
    public var maxNodeModulesDepth = 8
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
    /// Full path of a command-line tool (brew, xcrun), or nil if it isn't installed; replaceable for tests.
    public var toolPath: (String) -> String? = DiskScanner.findTool
    /// Folders of simulator devices whose runtime is gone; replaceable for tests.
    public var unavailableSimulators: () -> [URL] = DiskScanner.listUnavailableSimulators
    /// Sizes remembered from earlier scans, reused when a folder hasn't changed (nil: always measure).
    public var sizeCache: SizeCache?
    /// The last walk of the home folder, reused for a while when Spotlight isn't indexing it (nil: always walk).
    public var homeWalkCache: HomeWalkCache?
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
        /// The tool's own cleanup command, tool name first. Used instead of the Trash when the
        /// tool is installed; without it, the folder goes to the Trash like any other cache.
        var command: [String]? = nil
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
        Known(path: ".npm/_cacache", name: "npm cache", reason: "Downloaded again when needed"),
        Known(path: "Library/Caches/Yarn", name: "Yarn cache", reason: "Downloaded again when needed"),
        Known(path: ".yarn/berry/cache", name: "Yarn cache", reason: "Downloaded again when needed"),
        Known(path: "Library/pnpm/store", name: "pnpm store", reason: "Downloaded again when needed",
              caution: "Projects installed with pnpm share files with it; that part comes back only once their node_modules go too"),
        Known(path: ".local/share/pnpm/store", name: "pnpm store", reason: "Downloaded again when needed",
              caution: "Projects installed with pnpm share files with it; that part comes back only once their node_modules go too"),
        Known(path: ".pnpm-store", name: "pnpm store", reason: "Downloaded again when needed",
              caution: "Projects installed with pnpm share files with it; that part comes back only once their node_modules go too"),
        Known(path: "Library/Caches/Homebrew", name: "Homebrew cache",
              reason: "Downloaded packages, fetched again when needed. Homebrew's own cleanup clears them and old versions of what you've upgraded",
              command: ["brew", "cleanup", "--prune=all"]),
        Known(path: ".gradle/caches", name: "Gradle cache", reason: "Downloaded again when needed"),
        Known(path: ".cargo/registry", name: "Cargo registry cache", reason: "Downloaded again when needed"),
        Known(path: "Library/Containers/com.docker.docker/Data/vms", name: "Docker disk image",
              reason: "Docker's images, containers and build cache. Free space inside it with: docker system prune -a (removes everything not in use), or Docker Desktop › Troubleshoot › Clean / Purge data. Lower its size limit under Settings › Resources",
              caution: "Deleting the file itself erases every container, image and volume", canTrash: false),
    ]

    /// `progress` gets the step being scanned and everything found so far, so results can show as they arrive.
    public func scan(progress: (String, [DiskItem]) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) -> DiskReport {
        let lock = NSLock()
        var items: [DiskItem] = []
        func add(_ step: String, _ new: [DiskItem], report: (String, [DiskItem]) -> Void) {
            lock.lock(); items += new; let snapshot = items; lock.unlock()
            report(step, snapshot)
        }

        // Caches, unused apps, old downloads, the Trash and the Spotlight queries don't depend
        // on each other, so they run at the same time; the total is the slowest one, not the sum.
        var claimed: [String] = [], downloads: [DiskItem] = [], nodeModules: [DiskItem] = [], index = HomeIndex()
        withoutActuallyEscaping(progress) { progress in
            withoutActuallyEscaping(isCancelled) { isCancelled in
                progress("caches, apps, downloads and Spotlight", [])
                let group = DispatchGroup(), queue = DispatchQueue.global(qos: .userInitiated)
                queue.async(group: group) {
                    // Each cache shows up the moment it's measured, not when all of them are done.
                    let c = self.caches(isCancelled: isCancelled, onFound: { add("caches", [$0], report: progress) })
                    claimed = c.claimed
                }
                queue.async(group: group) { add("apps you don't use", self.unusedApps(isCancelled: isCancelled), report: progress) }
                queue.async(group: group) {
                    downloads = self.avoidProtectedFolders ? [] : self.oldDownloads()
                    add("old downloads", downloads, report: progress)
                }
                queue.async(group: group) { add("the Trash", self.trashItem().map { [$0] } ?? [], report: progress) }
                queue.async(group: group) {
                    add("simulators", self.unavailableSimulatorItem(isCancelled: isCancelled).map { [$0] } ?? [], report: progress)
                }
                queue.async(group: group) {
                    // One pass (Spotlight, or a walk of the home folder) finds large files, projects and node_modules.
                    progress("large files and projects", [])
                    index = self.homeIndex(isCancelled: isCancelled)
                    nodeModules = self.staleNodeModules(index.nodeModules.map { URL(fileURLWithPath: $0) }, isCancelled: isCancelled)
                    add("node_modules", nodeModules, report: progress)
                }
                group.wait()
            }
        }

        // These need the results above: large files skip anything already listed, and
        // build folders come from the project list.
        let skipFiles = Set(downloads.map(\.path))
        let found = filterIndex(index, excluding: claimed, skipFiles: skipFiles)
        add("large files", found.largeFiles, report: progress)
        add("build files in old projects", buildArtifacts(in: found.projects.filter { !isProtected($0) },
                                                          listed: Set(nodeModules.map { Self.realPath($0.path) }), isCancelled: isCancelled),
            report: progress)

        return DiskReport(items: items.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }, scannedAt: Date())
    }

    /// Developer, app and tool caches over `minCacheBytes`, all measured in parallel.
    /// `onFound` is called (from any thread) for each one as soon as it's measured.
    func caches(isCancelled: () -> Bool, onFound: (DiskItem) -> Void = { _ in }) -> (items: [DiskItem], claimed: [String]) {
        var candidates: [(url: URL, min: Int64, make: (Int64) -> DiskItem)] = []
        var knownPaths = Set<String>()
        for k in Self.known {
            let url = home.appendingPathComponent(k.path)
            guard exists(url) else { continue }
            knownPaths.insert(Self.realPath(url.path))
            // The tool's own cleanup when it's installed, otherwise the Trash.
            let command = k.command.flatMap { c in toolPath(c[0]).map { [$0] + c.dropFirst() } }
            candidates.append((url, minCacheBytes, {
                DiskItem(name: k.name, path: url.path, bytes: $0, kind: .cache, reason: k.reason, caution: k.caution,
                         canTrash: k.canTrash && command == nil, lastModified: Self.lastModified(url), cleanupCommand: command)
            }))
        }
        for (folder, min, reason) in [("Library/Caches", minLibraryCacheBytes, "App cache; the app rebuilds it as needed"),
                                      (".cache", minCacheBytes, "Tool cache (e.g. downloaded models or packages); downloaded again when needed")] {
            let parent = home.appendingPathComponent(folder)
            for child in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            where !knownPaths.contains(Self.realPath(child.path)) {
                candidates.append((child, min, { DiskItem(name: Self.prettyCacheName(child.lastPathComponent), path: child.path,
                                                          bytes: $0, kind: .cache, reason: reason, lastModified: Self.lastModified(child)) }))
            }
        }
        let sizes = withoutActuallyEscaping(onFound) { onFound in
            self.sizes(candidates.map(\.url), isCancelled: isCancelled, onEach: { i, size in
                if size >= candidates[i].min { onFound(candidates[i].make(size)) }
            })
        }
        var items: [DiskItem] = [], claimed: [String] = []
        for (c, size) in zip(candidates, sizes) where size >= c.min {
            items.append(c.make(size))
            claimed.append(c.url.path)
        }
        return (items, claimed)
    }

    func trashItem() -> DiskItem? {
        let trash = home.appendingPathComponent(".Trash")
        guard exists(trash) else { return nil }
        let readable = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil
        let size = readable ? Self.allocatedSize(trash) : nil
        if let size, size == 0 { return nil }
        return DiskItem(name: "Trash", path: trash.path, bytes: size, kind: .trash,
                        reason: size == nil
                            ? "macOS doesn't let RamClean measure the Trash. Empty it in Finder to free its space."
                            : "Files you've already deleted still take space until you empty the Trash in Finder.",
                        canTrash: false)
    }

    /// Simulator devices whose runtime is no longer installed: they can't boot, and Xcode's own
    /// `xcrun simctl delete unavailable` removes them. One item for all of them.
    func unavailableSimulatorItem(isCancelled: () -> Bool) -> DiskItem? {
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        // Checked first: on a Mac without Xcode, running xcrun offers to install the developer tools.
        guard exists(devices), let xcrun = toolPath("xcrun") else { return nil }
        let dirs = unavailableSimulators().filter(exists)
        let size = sizes(dirs, isCancelled: isCancelled).reduce(0, +)
        guard size >= minArtifactBytes else { return nil }
        return DiskItem(name: "Unavailable simulators", path: devices.path, bytes: size, kind: .cache,
                        reason: "\(dirs.count) simulator device\(dirs.count == 1 ? "" : "s") for iOS, watchOS or other runtimes that are no longer installed; they can't be started",
                        canTrash: false, lastModified: dirs.compactMap(Self.lastModified).max(),
                        cleanupCommand: [xcrun, "simctl", "delete", "unavailable"])
    }

    /// node_modules folders under the home folder (not ~/Library or hidden folders, at most
    /// `maxNodeModulesDepth` deep) that haven't changed in `activeDays`, beside a project that hasn't either.
    /// `dirs` are the candidates from `homeIndex`; nil looks them up first.
    func staleNodeModules(_ dirs: [URL]? = nil, isCancelled: () -> Bool) -> [DiskItem] {
        let dirs = dirs ?? homeIndex(isCancelled: isCancelled).nodeModules.map { URL(fileURLWithPath: $0) }
        // Each check reads a few folders, so they run side by side.
        var checked = [(dir: URL, idle: Date?)?](repeating: nil, count: dirs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
            let dir = dirs[i], project = dir.deletingLastPathComponent()
            // Only a project's own dependencies: not a global install like …/lib/node_modules.
            guard !isCancelled(), exists(project.appendingPathComponent("package.json")) else { return }
            let modified = Self.lastModified(dir)
            if isActive(modified) || isActive(lastActivity(ofProject: project)) { return } // installed lately, or a live project
            lock.lock(); checked[i] = (dir, modified); lock.unlock()
        }
        let found = checked.compactMap { $0 }
        let sizes = sizes(found.map(\.dir), isCancelled: isCancelled)
        return zip(found, sizes).filter { $0.1 >= minArtifactBytes }.map { f, size in
            let idle = daysSince(f.idle).map { "\(HumanFormat.duration(minutes: $0 * 1440)) ago" } ?? "a long time ago"
            return DiskItem(name: "\(f.dir.deletingLastPathComponent().lastPathComponent) › node_modules", path: f.dir.path, bytes: size,
                            kind: .buildArtifact,
                            reason: "Last changed \(idle). Dependency files; they come back with npm install (or yarn / pnpm install)",
                            lastModified: f.idle)
        }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
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

    /// A large-file entry, or nil if it's active work (opened or changed within `activeDays`).
    func largeFileItem(_ url: URL, size: Int64, opened: Date?) -> DiskItem? {
        if isActive(opened) { return nil }
        let stale = (daysSince(opened) ?? 0) >= staleDays
        var reason = Self.largeFileReason(url, lastOpened: opened, now: now)
        if stale { reason += ". Not needed day to day: move it to an external drive or cloud storage" }
        return DiskItem(name: url.lastPathComponent, path: url.path, bytes: size, kind: .largeFile,
                        reason: reason, lastOpened: opened, suggestMove: stale)
    }

    /// Large files, code-project marker files and node_modules folders in the home folder,
    /// before filtering against the other steps' results.
    struct HomeIndex: Codable {
        struct Big: Codable {
            var path: String
            var size: Int64
            var opened: Date?
        }
        var big: [Big] = []
        var markers: [String] = []
        /// Top-level node_modules folders within `maxNodeModulesDepth`, outside ~/Library and hidden folders.
        var nodeModules: [String] = []
    }

    /// From Spotlight's index when it covers the home folder (under a second), otherwise by walking
    /// it, or from the last walk (re-checked) when `homeWalkCache` still has a good one.
    func homeIndex(isCancelled: () -> Bool) -> HomeIndex {
        if useSpotlight, let index = spotlightIndex() { return index }
        let key = HomeWalkCache.Key(root: Self.realPath(home.path), largeFileBytes: largeFileBytes,
                                    maxNodeModulesDepth: maxNodeModulesDepth, coversProtected: !avoidProtectedFolders)
        if let last = homeWalkCache?.reusable(key, now: now) { return recheck(last) }
        let index = walkIndex(isCancelled: isCancelled)
        if !isCancelled() { homeWalkCache?.store(index, key: key, now: now) }
        return index
    }

    /// An earlier walk brought up to date for what it already lists: files and folders since
    /// removed are dropped, and large files get their current size and last-opened date.
    /// Protected folders are left as they were while RamClean stays out of them.
    func recheck(_ index: HomeIndex) -> HomeIndex {
        var out = HomeIndex()
        for b in index.big {
            if isProtected(b.path) { out.big.append(b); continue }
            var st = stat()
            guard lstat(b.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            let size = Int64(st.st_blocks) * 512
            guard size >= largeFileBytes else { continue }
            out.big.append(.init(path: b.path, size: size,
                                 opened: Date(timeIntervalSince1970: TimeInterval(max(st.st_atimespec.tv_sec, st.st_mtimespec.tv_sec)))))
        }
        out.markers = index.markers.filter { isProtected($0) || FileManager.default.fileExists(atPath: $0) }
        out.nodeModules = index.nodeModules.filter { isProtected($0) || FileManager.default.fileExists(atPath: $0) }
        return out
    }

    /// Nil when Spotlight can't run the queries or isn't indexing the home folder: with indexing
    /// off it answers every query with nothing, which would hide every large file and project.
    func spotlightIndex() -> HomeIndex? {
        let standard = ["Desktop", "Documents", "Downloads", "Library"].map { "kMDItemFSName == \"\($0)\"" }.joined(separator: " || ")
        guard let probe = Spotlight.query(standard, scope: home), !probe.isEmpty else { return nil }
        let queries = ["kMDItemFSSize >= \(largeFileBytes)",
                       Self.projectMarkers.map { "kMDItemFSName == \"\($0)\"" }.joined(separator: " || "),
                       "kMDItemFSName == \"node_modules\""]
        var results = [[MDItem]?](repeating: nil, count: queries.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: queries.count) { i in
            let r = Spotlight.query(queries[i], scope: home)
            lock.lock(); results[i] = r; lock.unlock()
        }
        guard let big = results[0], let markers = results[1], let nodeModules = results[2] else { return nil }
        let homePath = Self.realPath(home.path)
        return HomeIndex(
            big: big.compactMap { item in
                guard let path = Spotlight.string(item, kMDItemPath) else { return nil }
                let size = (Spotlight.number(item, "kMDItemPhysicalSize" as CFString) ?? Spotlight.number(item, kMDItemFSSize)).map(Int64.init) ?? 0
                let opened = [Spotlight.date(item, kMDItemLastUsedDate), Spotlight.date(item, kMDItemFSContentChangeDate)].compactMap { $0 }.max()
                return HomeIndex.Big(path: path, size: size, opened: opened)
            },
            markers: markers.compactMap { Spotlight.string($0, kMDItemPath) },
            nodeModules: nodeModules.compactMap { Spotlight.string($0, kMDItemPath) }.filter { path in
                guard path.hasPrefix(homePath + "/"), !isProtected(path) else { return false }
                let parts = path.dropFirst(homePath.count + 1).split(separator: "/")
                return parts.count <= maxNodeModulesDepth && !["Library", "Applications"].contains(parts[0])
                    && !parts.contains(where: { $0.hasPrefix(".") }) && parts.dropLast().allSatisfy({ $0 != "node_modules" })
            })
    }

    /// The same index by walking the home folder (outside ~/Library, ~/Applications, hidden
    /// folders, packages and build output). Each folder is read with one `getattrlistbulk` call
    /// and subfolders are walked in parallel: about 10× faster than FileManager's enumerator.
    func walkIndex(isCancelled: () -> Bool) -> HomeIndex {
        let root = Self.realPath(home.path)
        var index = HomeIndex()
        let skipTop: Set<String> = avoidProtectedFolders ? ["Library", "Applications", "Desktop", "Documents", "Downloads"] : ["Library", "Applications"]
        let markerStarts = Set(Self.projectMarkers.map { $0.utf8.first! }), markerLengths = Set(Self.projectMarkers.map(\.utf8.count))
        let lock = NSLock()
        Self.walkFolders([root], isCancelled: isCancelled) { _, path, depth, fd, buf in
            var big: [HomeIndex.Big] = [], markers: [String] = [], modules: [String] = [], subdirs: [String] = []
            Self.forEachEntry(fd, buffer: buf) { namePtr, type, allocated in
                guard namePtr[0] != 0x2E else { return } // hidden ("." names)
                if type == VREG.rawValue {
                    if allocated >= largeFileBytes {
                        let file = path + "/" + String(cString: namePtr)
                        var st = stat()
                        let opened = lstat(file, &st) == 0
                            ? Date(timeIntervalSince1970: TimeInterval(max(st.st_atimespec.tv_sec, st.st_mtimespec.tv_sec))) : nil
                        big.append(.init(path: file, size: allocated, opened: opened))
                    }
                    // Most files can't be a marker by their first letter and length, so no String is made for them.
                    if markerStarts.contains(UInt8(bitPattern: namePtr[0])), markerLengths.contains(strlen(namePtr)) {
                        let name = String(cString: namePtr)
                        if Self.projectMarkers.contains(name) { markers.append(path + "/" + name) }
                    }
                } else if type == VDIR.rawValue {
                    let name = String(cString: namePtr)
                    if depth == 0 && skipTop.contains(name) { return }
                    let child = path + "/" + name
                    if name == "node_modules" && depth + 1 <= maxNodeModulesDepth { modules.append(child) }
                    if Self.artifacts[name] != nil { return } // build output never holds a project of its own
                    if name.contains("."), (try? URL(fileURLWithPath: child).resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return }
                    subdirs.append(child)
                }
            }
            if !big.isEmpty || !markers.isEmpty || !modules.isEmpty {
                lock.lock(); index.big += big; index.markers += markers; index.nodeModules += modules; lock.unlock()
            }
            return subdirs
        }
        return index
    }

    func filterIndex(_ r: HomeIndex, excluding claimed: [String], skipFiles: Set<String>) -> (largeFiles: [DiskItem], projects: Set<String>) {
        let homePath = Self.realPath(home.path)
        let library = homePath + "/Library/", apps = homePath + "/Applications/"
        let claimedDirs = claimed.map { Self.realPath($0) + "/" }
        func usable(_ path: String) -> Bool {
            guard path.hasPrefix(homePath + "/"), !path.hasPrefix(library), !path.hasPrefix(apps),
                  !claimedDirs.contains(where: path.hasPrefix) else { return false }
            let parts = path.dropFirst(homePath.count + 1).split(separator: "/")
            return !parts.contains { $0.hasPrefix(".") || Self.artifacts[String($0)] != nil }
        }
        let bigPaths = r.big.map(\.path)
        var files: [DiskItem] = []
        for b in r.big where b.size >= largeFileBytes && usable(b.path) && !skipFiles.contains(b.path)
            && !bigPaths.contains(where: { $0 != b.path && b.path.hasPrefix($0 + "/") }) { // inside a bigger bundle
            if let d = largeFileItem(URL(fileURLWithPath: b.path), size: b.size, opened: b.opened) { files.append(d) }
        }
        let projects = Set(r.markers.filter(usable).map { ($0 as NSString).deletingLastPathComponent })
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
    /// `listed` holds folders another step already found (node_modules), so they aren't listed twice.
    func buildArtifacts(in projects: Set<String>, listed: Set<String> = [], isCancelled: () -> Bool) -> [DiskItem] {
        let fm = FileManager.default
        // Each project costs a few small reads, so they're checked side by side (1,500 projects: 4 s → under 1 s).
        let roots = projects.sorted()
        var perProject = [[(dir: URL, make: (Int64) -> DiskItem)]](repeating: [], count: roots.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            guard !isCancelled() else { return }
            let root = URL(fileURLWithPath: roots[i])
            let activity = lastActivity(ofProject: root)
            if isActive(activity) { return } // live project
            var found: [(dir: URL, make: (Int64) -> DiskItem)] = []
            for (folder, rebuild) in Self.artifacts {
                let dir = root.appendingPathComponent(folder)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, !listed.contains(Self.realPath(dir.path)) else { continue }
                let written = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if isActive(written) { continue } // a build may be running
                let idle = daysSince(activity).map { "\(HumanFormat.duration(minutes: $0 * 1440)) ago" } ?? "a long time ago"
                found.append((dir, { DiskItem(name: "\(root.lastPathComponent) › \(folder)", path: dir.path, bytes: $0, kind: .buildArtifact,
                                              reason: "Project last changed \(idle). These are build or dependency files; they come back with \(rebuild)",
                                              lastOpened: activity, lastModified: written) }))
            }
            lock.lock(); perProject[i] = found; lock.unlock()
        }
        let candidates = perProject.flatMap { $0 }
        let sizes = sizes(candidates.map(\.dir), isCancelled: isCancelled)
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
        let sizes = sizes(out.map { URL(fileURLWithPath: $0.path) }, isCancelled: isCancelled)
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
        let sizes = sizes(old.map(\.url), isCancelled: { false })
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

    /// The newest modification date of a folder and what's directly inside it (one level, so it's
    /// cheap; installs and cache writes nearly always touch that level). A file's own date for a file.
    static func lastModified(_ url: URL) -> Date? {
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        let own = try? url.resourceValues(forKeys: key).contentModificationDate
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(key))) ?? []
        return ([own] + children.map { try? $0.resourceValues(forKeys: key).contentModificationDate }).compactMap { $0 }.max()
    }

    /// Where a command-line tool is installed, looking where Homebrew and Xcode put them
    /// (an app started from Finder doesn't get your shell's PATH).
    public static func findTool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Device folders from `xcrun simctl list devices unavailable -j`; empty if simctl can't run.
    public static func listUnavailableSimulators() -> [URL] {
        guard let xcrun = findTool("xcrun"),
              let out = try? ToolRunner.run([xcrun, "simctl", "list", "devices", "unavailable", "-j"], timeout: 20),
              out.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(out.output.utf8)) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return [] }
        // dataPath is <device folder>/data.
        return runtimes.values.joined().compactMap { ($0["dataPath"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent() } }
    }

    /// Space a file or folder takes on disk. See `allocatedSizes`.
    public static func allocatedSize(_ url: URL) -> Int64 { allocatedSizes([url.path])[0] }

    /// Space each file or folder takes on disk. Folders are read with `getattrlistbulk`, which
    /// returns a whole directory's sizes in one call instead of one `stat` per file, and every
    /// folder of every tree goes through one shared set of workers, so one huge tree is spread
    /// across all of them. `onEach` gets each total (from any thread) as soon as that tree is done.
    static func allocatedSizes(_ paths: [String], isCancelled: () -> Bool = { false }, onEach: (Int, Int64) -> Void = { _, _ in }) -> [Int64] {
        var totals = [Int64](repeating: 0, count: paths.count)
        var folders: [Int] = []
        for (i, path) in paths.enumerated() {
            var st = stat()
            if lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR { folders.append(i) } else {
                totals[i] = ftsSize(path) // a file, a link or unreadable
                onEach(i, totals[i])
            }
        }
        let lock = NSLock()
        walkFolders(folders.map { paths[$0] }, isCancelled: isCancelled, visit: { root, path, _, fd, buf in
            var sum: Int64 = 0, subdirs: [String] = []
            forEachEntry(fd, buffer: buf) { namePtr, type, allocated in
                sum += allocated
                if type == VDIR.rawValue { subdirs.append(path + "/" + String(cString: namePtr)) }
            }
            lock.lock(); totals[folders[root]] += sum; lock.unlock()
            return subdirs
        }, finished: { root in
            lock.lock(); let total = totals[folders[root]]; lock.unlock()
            onEach(folders[root], total)
        })
        return totals
    }

    /// Reads many folder trees with one fixed set of workers sharing a list of folders still to
    /// read. `visit` gets a folder's tree (index into `roots`), path, depth below its root, open
    /// descriptor and a reusable `bulkBufferSize` buffer, and returns the subfolders to read next.
    /// `finished` is called once per tree when every folder in it has been read.
    /// Splitting the work per folder instead (nested concurrentPerform) ran 2-5x slower on a busy Mac.
    static func walkFolders(_ roots: [String], isCancelled: () -> Bool,
                            visit: (Int, String, Int, Int32, UnsafeMutableRawPointer) -> [String],
                            finished: (Int) -> Void = { _ in }) {
        guard !roots.isEmpty else { return }
        var pending: [(root: Int, path: String, depth: Int)] = roots.indices.reversed().map { ($0, roots[$0], 0) }
        var left = [Int](repeating: 1, count: roots.count) // folders in each tree not read yet
        var busy = 0
        let more = NSCondition()
        withoutActuallyEscaping(isCancelled) { isCancelled in
            withoutActuallyEscaping(visit) { visit in
                withoutActuallyEscaping(finished) { finished in
                    DispatchQueue.concurrentPerform(iterations: max(4, ProcessInfo.processInfo.activeProcessorCount)) { _ in
                        let buf = UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: 8)
                        defer { buf.deallocate() }
                        while true {
                            more.lock()
                            while pending.isEmpty && busy > 0 { more.wait() }
                            guard let next = pending.popLast(), !isCancelled() else {
                                pending.removeAll(); more.broadcast(); more.unlock(); return
                            }
                            busy += 1
                            more.unlock()
                            let fd = open(next.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                            var subdirs: [String] = []
                            if fd >= 0 { subdirs = visit(next.root, next.path, next.depth, fd, buf); close(fd) }
                            more.lock()
                            pending += subdirs.map { (next.root, $0, next.depth + 1) }
                            left[next.root] += subdirs.count - 1
                            let done = left[next.root] == 0
                            busy -= 1
                            more.broadcast()
                            more.unlock()
                            if done { finished(next.root) }
                        }
                    }
                }
            }
        }
    }

    static let bulkBufferSize = 64 * 1024

    /// Calls `body` with each entry of an open folder: its name, type (VREG, VDIR, …) and, for a
    /// file, the space it takes (0 otherwise). One `getattrlistbulk` call returns many entries.
    /// `buffer` (at least `bulkBufferSize` bytes) can be reused across calls; nil allocates one.
    static func forEachEntry(_ dirFD: Int32, buffer: UnsafeMutableRawPointer? = nil, _ body: (UnsafePointer<CChar>, fsobj_type_t, Int64) -> Void) {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
        attrs.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        let buf = buffer ?? UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: 8)
        defer { if buffer == nil { buf.deallocate() } }
        while true {
            let n = getattrlistbulk(dirFD, &attrs, buf, bulkBufferSize, 0)
            if n <= 0 { break }
            var entry = buf
            for _ in 0..<n {
                // Entries are packed on 4-byte boundaries, so read every field unaligned.
                let length = entry.loadUnaligned(as: UInt32.self)
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePtr = UnsafePointer((field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size
                let allocated = type == VREG.rawValue && returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0
                    ? field.loadUnaligned(as: Int64.self) : 0
                body(namePtr, type, allocated)
                entry += Int(length)
            }
        }
    }

    /// The same total via fts (what `du` uses), for single files or when a folder can't be opened directly.
    static func ftsSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        path.withCString { p in
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

    /// Sizes many folders at once, reusing remembered sizes when allowed.
    func sizes(_ urls: [URL], isCancelled: () -> Bool, onEach: (Int, Int64) -> Void = { _, _ in }) -> [Int64] {
        var sizes = [Int64](repeating: 0, count: urls.count)
        guard !urls.isEmpty, !isCancelled() else { return sizes }
        var measure: [Int] = []
        for (i, url) in urls.enumerated() {
            if let known = sizeCache?.remembered(url, now: now) { sizes[i] = known; onEach(i, known) } else { measure.append(i) }
        }
        let measured = Self.allocatedSizes(measure.map { urls[$0].path }, isCancelled: isCancelled) { j, size in
            sizeCache?.remember(urls[measure[j]], bytes: size, now: now)
            onEach(measure[j], size)
        }
        for (j, i) in measure.enumerated() { sizes[i] = measured[j] }
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

/// 3) Sizes remembered between scans. A folder is re-measured only if it was last measured
/// more than `maxAge` ago or its own modification time changed (something was added, removed
/// or renamed directly inside it). Deeper changes show up within `maxAge` or on a Rescan,
/// which sets `reuse` to false so everything is measured fresh (and remembered again).
public final class SizeCache {
    struct Entry: Codable {
        var bytes: Int64
        var mtimeSec: Int
        var mtimeNsec: Int
        var measuredAt: Date
    }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    public var maxAge: TimeInterval = 6 * 3600
    public var reuse = true
    public private(set) var hits = 0

    public init() {}

    /// Loads sizes saved by an earlier run, so a relaunch or reboot doesn't mean re-measuring everything.
    public convenience init(contentsOf url: URL) {
        self.init()
        if let data = try? Data(contentsOf: url),
           let saved = try? HabitStore.decoder.decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    public func save(to url: URL) {
        lock.lock(); let snapshot = entries; lock.unlock()
        if let data = try? HabitStore.encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func lastKnownSize(_ path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return entries[path]?.bytes
    }

    func size(of url: URL, now: Date, measure: (URL) -> Int64) -> Int64 {
        if let known = remembered(url, now: now) { return known }
        let bytes = measure(url)
        remember(url, bytes: bytes, now: now)
        return bytes
    }

    /// The remembered size, if it's still good for `url`.
    func remembered(_ url: URL, now: Date) -> Int64? {
        var st = stat()
        guard reuse, lstat(url.path, &st) == 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let c = entries[url.path], now.timeIntervalSince(c.measuredAt) < maxAge,
              c.mtimeSec == st.st_mtimespec.tv_sec, c.mtimeNsec == st.st_mtimespec.tv_nsec else { return nil }
        hits += 1
        return c.bytes
    }

    /// Note a size just measured. The folder's modification time is read now, right after measuring.
    func remember(_ url: URL, bytes: Int64, now: Date) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        lock.lock()
        entries[url.path] = Entry(bytes: bytes, mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec, measuredAt: now)
        lock.unlock()
    }
}

/// The last walk of the home folder (large files, projects, node_modules), so a refresh doesn't
/// walk it again: about 7 s on a home folder of 1.75 million files, against a few milliseconds to
/// re-check what it found. Reused for `maxAge`; new large files and projects show up after that or on
/// a Rescan, which sets `reuse` to false.
public final class HomeWalkCache {
    struct Key: Codable, Equatable {
        var root: String
        var largeFileBytes: Int64
        var maxNodeModulesDepth: Int
        /// Whether the walk read Desktop, Documents and Downloads.
        var coversProtected: Bool
    }
    struct Saved: Codable {
        var key: Key
        var index: DiskScanner.HomeIndex
        var walkedAt: Date
    }
    private var saved: Saved?
    private let lock = NSLock()
    public var maxAge: TimeInterval = 6 * 3600
    public var reuse = true

    public init() {}

    /// Loads the walk saved by an earlier run, so a relaunch doesn't mean walking again.
    public convenience init(contentsOf url: URL) {
        self.init()
        if let data = try? Data(contentsOf: url) { saved = try? HabitStore.decoder.decode(Saved.self, from: data) }
    }

    public func save(to url: URL) {
        lock.lock(); let snapshot = saved; lock.unlock()
        if let snapshot, let data = try? HabitStore.encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }

    /// The last walk, if it was made the same way and recently enough. One that read the protected
    /// folders also serves a scan that stays out of them, not the other way round.
    func reusable(_ key: Key, now: Date) -> DiskScanner.HomeIndex? {
        lock.lock(); defer { lock.unlock() }
        guard reuse, let s = saved, now.timeIntervalSince(s.walkedAt) < maxAge, s.key.root == key.root,
              s.key.largeFileBytes == key.largeFileBytes, s.key.maxNodeModulesDepth == key.maxNodeModulesDepth,
              s.key.coversProtected || !key.coversProtected else { return nil }
        return s.index
    }

    func store(_ index: DiskScanner.HomeIndex, key: Key, now: Date) {
        lock.lock(); saved = Saved(key: key, index: index, walkedAt: now); lock.unlock()
    }
}

/// Runs a command-line tool and collects what it prints (output and errors together).
public enum ToolRunner {
    public struct Timeout: Error {}

    /// Gives up after `timeout` seconds, stopping the tool, so a stuck one can't hang a scan or a cleanup.
    public static func run(_ argv: [String], timeout: TimeInterval) throws -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: argv[0])
        task.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        try task.run()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            throw Timeout()
        }
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
