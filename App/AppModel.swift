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
    @Published var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            Self.savePrefs(prefs)
            if prefs.checkInterval != oldValue.checkInterval { scheduleTimer() }
            tick()
        }
    }

    let dataDirectory: URL
    let habitStore: HabitStore
    let model: DeadweightModel
    let notifier = Notifier()

    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private var cpuHistory = CPUHistory()
    private var timer: Timer?
    private var frontmost: (key: String, name: String)?
    private var lastCredit = Date()
    private var lastNotified: [String: Date] = [:]
    private var lastAnyNotification: Date?
    private var lastDiskWarning: Date?
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
        modelStatus = model.status
        events = habitStore.recentEvents
    }

    func start() {
        guard !started else { return }
        started = true
        notifier.onAction = { [weak self] action, key in self?.handle(action, key: key) }
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
        checkDisk(snapshot, now: now)
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

    func handle(_ action: Notifier.Action, key: String) {
        switch action {
        case .quit: quit(key: key, source: "notification")
        case .keep: keep(key: key, always: false, source: "notification")
        case .alwaysKeep: keep(key: key, always: true, source: "notification")
        case .forceQuit: forceQuit(key: key)
        case .open: NSApp.activate(ignoringOtherApps: true)
        }
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

    func resetModel() {
        model.reset()
        modelStatus = model.status
    }

    func clearHabits() {
        habitStore.clear()
        habits = []
        events = []
    }

    private func checkDisk(_ s: SystemSnapshot, now: Date) {
        guard prefs.notificationsEnabled, s.diskFreeFraction * 100 < prefs.diskWarningPercent else { return }
        if let last = lastDiskWarning, now.timeIntervalSince(last) < 24 * 3600 { return }
        lastDiskWarning = now
        notifier.diskWarning(free: Format.bytes(UInt64(max(0, s.diskFree))), percent: Int(s.diskFreeFraction * 100))
        habitStore.log(.diskWarning, key: "disk", name: "Disk", detail: "\(Format.bytes(UInt64(max(0, s.diskFree)))) free", at: now)
        refreshEvents()
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
    static func duration(minutes m: Double) -> String {
        if m >= 20_000 { return "over 2 weeks" }
        if m < 1 { return "under a minute" }
        if m < 60 { return "\(Int(m)) min" }
        if m < 60 * 48 { return String(format: "%.1f h", m / 60).replacingOccurrences(of: ".0 h", with: " h") }
        return "\(Int(m / 1440)) days"
    }
}
