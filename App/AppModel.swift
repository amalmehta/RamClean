import AppKit
import Combine
import CoreGraphics
import RamCleanCore

/// The running brain of the app: samples every few seconds, keeps the habit log,
/// scores apps, sends suggestions and carries out your answers.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var system: SystemSnapshot?
    @Published private(set) var assessments: [Assessment] = []
    @Published private(set) var modelStatus = ModelStatus()
    @Published private(set) var events: [HabitEvent] = []
    @Published private(set) var habits: [AppHabit] = []
    @Published private(set) var awaitingForceQuit: Set<String> = []
    @Published private(set) var isTraining = false
    @Published private(set) var diskReport: DiskReport?
    @Published private(set) var diskScanStep: String?
    /// Paths being moved off the Mac right now.
    @Published private(set) var movingPaths: Set<String> = []
    /// Set by "Show recommendations" on an alert; the Overview opens that bar's list.
    @Published var requestedPanel: UsagePanel?
    /// Opens the main window; provided by a SwiftUI view that has `openWindow`.
    var openMainWindow: (() -> Void)?
    @Published var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            Self.savePrefs(prefs)
            thresholds.prefs = prefs
            if prefs.checkInterval != oldValue.checkInterval { scheduleTimer() }
            tick()
        }
    }

    let dataDirectory: URL
    let habitStore: HabitStore
    let model: DeadweightModel
    let notifier = Notifier()
    /// Folder sizes remembered between disk scans (and app launches, via sizes.json), so
    /// refreshes only re-measure what changed.
    let sizeCache: SizeCache

    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private var cpuHistory = CPUHistory()
    private var timer: Timer?
    private var frontmost: (key: String, name: String)?
    private var lastCredit = Date()
    private var lastNotified: [String: Date] = [:]
    private var lastAnyNotification: Date?
    private lazy var thresholds = ThresholdMonitor(prefs: prefs)
    /// The disk alert waits for a fresh scan so it can name what to clear.
    private var diskAlertWaitingForScan = false
    /// Apps RamClean quit, and when — for force-quit follow-ups and "regret" relabelling.
    private var quitByUs: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDirectory = base.appendingPathComponent("RamClean", isDirectory: true)
        habitStore = HabitStore(directory: dataDirectory)
        model = DeadweightModel(directory: dataDirectory)
        prefs = Self.loadPrefs()
        sizeCache = SizeCache(contentsOf: dataDirectory.appendingPathComponent("sizes.json"))
        // Last disk scan, so "What to clear" opens instantly; it refreshes in the background.
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("disk-report.json")),
           let saved = try? HabitStore.decoder.decode(DiskReport.self, from: data) {
            diskReport = saved
        }
        modelStatus = model.status
        events = habitStore.recentEvents
    }

    func start() {
        guard !started else { return }
        started = true
        notifier.onAction = { [weak self] action, info in self?.handle(action, info: info) }
        notifier.setUp()
        observeWorkspace()
        if let app = NSWorkspace.shared.frontmostApplication { frontmost = (Self.key(app), app.localizedName ?? "") }
        retrain()
        tick()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(5, prefs.checkInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Sampling

    func tick() {
        let now = Date()
        creditForeground(now: now)

        let snapshot = systemSampler.sample()
        let procs = processSampler.sample()
        let running = NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "",
                           bundlePath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular)
        }
        let groups = AppGrouper.group(procs, apps: running)
        let averages = cpuHistory.record(groups)
        let assessor = Assessor(prefs: prefs, frontmostKey: frontmost?.key, selfBundleID: Bundle.main.bundleIdentifier,
                                audioPIDs: AudioActivity.pidsPlayingAudio(), cpuAverages: averages, now: now)
        let store = habitStore, model = model
        let result = assessor.assess(groups, stats: { store.stats(for: $0, now: now) }, score: { model.score($0) })

        system = snapshot
        assessments = result
        habits = habitStore.habits.values.sorted { lhs, rhs in
            (habitStore.stats(for: lhs.key, now: now).avgDailyMinutes14d) > (habitStore.stats(for: rhs.key, now: now).avgDailyMinutes14d)
        }
        habitStore.save(now: now)

        let policy = SuggestionPolicy(prefs: prefs)
        if let pick = policy.pick(from: result, system: snapshot, lastNotified: lastNotified,
                                  lastAnyNotification: lastAnyNotification, now: now) {
            suggest(pick, system: snapshot, now: now)
        }
        checkThresholds(snapshot, result, now: now)
    }

    /// Credits the frontmost app with the time since the last tick — but only while
    /// you're actually at the Mac (input in the last 2 minutes).
    private func creditForeground(now: Date) {
        defer { lastCredit = now }
        guard let f = frontmost else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 120 else { return }
        habitStore.creditForeground(key: f.key, name: f.name, seconds: min(now.timeIntervalSince(lastCredit), 120), at: now)
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        func app(_ n: Notification) -> NSRunningApplication? { n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = app(n) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.creditForeground(now: Date())
                self.frontmost = (Self.key(a), a.localizedName ?? "")
                self.habitStore.markActive(key: Self.key(a), name: a.localizedName ?? "", at: Date())
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = app(n) else { return }
            Task { @MainActor in self?.launched(a) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = app(n) else { return }
            Task { @MainActor in
                guard let self else { return }
                let key = Self.key(a)
                self.awaitingForceQuit.remove(key)
                if a.activationPolicy == .regular {
                    self.habitStore.log(.terminated, key: key, name: a.localizedName ?? "", at: Date())
                    self.refreshEvents()
                }
            }
        })
    }

    private func launched(_ a: NSRunningApplication) {
        guard a.activationPolicy == .regular else { return }
        let key = Self.key(a), name = a.localizedName ?? key, now = Date()
        habitStore.recordLaunch(key: key, name: name, at: now)
        // Reopened within 30 minutes of RamClean quitting it: that was the wrong call.
        if let quitAt = quitByUs[key], now.timeIntervalSince(quitAt) < 30 * 60 {
            quitByUs[key] = nil
            habitStore.recordDecision(.regretRelaunch, key: key, name: name, detail: "Reopened \(Int(now.timeIntervalSince(quitAt) / 60)) min after RamClean quit it", at: now)
            model.relabelLatest(key: key, since: quitAt.addingTimeInterval(-60), to: .keep)
            retrain()
        }
        refreshEvents()
    }

    // MARK: - Suggestions and answers

    private func suggest(_ a: Assessment, system s: SystemSnapshot, now: Date) {
        lastNotified[a.group.habitKey] = now
        lastAnyNotification = now
        let idle = Format.duration(minutes: a.features.minutesSinceActive)
        var body = "Using \(Format.bytes(a.group.memoryBytes))"
        if a.cpuAverage >= 5 { body += " and \(Int(a.cpuAverage))% CPU" }
        body += ". Last used \(idle) ago. Looks like deadweight (\(Int(a.score * 100))%)."
        if SuggestionPolicy(prefs: prefs).memoryIsTight(s) { body += " Memory is \(Int(s.memoryUsedFraction * 100))% full." }
        notifier.suggest(key: a.group.habitKey, name: a.group.name, body: body)
        habitStore.log(.suggested, key: a.group.habitKey, name: a.group.name, detail: "score \(Int(a.score * 100))%, \(Format.bytes(a.group.memoryBytes))", at: now)
        refreshEvents()
    }

    func handle(_ action: Notifier.Action, info: [AnyHashable: Any]) {
        let key = info["key"] as? String ?? ""
        let resource = (info["resource"] as? String).flatMap(Resource.init(rawValue:))
        switch action {
        case .quit: quit(key: key, source: "notification")
        case .keep: keep(key: key, always: false, source: "notification")
        case .alwaysKeep: keep(key: key, always: true, source: "notification")
        case .forceQuit: forceQuit(key: key)
        case .alertFix: applyAlertFix(info)
        case .alertShow: if let resource { showRecommendations(resource) }
        case .alertSnooze:
            if let resource {
                thresholds.snooze(resource, until: Date().addingTimeInterval(3600))
                habitStore.log(.thresholdAlert, key: resource.rawValue, name: resource.title, detail: "snoozed for an hour", at: Date())
                refreshEvents()
            }
        case .open:
            if let resource { showRecommendations(resource) } else { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: - Threshold alerts

    private func checkThresholds(_ s: SystemSnapshot, _ list: [Assessment], now: Date) {
        for r in thresholds.update(s, now: now) {
            switch r {
            case .memory: sendAlert(AlertRecommender.memory(s, list))
            case .cpu: sendAlert(AlertRecommender.cpu(s, list))
            case .disk:
                // Use a scan from the last 6 hours, or run one and alert when it's done.
                if let report = diskReport, diskScanStep == nil, now.timeIntervalSince(report.scannedAt) < 6 * 3600 {
                    sendAlert(AlertRecommender.disk(s, report))
                } else {
                    diskAlertWaitingForScan = true
                    scanDisk(byUser: false)
                }
            }
        }
    }

    private func sendAlert(_ content: AlertContent) {
        notifier.alert(content)
        lastAnyNotification = Date()
        habitStore.log(.thresholdAlert, key: content.resource.rawValue, name: content.title, detail: content.body, at: Date())
        refreshEvents()
    }

    /// The one-tap fix from an alert: quit the top app, or trash the biggest rebuildable cache.
    private func applyAlertFix(_ info: [AnyHashable: Any]) {
        guard let kind = (info["fixKind"] as? String).flatMap(AlertAction.Kind.init(rawValue:)),
              let target = info["fixTarget"] as? String else { return }
        switch kind {
        case .quit: quit(key: target, source: "alert")
        case .trash:
            let item = diskReport?.items.first { $0.path == target }
                ?? DiskItem(name: (target as NSString).lastPathComponent, path: target, bytes: nil, kind: .cache, reason: "")
            if let error = moveToTrash(item) { notifier.problem("Couldn't move \(item.name) to the Trash", error) }
        }
    }

    func showRecommendations(_ r: Resource) {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        requestedPanel = UsagePanel(rawValue: r.rawValue)
    }

    func quit(key: String, source: String) {
        let apps = Self.runningApps(key)
        guard !apps.isEmpty else { return }
        let name = apps[0].localizedName ?? key
        let now = Date()
        record(key: key, label: .deadweight, source: source)
        habitStore.recordDecision(.quitBySuggestion, key: key, name: name, detail: "from \(source)", at: now)
        quitByUs[key] = now
        apps.forEach { $0.terminate() }
        refreshEvents()

        DispatchQueue.main.asyncAfter(deadline: .now() + prefs.forceQuitAfterSeconds) { [weak self] in
            guard let self, !Self.runningApps(key).isEmpty else { return }
            self.awaitingForceQuit.insert(key)
            self.notifier.offerForceQuit(key: key, name: name)
        }
    }

    func forceQuit(key: String) {
        let apps = Self.runningApps(key)
        apps.forEach { $0.forceTerminate() }
        awaitingForceQuit.remove(key)
        if let name = apps.first?.localizedName {
            habitStore.log(.forceQuit, key: key, name: name, at: Date())
            refreshEvents()
        }
    }

    func keep(key: String, always: Bool, source: String) {
        let name = assessments.first { $0.group.habitKey == key }?.group.name ?? habitStore.habits[key]?.name ?? key
        record(key: key, label: .keep, source: source)
        habitStore.recordDecision(always ? .alwaysKept : .kept, key: key, name: name, detail: "from \(source)", at: Date())
        if always, !prefs.alwaysKeep.contains(key) { prefs.alwaysKeep.append(key) }
        lastNotified[key] = Date()
        refreshEvents()
    }

    private func record(key: String, label: Label, source: String) {
        guard let a = assessments.first(where: { $0.group.habitKey == key }) else { return }
        model.add(TrainingExample(date: Date(), features: a.features, label: label, source: source))
        modelStatus = model.status
        retrain()
    }

    func retrain() {
        isTraining = true
        let model = model
        DispatchQueue.global(qos: .utility).async {
            let status = model.train()
            DispatchQueue.main.async {
                self.modelStatus = status
                self.isTraining = false
            }
        }
    }

    // MARK: - Disk

    /// Scans in the background; the UI shows `diskScanStep` until it's done.
    /// `byUser` is true when you opened the Disk list or pressed Rescan: only then may the scan
    /// read Desktop, Documents and Downloads for the first time, since that can raise a macOS
    /// permission prompt that would otherwise stall a background scan until someone answers it.
    /// `fresh` (the Rescan button) measures every folder again instead of reusing remembered sizes.
    func scanDisk(byUser: Bool = true, fresh: Bool = false) {
        guard diskScanStep == nil else { return }
        sizeCache.reuse = !fresh
        diskScanStep = "starting"
        let askedKey = "RamCleanScannedProtectedFolders"
        var scanner = DiskScanner()
        scanner.avoidProtectedFolders = !byUser && !UserDefaults.standard.bool(forKey: askedKey)
        scanner.sizeCache = sizeCache
        scanner.staleDays = prefs.staleDays
        scanner.activeDays = prefs.activeDays
        let keep = prefs
        scanner.isKept = { keep.matches(keep.alwaysKeep + keep.workTools, $0) }
        scanner.runningAppPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        // With earlier results on screen, keep showing them until the new scan is done;
        // on a first scan, show results as they arrive.
        let firstScan = diskReport == nil
        // Results stream in per folder; redraw at most 4 times a second so the list stays smooth.
        let lastPublish = NSLock()
        var publishedAt = Date.distantPast
        DispatchQueue.global(qos: .utility).async {
            let report = scanner.scan(progress: { step, found in
                lastPublish.lock()
                let due = Date().timeIntervalSince(publishedAt) >= 0.25
                if due { publishedAt = Date() }
                lastPublish.unlock()
                guard due else { return }
                let partial = DiskReport(items: found.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }, scannedAt: Date())
                DispatchQueue.main.async {
                    self.diskScanStep = step
                    if firstScan && !found.isEmpty { self.diskReport = partial }
                }
            })
            DispatchQueue.main.async {
                if byUser { UserDefaults.standard.set(true, forKey: askedKey) }
                self.diskReport = report
                self.saveDiskReport()
                self.diskScanStep = nil
                if self.diskAlertWaitingForScan, let s = self.system {
                    self.diskAlertWaitingForScan = false
                    self.sendAlert(AlertRecommender.disk(s, report))
                }
            }
        }
    }

    /// Moves an item to the Trash (recoverable until you empty it). Returns an error message on failure.
    func moveToTrash(_ item: DiskItem) -> String? {
        guard item.canTrash else { return "RamClean doesn't remove this one itself." }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
        } catch {
            return error.localizedDescription
        }
        habitStore.log(.movedToTrash, key: "disk", name: item.name,
                       detail: "\(Format.bytes(UInt64(max(0, item.bytes ?? 0)))) · \(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))",
                       at: Date())
        diskReport?.items.removeAll { $0.id == item.id }
        saveDiskReport()
        refreshEvents()
        tick()
        return nil
    }

    private func saveDiskReport() {
        guard let r = diskReport, let data = try? HabitStore.encoder.encode(r) else { return }
        try? data.write(to: dataDirectory.appendingPathComponent("disk-report.json"), options: .atomic)
        sizeCache.save(to: dataDirectory.appendingPathComponent("sizes.json"))
    }

    /// Drives you can move big files to (external and network volumes, not this Mac's own disk).
    static func externalVolumes() -> [(name: String, url: URL, free: Int64)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
                                      .volumeIsReadOnlyKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true,
                  v.volumeIsInternal != true, v.volumeIsBrowsable != false, v.volumeIsReadOnly != true else { return nil }
            return (v.volumeName ?? url.lastPathComponent, url, Int64(v.volumeAvailableCapacity ?? 0))
        }
    }

    /// Moves a file off this Mac into `folder` (e.g. an external drive). It's copied, then
    /// removed here only once the copy succeeded. Calls back on the main thread with an error message or nil.
    func move(_ item: DiskItem, to folder: URL, done: @escaping (String?) -> Void) {
        let source = URL(fileURLWithPath: item.path)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).flatMap { $0 }
        if let free, let size = item.bytes, Int64(free) < size + 100 * 1_048_576 {
            done("\(folder.lastPathComponent) only has \(Format.bytes(UInt64(free))) free; \(item.name) needs \(Format.bytes(UInt64(size))).")
            return
        }
        var dest = folder.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        movingPaths.insert(item.path)
        let target = dest
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try FileManager.default.moveItem(at: source, to: target) } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.movingPaths.remove(item.path)
                if failure == nil {
                    self.habitStore.log(.movedOffMac, key: "disk", name: item.name,
                                        detail: "\(Format.bytes(UInt64(max(0, item.bytes ?? 0)))) → \(target.path)", at: Date())
                    self.diskReport?.items.removeAll { $0.id == item.id }
                    self.saveDiskReport()
                    self.refreshEvents()
                    self.tick()
                }
                done(failure)
            }
        }
    }

    func resetModel() {
        model.reset()
        modelStatus = model.status
    }

    func clearHabits() {
        habitStore.clear()
        habits = []
        events = []
    }

    private func refreshEvents() { events = habitStore.recentEvents }

    // MARK: - Helpers

    static func key(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
    }

    static func runningApps(_ key: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { Self.key($0) == key && !$0.isTerminated }
    }

    private static let prefsKey = "RamCleanPreferences"
    private static func loadPrefs() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let p = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return p
    }
    private static func savePrefs(_ p: Preferences) {
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: prefsKey) }
    }
}

enum Format {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
    static func duration(minutes m: Double) -> String { HumanFormat.duration(minutes: m) }
}
