import AppKit
import Combine
import CoreGraphics
import RamCleanCore
import SystemConfiguration

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
    /// Apps asked to quit that haven't exited yet, so their Quit button can show progress.
    @Published private(set) var quitting: Set<String> = []
    /// Apps whose memory has swelled since they started, by key: restarting frees the growth.
    @Published private(set) var grown: [String: MemoryGrowth.Growth] = [:]
    /// Days until the disk reaches its alert line at the current rate, when it's shrinking.
    @Published private(set) var diskFullInDays: Double?
    /// Suggestions and alerts are held until then (from the menu bar: a call, a presentation).
    @Published private(set) var pausedUntil: Date? = UserDefaults.standard.object(forKey: AppModel.pausedKey) as? Date
    var notificationsPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    private static let pausedKey = "RamCleanNotificationsPausedUntil"
    @Published private(set) var isTraining = false
    @Published private(set) var diskReport: DiskReport?
    @Published private(set) var diskScanStep: String?
    /// Paths being moved off the Mac right now.
    @Published private(set) var movingPaths: Set<String> = []
    /// Items whose cleanup command (brew cleanup, simctl delete unavailable) is running.
    @Published private(set) var cleaningPaths: Set<String> = []
    /// Set by "Show recommendations" on an alert; the Overview opens that bar's list.
    @Published var requestedPanel: UsagePanel?
    /// Opens the main window; provided by a SwiftUI view that has `openWindow`.
    var openMainWindow: (() -> Void)?
    /// Opens Settings; provided by a SwiftUI view that has `openSettings`.
    var openSettings: (() -> Void)?
    @Published var settingsTab: SettingsTab = .general
    /// Trial, licensed, offline or expired. Watching always works; acting needs this to unlock.
    @Published private(set) var licence: LicenceState = .salesNotSetUp
    @Published private(set) var licenceRecord: LicenceRecord?
    /// Why the licence was removed at the last check (refunded, deactivated elsewhere), if it was.
    @Published var licenceProblem: String?
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
    /// Apps RamClean quit, followed for 30 minutes to learn whether you wanted them back.
    let kills: KillLedger
    let notifier = Notifier()
    let licensing: Licensing
    /// Folder sizes remembered between disk scans (and app launches, via sizes.json), so
    /// refreshes only re-measure what changed.
    let sizeCache: SizeCache

    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    /// Lives on `samplingQueue` with the samplers.
    private let activeWork = ActiveWorkTracker()
    private var cpuHistory = CPUHistory()
    private var memoryGrowth = MemoryGrowth()
    private var diskHistory: DiskHistory
    private var diskHistoryURL: URL { dataDirectory.appendingPathComponent("disk-history.json") }
    /// Apps being restarted: opened again as soon as they exit.
    private var pendingRelaunch: Set<String> = []
    private static let lastForecastKey = "RamCleanLastDiskForecastAlert"
    /// Reading every process, the system numbers and Core Audio takes 50–150 ms per check
    /// (nearly a second the first time), so it happens here rather than on the main thread.
    private let samplingQueue = DispatchQueue(label: "com.amalmehta.RamClean.sampling", qos: .utility)
    private var sampling = false
    private var timer: Timer?
    private var frontmost: (key: String, name: String)?
    private var lastCredit = Date()
    private var lastNotified: [String: Date] = [:]
    private var lastAnyNotification: Date?
    private lazy var thresholds = ThresholdMonitor(prefs: prefs)
    /// The disk alert waits for a fresh scan so it can name what to clear.
    private var diskAlertWaitingForScan = false
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var checkingLicence = false
    private var lastLicenceAlert = Date.distantPast

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDirectory = base.appendingPathComponent("RamClean", isDirectory: true)
        habitStore = HabitStore(directory: dataDirectory)
        model = DeadweightModel(directory: dataDirectory)
        kills = KillLedger(directory: dataDirectory)
        // Two copies of the trial clock and licence, so deleting preferences doesn't reset the trial.
        licensing = Licensing(config: .ramClean,
                              stores: [KeychainStore(service: "com.amalmehta.RamClean.licence"), DefaultsStore()],
                              http: URLSessionHTTPClient(),
                              instanceName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac")
        prefs = Self.loadPrefs()
        sizeCache = SizeCache(contentsOf: dataDirectory.appendingPathComponent("sizes.json"))
        diskHistory = DiskHistory(contentsOf: dataDirectory.appendingPathComponent("disk-history.json"))
        // Last disk scan, so "What to clear" opens instantly; it refreshes in the background.
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("disk-report.json")),
           let saved = try? HabitStore.decoder.decode(DiskReport.self, from: data) {
            diskReport = saved
        }
        modelStatus = model.status
        events = habitStore.recentEvents
        licence = licensing.state()
        licenceRecord = licensing.record
    }

    func start() {
        guard !started else { return }
        started = true
        notifier.onAction = { [weak self] action, info in self?.handle(action, info: info) }
        notifier.setUp()
        observeWorkspace()
        if let app = NSWorkspace.shared.frontmostApplication { frontmost = (Self.key(app), Self.name(app)) }
        // The model trained last time is reused when there are no new answers since.
        if model.restoredFromDisk { modelStatus = model.status } else { retrain() }
        tick()
        scheduleTimer()
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleTimer() }
        })
    }

    /// In Low Power Mode, checks at most once a minute to save battery.
    private func scheduleTimer() {
        timer?.invalidate()
        var interval = max(5, prefs.checkInterval)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { interval = max(60, interval) }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Sampling

    /// Samples on `samplingQueue`, then judges the results on the main thread. A check that
    /// arrives while one is still sampling is skipped.
    func tick() {
        guard !sampling else { return }
        sampling = true
        let running = NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "",
                           bundlePath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular)
        }
        let systemSampler = systemSampler, processSampler = processSampler, activeWork = activeWork
        samplingQueue.async {
            let snapshot = systemSampler.sample()
            let processes = processSampler.sample()
            let groups = AppGrouper.group(processes, apps: running)
            let audio = AudioActivity.pidsPlayingAudio()
            // Which apps are mid-build, running an agent, playing sound or keeping the Mac awake:
            // worked out here, once per check, so judging on the main thread only looks it up.
            let busy = activeWork.update(groups: groups, processes: processes, assertions: PowerAssertions.read(),
                                         audioPIDs: audio, now: Date())
            Task { @MainActor in self.assess(snapshot, groups, audio: audio, busy: busy) }
        }
    }

    private func assess(_ snapshot: SystemSnapshot, _ groups: [AppGroup], audio: Set<Int32>, busy: [String: ActiveWorkReason]) {
        sampling = false
        let now = Date()
        creditForeground(now: now)
        let averages = cpuHistory.record(groups)
        let assessor = Assessor(prefs: prefs, frontmostKey: frontmost?.key, selfBundleID: Bundle.main.bundleIdentifier,
                                audioPIDs: audio, activeWork: busy, cpuAverages: averages, now: now)
        let store = habitStore, model = model
        let result = assessor.assess(groups, stats: { store.stats(for: $0, now: now) }, score: { model.score($0) })

        system = snapshot
        assessments = result
        // A "Quit?" already on screen is wrong once the app gets busy: take it back.
        let busyKeys = result.compactMap { a -> String? in
            guard case .protected(.busy) = a.verdict, lastNotified[a.group.habitKey] != nil else { return nil }
            return a.group.habitKey
        }
        if !busyKeys.isEmpty { notifier.withdraw(busyKeys.map { "suggest-\($0)" }) }
        memoryGrowth.record(groups, now: now)
        grown = Dictionary(groups.compactMap { g in memoryGrowth.growth(of: g, now: now).map { (g.habitKey, $0) } },
                           uniquingKeysWith: { a, _ in a })
        if diskHistory.record(free: snapshot.diskFree, at: now) { diskHistory.save(to: diskHistoryURL) }
        let floor = Int64(Double(snapshot.diskTotal) * (1 - prefs.diskAlertUsedPercent / 100))
        diskFullInDays = diskHistory.daysUntil(free: floor, now: now)
        if !notificationsPaused { checkDiskForecast(snapshot, now: now) }
        habits = habitStore.habits.values.sorted { lhs, rhs in
            (habitStore.stats(for: lhs.key, now: now).avgDailyMinutes14d) > (habitStore.stats(for: rhs.key, now: now).avgDailyMinutes14d)
        }
        for (r, outcome) in kills.expire(now: now) { resolve(r, outcome, at: now) }
        habitStore.save(now: now)

        if pausedUntil.map({ $0 <= now }) ?? false { resumeNotifications() }
        guard !notificationsPaused else { return }
        let policy = SuggestionPolicy(prefs: prefs)
        if let pick = policy.pick(from: result, system: snapshot, lastNotified: lastNotified,
                                  lastAnyNotification: lastAnyNotification, now: now) {
            suggest(pick, now: now)
        }
        checkThresholds(snapshot, result, now: now)
        updateLicence()
    }

    func pauseNotifications(for seconds: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(seconds)
        UserDefaults.standard.set(pausedUntil, forKey: Self.pausedKey)
    }

    func resumeNotifications() {
        pausedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
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
                self.frontmost = (Self.key(a), Self.name(a))
                self.habitStore.markActive(key: Self.key(a), name: Self.name(a), at: Date())
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
                if self.pendingRelaunch.remove(key) != nil { self.relaunch(key: key) }
                let wasQuitting = self.quitting.remove(key) != nil
                if self.awaitingForceQuit.remove(key) != nil || wasQuitting { self.appExited(key) }
                // Its "Quit?" and "didn't quit" notifications are moot now, however it quit.
                self.notifier.withdraw(["suggest-\(key)", "force-\(key)"])
                if let r = self.kills.noteTerminated(key: key, at: Date()) { self.announceQuit(r) }
                if a.activationPolicy == .regular {
                    self.habitStore.log(.terminated, key: key, name: Self.name(a), at: Date())
                    self.refreshEvents()
                }
            }
        })
    }

    private func launched(_ a: NSRunningApplication) {
        guard a.activationPolicy == .regular else { return }
        let key = Self.key(a), name = Self.name(a), now = Date()
        habitStore.recordLaunch(key: key, name: name, at: now)
        notifier.withdraw(["quit-done-\(key)"]) // nothing left to relaunch
        if let hit = kills.noteLaunch(key: key, at: now) { resolve(hit.record, hit.outcome, at: now) }
        refreshEvents()
    }

    /// A kill's 30-minute window has closed (or you reopened the app sooner): log how it
    /// went, and if you wanted it back, flip that answer to "keep" so the model learns.
    private func resolve(_ r: KillRecord, _ outcome: KillOutcome, at now: Date) {
        let minutes = Int(now.timeIntervalSince(r.killedAt) / 60)
        switch outcome {
        case .relaunched:
            habitStore.recordDecision(.regretRelaunch, key: r.key, name: r.name, detail: "Reopened \(minutes) min after RamClean quit it", at: now)
        case .stayedClosed:
            habitStore.log(.stayedClosed, key: r.key, name: r.name,
                           detail: "Not reopened within \(Int(KillLabeler.regretWindow / 60)) min of RamClean \(r.forced ? "force quitting" : "quitting") it", at: now)
        case .neverQuit:
            // You cancelled its save dialog, or it hung and you let it be: the "deadweight"
            // answer recorded when you asked to quit it didn't turn out to be true.
            habitStore.log(.neverQuit, key: r.key, name: r.name, detail: "Still open \(minutes) min after RamClean asked it to quit", at: now)
            if model.removeLatest(key: r.key, since: r.killedAt.addingTimeInterval(-60), label: .deadweight) {
                modelStatus = model.status
                scheduleRetrain()
            }
        }
        if KillLabeler.label(for: outcome) == .keep {
            model.relabelLatest(key: r.key, since: r.killedAt.addingTimeInterval(-60), to: .keep)
            scheduleRetrain()
        }
        refreshEvents()
    }

    private func announceQuit(_ r: KillRecord) {
        var body = r.memoryBytes.map { "Freed about \(Format.bytes($0)). " } ?? ""
        body += "Changed your mind? Relaunch it."
        notifier.quitDone(key: r.key, name: r.name, body: body)
    }

    // MARK: - Suggestions and answers

    private func suggest(_ a: Assessment, now: Date) {
        lastNotified[a.group.habitKey] = now
        lastAnyNotification = now
        // Just the reason, so the body stays within two lines.
        let body = QuitReason.text(for: a, growth: grown[a.group.habitKey], now: now)
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
        case .relaunch: relaunch(key: key)
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
            case .memory: sendAlert(AlertRecommender.memory(s, list, grown: grown))
            case .cpu: sendAlert(AlertRecommender.cpu(s, list))
            case .disk:
                // Use a scan from the last 6 hours, or run one and alert when it's done.
                if let report = diskReport, diskScanStep == nil, now.timeIntervalSince(report.scannedAt) < 6 * 3600 {
                    sendAlert(AlertRecommender.disk(s, report))
                } else if let report = diskReport {
                    // Don't make you wait minutes for a scan: alert now from the last one,
                    // minus anything since deleted, and refresh the list in the background.
                    sendAlert(AlertRecommender.disk(s, report.droppingMissing()))
                    scanDisk(byUser: false)
                } else {
                    diskAlertWaitingForScan = true
                    scanDisk(byUser: false)
                }
            }
        }
    }

    /// Warns, at most once a day, when the disk will reach its alert line within three days at
    /// the current rate, naming what to clear from the last scan, before it's an emergency.
    private func checkDiskForecast(_ s: SystemSnapshot, now: Date) {
        guard prefs.alertsEnabled, let days = diskFullInDays, days <= 3,
              let loss = diskHistory.lossPerDay(now: now) else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastForecastKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= 86_400 else { return }
        UserDefaults.standard.set(now, forKey: Self.lastForecastKey)
        sendAlert(AlertRecommender.diskForecast(s, diskReport?.droppingMissing(), days: days, lossPerDay: loss))
        if diskReport.map({ now.timeIntervalSince($0.scannedAt) > 6 * 3600 }) ?? true { scanDisk(byUser: false) }
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
        case .restart: restart(key: target)
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

    /// Asks the app to quit normally, so it can save or prompt. Apps with unsaved changes, or
    /// the one you're using, need a confirmation first. The unsaved check runs off the main
    /// thread, and the quit request goes out before any bookkeeping.
    func quit(key: String, source: String) {
        let apps = Self.runningApps(key)
        guard !apps.isEmpty, !quitting.contains(key), allowed("Quitting apps") else { return }
        let name = Self.name(apps[0])
        let pids = apps.map(\.processIdentifier), front = apps.contains(where: \.isActive)
        quitting.insert(key)
        Task {
            let unsaved = await Self.anyUnsavedDocuments(pids)
            if let risk = Self.quitRisk(unsaved: unsaved, front: front), !confirmQuit(name: name, reason: risk) {
                quitting.remove(key)
                lastNotified[key] = Date()
                return
            }
            let apps = Self.runningApps(key)
            guard !apps.isEmpty else { quitting.remove(key); return }
            apps.forEach { $0.terminate() }

            let now = Date()
            kills.recordKill(KillRecord(key: key, name: name, killedAt: now, source: source,
                                        memoryBytes: assessments.first { $0.group.habitKey == key }?.group.memoryBytes))
            record(key: key, label: .deadweight, source: source)
            habitStore.recordDecision(.quitBySuggestion, key: key, name: name, detail: "from \(source)", at: now)
            refreshEvents()
            watchQuit(key: key, name: name, pids: pids)
        }
    }

    /// Quits several apps after one confirmation that names them and what they'd free.
    func quitAll(_ apps: [Assessment]) {
        guard !apps.isEmpty, allowed("Quitting apps") else { return }
        let total = apps.reduce(UInt64(0)) { $0 + $1.group.memoryBytes }
        let alert = NSAlert()
        alert.messageText = "Quit \(apps.count) apps?"
        alert.informativeText = apps.map(\.group.name).joined(separator: ", ")
            + ".\n\nThat frees about \(Format.bytes(total)). Each is asked to quit normally, so it can offer to save first."
        alert.addButton(withTitle: "Quit \(apps.count) Apps")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for a in apps { quit(key: a.group.habitKey, source: "quit all") }
    }

    /// Quits the app and opens it again once it has exited, to free the memory it has built
    /// up. Unlike Quit, this isn't a "deadweight" answer, so nothing is learned from it.
    func restart(key: String) {
        let apps = Self.runningApps(key)
        guard !apps.isEmpty, !quitting.contains(key), allowed("Restarting apps") else { return }
        let name = Self.name(apps[0])
        let pids = apps.map(\.processIdentifier), front = apps.contains(where: \.isActive)
        let freed = grown[key]?.freed
        quitting.insert(key)
        Task {
            let unsaved = await Self.anyUnsavedDocuments(pids)
            if let risk = Self.quitRisk(unsaved: unsaved, front: front), !confirmQuit(name: name, reason: risk, restarting: true) {
                quitting.remove(key)
                return
            }
            let apps = Self.runningApps(key)
            guard !apps.isEmpty else { quitting.remove(key); return }
            pendingRelaunch.insert(key)
            apps.forEach { $0.terminate() }
            habitStore.log(.restarted, key: key, name: name,
                           detail: freed.map { "to free about \(Format.bytes($0)) it had built up" }, at: Date())
            refreshEvents()
            watchQuit(key: key, name: name, pids: pids)
        }
    }

    /// Offers Force Quit once the app has stopped answering for a few seconds in a row, or
    /// after `forceQuitAfterSeconds` at the latest, instead of always waiting the full time.
    private func watchQuit(key: String, name: String, pids: [pid_t]) {
        let deadline = Date().addingTimeInterval(prefs.forceQuitAfterSeconds)
        Task {
            var unresponsive = 0
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard quitting.contains(key), !Self.runningApps(key).isEmpty else { return }
                unresponsive = await Self.isUnresponsive(pids) ? unresponsive + 1 : 0
                if unresponsive >= 3 || Date() >= deadline { break }
            }
            quitting.remove(key)
            awaitingForceQuit.insert(key)
            notifier.offerForceQuit(key: key, name: name)
        }
    }

    /// The app is gone: drop it from the lists now, and re-measure memory a moment later
    /// (once the system has reclaimed it) rather than waiting for the next check.
    private func appExited(_ key: String) {
        assessments.removeAll { $0.group.habitKey == key }
        Task {
            try? await Task.sleep(for: .seconds(1))
            tick()
        }
    }

    func forceQuit(key: String) {
        let apps = Self.runningApps(key)
        kills.markForced(key: key)
        apps.forEach { $0.forceTerminate() }
        awaitingForceQuit.remove(key)
        if let name = apps.first.map(Self.name) {
            habitStore.log(.forceQuit, key: key, name: name, at: Date())
            refreshEvents()
        }
    }

    /// Reopens an app RamClean quit, by its bundle ID (or path, for apps without one).
    func relaunch(key: String) {
        let name = habitStore.habits[key]?.name ?? key
        if AppKey.project(bundlePath: key) != nil {
            notifier.problem("Couldn't relaunch \(name)", "It's a development build. Start it again from its project.")
            return
        }
        guard let url = key.hasPrefix("/") ? URL(fileURLWithPath: key) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else {
            notifier.problem("Couldn't relaunch \(name)", "RamClean can't find the app anymore.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in self.notifier.problem("Couldn't relaunch \(name)", error.localizedDescription) }
        }
    }

    /// Why quitting this app needs a confirmation, or nil when it can go quietly.
    private static func quitRisk(unsaved: Bool, front: Bool) -> String? {
        switch (unsaved, front) {
        case (true, true): return "It has unsaved changes, and you're using it right now."
        case (true, false): return "It has unsaved changes."
        case (false, true): return "You're using it right now."
        case (false, false): return nil
        }
    }

    private func confirmQuit(name: String, reason: String, restarting: Bool = false) -> Bool {
        let verb = restarting ? "Restart" : "Quit"
        let alert = NSAlert()
        alert.messageText = "\(verb) \(name)?"
        alert.informativeText = "\(reason) RamClean will ask it to quit normally, so it can offer to save first\(restarting ? ", then open it again" : "")."
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Checks every process of the app at once, off the main thread.
    nonisolated static func anyUnsavedDocuments(_ pids: [pid_t]) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for pid in pids { group.addTask { hasUnsavedDocuments(pid) } }
            return await group.contains(true)
        }
    }

    /// True when any of the app's windows shows unsaved changes. Needs Accessibility access;
    /// without it RamClean can't tell, and the app's own save prompt is the backstop. A hung
    /// app counts as clean: it times out once rather than once per window.
    nonisolated static func hasUnsavedDocuments(_ pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        return windows.contains { w in
            AXUIElementSetMessagingTimeout(w, axTimeout)
            var edited: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXEditedAttribute as CFString, &edited) == .success && (edited as? Bool) == true
        }
    }

    /// True when every process of the app fails to answer Accessibility within `axTimeout`:
    /// it's hung, not waiting on a save dialog. False when RamClean lacks Accessibility access.
    nonisolated static func isUnresponsive(_ pids: [pid_t]) async -> Bool {
        guard AXIsProcessTrusted(), !pids.isEmpty else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            for pid in pids {
                group.addTask {
                    let app = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(app, axTimeout)
                    var role: CFTypeRef?
                    return AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role) == .cannotComplete
                }
            }
            return await group.allSatisfy { $0 }
        }
    }

    private nonisolated static let axTimeout: Float = 0.25

    func keep(key: String, always: Bool, source: String) {
        let name = assessments.first { $0.group.habitKey == key }?.group.name ?? habitStore.habits[key]?.name ?? key
        // "Always keep" is a protection setting and works without a licence; learning from it doesn't.
        let learns = always ? licensing.state().unlocksActions : allowed("Learning from your answers")
        if always, !prefs.alwaysKeep.contains(key) { prefs.alwaysKeep.append(key) }
        lastNotified[key] = Date()
        guard learns else { return }
        record(key: key, label: .keep, source: source)
        habitStore.recordDecision(always ? .alwaysKept : .kept, key: key, name: name, detail: "from \(source)", at: Date())
        refreshEvents()
    }

    private func record(key: String, label: Label, source: String) {
        guard let a = assessments.first(where: { $0.group.habitKey == key }) else { return }
        model.add(TrainingExample(date: Date(), features: a.features, label: label, source: source))
        modelStatus = model.status
        scheduleRetrain()
    }

    private var retrainScheduled = false

    /// Retrains a little later, once, however many answers arrive meanwhile, so training
    /// doesn't compete for CPU and memory with an app that's busy quitting.
    private func scheduleRetrain() {
        guard !retrainScheduled else { return }
        retrainScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(15))
            retrainScheduled = false
            retrain(qos: .background)
        }
    }

    func retrain(qos: DispatchQoS.QoSClass = .utility) {
        isTraining = true
        let model = model
        DispatchQueue.global(qos: qos).async {
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
        guard allowed("Moving files to the Trash") else { return nil }
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

    /// Runs an item's own cleanup command (e.g. `xcrun simctl delete unavailable`) in the background
    /// and logs it. Calls back on the main thread with an error message or nil.
    func runCleanup(_ item: DiskItem, done: @escaping (String?) -> Void) {
        guard let command = item.cleanupCommand, let text = item.cleanupCommandText else {
            done("RamClean doesn't have a command for this one."); return
        }
        guard allowed("Cleaning up") else { done(nil); return }
        cleaningPaths.insert(item.path)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                let result = try ToolRunner.run(command, timeout: 600)
                if result.status != 0 {
                    let tail = result.output.split(separator: "\n").suffix(4).joined(separator: "\n")
                    failure = "\(text) stopped with code \(result.status)." + (tail.isEmpty ? "" : "\n\n\(tail)")
                }
            } catch is ToolRunner.Timeout {
                failure = "\(text) was still running after 10 minutes, so RamClean stopped it."
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.cleaningPaths.remove(item.path)
                if failure == nil {
                    self.habitStore.log(.cleanedUp, key: "disk", name: item.name,
                                        detail: "\(Format.bytes(UInt64(max(0, item.bytes ?? 0)))) · \(text)", at: Date())
                    self.diskReport?.items.removeAll { $0.id == item.id }
                    self.saveDiskReport()
                    self.refreshEvents()
                    self.tick()
                }
                done(failure)
            }
        }
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
        guard allowed("Moving files off this Mac") else { done(nil); return }
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

    // MARK: - Licence

    /// Watching and recommendations are free; acting needs the trial or a licence. When it's
    /// locked, says so and offers to buy or enter a key (once, even for "Quit all").
    private func allowed(_ action: String) -> Bool {
        licence = licensing.state()
        if licence.unlocksActions { return true }
        guard Date().timeIntervalSince(lastLicenceAlert) > 2 else { return false }
        let config = licensing.config
        let alert = NSAlert()
        alert.messageText = "\(action) needs a licence"
        alert.informativeText = licence.detail(config)
        alert.addButton(withTitle: "Buy \(config.name) – \(config.price)")
        alert.addButton(withTitle: "Enter Licence Key…")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: buy()
        case .alertSecondButtonReturn: showLicenceSettings()
        default: break
        }
        lastLicenceAlert = Date()
        return false
    }

    func buy() { NSWorkspace.shared.open(licensing.config.checkoutURL) }

    func showLicenceSettings() {
        settingsTab = .licence
        openSettings?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called after every check: refreshes the state, and re-checks the key with Lemon Squeezy
    /// when it's due (daily, or hourly while offline).
    private func updateLicence() {
        licence = licensing.state()
        guard licensing.needsCheck(), !checkingLicence else { return }
        Task { await checkLicence() }
    }

    func checkLicence() async {
        checkingLicence = true
        let problem = await licensing.refresh()
        checkingLicence = false
        if case .rejected(let why) = problem { licenceProblem = "Your licence was removed from this Mac: \(why)" }
        licence = licensing.state()
        licenceRecord = licensing.record
    }

    /// Returns an error message, or nil once the key is active on this Mac.
    func activateLicence(_ key: String) async -> String? {
        defer { licence = licensing.state(); licenceRecord = licensing.record }
        do {
            try await licensing.activate(key: key)
            licenceProblem = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deactivateLicence() async -> String? {
        defer { licence = licensing.state(); licenceRecord = licensing.record }
        do {
            try await licensing.deactivate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Removes the key from this Mac without telling the server (for when it can't be reached).
    func forgetLicence() {
        licensing.forget()
        licence = licensing.state()
        licenceRecord = nil
    }

    func resetModel() {
        model.reset()
        modelStatus = model.status
    }

    func clearHabits() {
        habitStore.clear()
        kills.clear()
        habits = []
        events = []
    }

    private func refreshEvents() { events = habitStore.recentEvents }

    // MARK: - Helpers

    static func key(_ app: NSRunningApplication) -> String {
        AppKey.key(bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path) ?? "pid:\(app.processIdentifier)"
    }

    static func name(_ app: NSRunningApplication) -> String {
        AppKey.name(app.localizedName ?? "", bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path)
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
