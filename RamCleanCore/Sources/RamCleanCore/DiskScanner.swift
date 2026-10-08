import Foundation

/// Something on disk worth a look, and why.
public struct DiskItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case cache, largeFile, trash

        public var title: String {
            switch self {
            case .cache: return "Rebuildable caches"
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
    public var id: String { path }

    public init(name: String, path: String, bytes: Int64?, kind: Kind, reason: String, caution: String? = nil,
                canTrash: Bool = true, lastOpened: Date? = nil) {
        self.name = name; self.path = path; self.bytes = bytes; self.kind = kind; self.reason = reason
        self.caution = caution; self.canTrash = canTrash; self.lastOpened = lastOpened
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
/// a separate, confirmed Move to Trash in the app.
public struct DiskScanner {
    public var home: URL
    public var minCacheBytes: Int64 = 200 * 1_048_576
    public var largeFileBytes: Int64 = 1_073_741_824
    public var maxLargeFiles = 30

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

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

        progress("large files in your home folder", items)
        items += largeFiles(excluding: claimed, isCancelled: isCancelled)

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

    func largeFiles(excluding claimed: [String], isCancelled: () -> Bool) -> [DiskItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .contentAccessDateKey]
        // Compare resolved paths: the enumerator reports them with symlinks resolved.
        let root = URL(fileURLWithPath: Self.realPath(home.path), isDirectory: true)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return [] }
        let skip = Set((claimed.map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Library")])
            .map { Self.realPath($0.path) })
        var found: [DiskItem] = []
        for case let url as URL in e {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skip.contains(Self.realPath(url.path)) { e.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, let size = v.totalFileAllocatedSize.map(Int64.init), size >= largeFileBytes else { continue }
            found.append(DiskItem(name: url.lastPathComponent, path: url.path, bytes: size, kind: .largeFile,
                                  reason: Self.largeFileReason(url, lastOpened: v.contentAccessDate),
                                  lastOpened: v.contentAccessDate))
        }
        return Array(found.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(maxLargeFiles))
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
