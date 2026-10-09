import XCTest
@testable import RamCleanCore

final class GroupingTests: XCTestCase {
    func testBundlePathUsesOutermostApp() {
        let p = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        XCTAssertEqual(AppGrouper.bundlePath(for: p), "/Applications/Google Chrome.app")
        XCTAssertNil(AppGrouper.bundlePath(for: "/usr/bin/node"))
    }

    func testHelpersGroupUnderTheirAppAndTerminalHostsClaude() {
        let procs = [
            ProcessSnapshot(pid: 10, ppid: 1, name: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", footprintBytes: 500 << 20, cpuPercent: 2),
            ProcessSnapshot(pid: 11, ppid: 10, name: "Google Chrome Helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/H.app/Contents/MacOS/Google Chrome Helper", footprintBytes: 300 << 20, cpuPercent: 3),
            ProcessSnapshot(pid: 20, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", footprintBytes: 100 << 20),
            ProcessSnapshot(pid: 21, ppid: 20, name: "login", path: "/usr/bin/login", footprintBytes: 1 << 20, hasTTY: true),
            ProcessSnapshot(pid: 22, ppid: 21, name: "zsh", path: "/bin/zsh", footprintBytes: 2 << 20, hasTTY: true),
            ProcessSnapshot(pid: 23, ppid: 22, name: "claude", path: "/Users/me/.local/bin/claude", footprintBytes: 400 << 20, cpuPercent: 40, hasTTY: true),
            ProcessSnapshot(pid: 30, ppid: 1, name: "cloudd", path: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd", footprintBytes: 50 << 20),
        ]
        let apps = [
            RunningAppInfo(pid: 10, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", isRegular: true),
            RunningAppInfo(pid: 20, bundleID: "com.apple.Terminal", name: "Terminal", bundlePath: "/System/Applications/Utilities/Terminal.app", isRegular: true),
        ]
        let groups = AppGrouper.group(procs, apps: apps)
        let chrome = groups.first { $0.bundleID == "com.google.Chrome" }!
        XCTAssertEqual(chrome.pids.sorted(), [10, 11])
        XCTAssertEqual(chrome.memoryBytes, 800 << 20)
        XCTAssertEqual(chrome.cpuPercent, 5, accuracy: 0.001)
        XCTAssertEqual(chrome.kind, .app)

        let terminal = groups.first { $0.bundleID == "com.apple.Terminal" }!
        XCTAssertEqual(terminal.hostedCommands, ["claude"])
        XCTAssertEqual(terminal.hostedCPUPercent, 40, accuracy: 0.001)

        XCTAssertEqual(groups.first { $0.id == "cli:claude" }?.kind, .commandLine)
        XCTAssertEqual(groups.first { $0.id == "proc:cloudd" }?.kind, .background)
    }
}

final class ProtectionTests: XCTestCase {
    func group(_ id: String, kind: GroupKind = .app, path: String = "/Applications/X.app", hosted: [String] = [], pids: [Int32] = [1]) -> AppGroup {
        AppGroup(id: path, kind: kind, name: id, bundleID: id, bundlePath: path, mainPID: pids.first, pids: pids,
                 memoryBytes: 1 << 30, cpuPercent: 0, hostedCommands: hosted, hostedCPUPercent: 0)
    }
    func ctx(_ prefs: Preferences = Preferences(), front: String? = nil, audio: Set<Int32> = [], cpu: Double = 0, idle: Double = 600) -> ProtectionContext {
        ProtectionContext(prefs: prefs, frontmostKey: front, selfBundleID: "com.amalmehta.RamClean", audioPIDs: audio, cpuAverage: cpu, minutesSinceActive: idle)
    }

    func testIdleAppIsNotProtected() {
        XCTAssertNil(ProtectionRules.reason(for: group("com.spotify.client"), ctx()))
    }
    func testSpotifyPlayingIsProtected() {
        XCTAssertEqual(ProtectionRules.reason(for: group("com.spotify.client", pids: [5, 6]), ctx(audio: [6])), .playingAudio)
    }
    func testTerminalRunningClaudeIsProtected() {
        XCTAssertEqual(ProtectionRules.reason(for: group("com.apple.Terminal", hosted: ["claude"]), ctx()), .hostsCommandLine(["claude"]))
    }
    func testBusyWorkToolIsProtectedButBusyNonWorkToolIsNot() {
        XCTAssertEqual(ProtectionRules.reason(for: group("com.apple.dt.Xcode"), ctx(cpu: 80)), .busyWork(cpu: 80))
        XCTAssertEqual(ProtectionRules.reason(for: group("com.jetbrains.pycharm"), ctx(cpu: 30)), .busyWork(cpu: 30))
        XCTAssertNil(ProtectionRules.reason(for: group("com.example.Game"), ctx(cpu: 80)))
    }
    func testSystemFrontmostRecentAndAlwaysKeep() {
        XCTAssertEqual(ProtectionRules.reason(for: group("com.apple.finder"), ctx()), .system)
        XCTAssertEqual(ProtectionRules.reason(for: group("x", path: "/System/Library/CoreServices/X.app"), ctx()), .system)
        XCTAssertEqual(ProtectionRules.reason(for: group("a"), ctx(front: "a")), .frontmost)
        XCTAssertEqual(ProtectionRules.reason(for: group("a"), ctx(idle: 5)), .recentlyUsed(minutes: 5))
        var fresh = ctx(idle: 5); fresh.everActive = false
        XCTAssertEqual(ProtectionRules.reason(for: group("a"), fresh), .learning(minutes: 5))
        var p = Preferences(); p.alwaysKeep = ["com.spotify.client"]
        XCTAssertEqual(ProtectionRules.reason(for: group("com.spotify.client"), ctx(p)), .alwaysKeep)
        XCTAssertEqual(ProtectionRules.reason(for: group("com.amalmehta.RamClean"), ctx()), .itself)
    }
    func testMenuBarAndCommandLineAreProtectedByDefault() {
        XCTAssertEqual(ProtectionRules.reason(for: group("m", kind: .menuBar), ctx()), .menuBarUtility)
        var p = Preferences(); p.includeMenuBarApps = true
        XCTAssertNil(ProtectionRules.reason(for: group("m", kind: .menuBar), ctx(p)))
        XCTAssertEqual(ProtectionRules.reason(for: group("c", kind: .commandLine), ctx()), .commandLine)
    }
}

final class HabitAndScoreTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testHabitStatsAndPersistence() {
        let now = Date()
        let store = HabitStore(directory: dir)
        store.creditForeground(key: "com.spotify.client", name: "Spotify", seconds: 1800, at: now)
        store.creditForeground(key: "com.spotify.client", name: "Spotify", seconds: 600, at: now.addingTimeInterval(-86_400 * 2))
        store.recordLaunch(key: "com.spotify.client", name: "Spotify", at: now)
        store.recordDecision(.kept, key: "com.spotify.client", name: "Spotify", at: now)
        store.save(now: now)

        let reloaded = HabitStore(directory: dir)
        let s = reloaded.stats(for: "com.spotify.client", now: now)
        XCTAssertEqual(s.foregroundMinutesToday, 30, accuracy: 0.01)
        XCTAssertEqual(s.avgDailyMinutes14d, 40.0 / 14, accuracy: 0.01)
        XCTAssertEqual(s.daysUsed14d, 2)
        XCTAssertEqual(s.launches7d, 1)
        XCTAssertEqual(s.timesKept, 1)
        XCTAssertEqual(reloaded.recentEvents.map(\.kind), [.launched, .kept])
        // Never seen in front: idle since RamClean started watching, not "forever".
        XCTAssertEqual(reloaded.stats(for: "never.seen", now: now.addingTimeInterval(3600)).minutesSinceActive, 60, accuracy: 1)
        XCTAssertFalse(reloaded.stats(for: "never.seen", now: now).everActive)
        XCTAssertTrue(s.everActive)
        let old = HabitStore(directory: dir.appendingPathComponent("old"), now: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(old.stats(for: "never.seen", now: now).minutesSinceActive, 20_160)
    }

    func f(idle: Double, avg: Double, days: Double, audio: Double = 0, kept: Double = 0, quit: Double = 0, id: String = "x") -> FeatureVector {
        FeatureVector(bundleID: id, memoryMB: 900, cpuPercent: 1, minutesSinceActive: idle, foregroundMinutesToday: 0,
                      avgDailyMinutes14d: avg, daysUsed14d: days, launches7d: 1, hourOfDay: 14, isWeekend: 0,
                      playingAudio: audio, timesKept: kept, timesQuit: quit)
    }

    func testHeuristicFavoursIdleRarelyUsedApps() {
        let deadweight = HeuristicScorer.score(f(idle: 600, avg: 1, days: 1))
        let habit = HeuristicScorer.score(f(idle: 600, avg: 90, days: 12))
        let fresh = HeuristicScorer.score(f(idle: 10, avg: 1, days: 1))
        XCTAssertGreaterThan(deadweight, 0.7)
        XCTAssertLessThan(habit, deadweight)
        XCTAssertLessThan(fresh, 0.3)
        XCTAssertLessThan(HeuristicScorer.score(f(idle: 600, avg: 1, days: 1, kept: 5)), 0.6)
    }

    func testModelStaysUntrainedUntilEnoughAnswersThenLearns() {
        let model = DeadweightModel(directory: dir)
        XCTAssertEqual(model.train().isTrained, false)
        XCTAssertNil(model.probability(f(idle: 600, avg: 1, days: 1)))

        // You quit idle, rarely used apps and keep the ones you use daily.
        for i in 0..<15 {
            model.add(TrainingExample(date: Date(), features: f(idle: 300 + Double(i * 40), avg: Double(i % 3), days: 1, id: "dead\(i % 4)"), label: .deadweight, source: "test"))
            model.add(TrainingExample(date: Date(), features: f(idle: 200 + Double(i * 40), avg: 60 + Double(i), days: 10 + Double(i % 4), id: "keep\(i % 4)"), label: .keep, source: "test"))
        }
        let status = model.train()
        XCTAssertTrue(status.isTrained, status.message)
        XCTAssertEqual(status.examples, 30)
        XCTAssertNotNil(status.holdoutAccuracy)
        let pDead = model.probability(f(idle: 500, avg: 1, days: 1, id: "dead1"))!
        let pKeep = model.probability(f(idle: 500, avg: 70, days: 12, id: "keep1"))!
        XCTAssertGreaterThan(pDead, pKeep)
        // An app it has never seen still gets a model score, via the "_other" category.
        let unseen = model.score(f(idle: 500, avg: 1, days: 1, id: "brand.new.app"))
        XCTAssertTrue(unseen.usedModel)
        XCTAssertGreaterThan(unseen.value, 0.5)

        // Persisted, and a regret flips the latest answer.
        let reopened = DeadweightModel(directory: dir)
        XCTAssertEqual(reopened.examples.count, 30)
        XCTAssertTrue(reopened.relabelLatest(key: "dead1", since: .distantPast, to: .keep))
        XCTAssertEqual(reopened.examples.last { $0.features.bundleID == "dead1" }?.label, .keep)
    }
}

final class PolicyTests: XCTestCase {
    func assessment(_ key: String, mb: Double, score: Double, verdict: Verdict = .deadweight, cpu: Double = 0) -> Assessment {
        let g = AppGroup(id: key, kind: .app, name: key, bundleID: key, bundlePath: nil, mainPID: 1, pids: [1],
                         memoryBytes: UInt64(mb * 1_048_576), cpuPercent: cpu, hostedCommands: [], hostedCPUPercent: 0)
        let f = FeatureVector(bundleID: key, memoryMB: mb, cpuPercent: cpu, minutesSinceActive: 600, foregroundMinutesToday: 0,
                              avgDailyMinutes14d: 0, daysUsed14d: 0, launches7d: 0, hourOfDay: 12, isWeekend: 0,
                              playingAudio: 0, timesKept: 0, timesQuit: 0)
        return Assessment(group: g, features: f, score: score, usedModel: false, verdict: verdict, cpuAverage: cpu)
    }
    let tight = SystemSnapshot(totalMemory: 16 << 30, usedMemory: 14 << 30)
    let roomy = SystemSnapshot(totalMemory: 16 << 30, usedMemory: 6 << 30)

    func testPicksBiggestDeadweightOnlyWhenMemoryIsTight() {
        let policy = SuggestionPolicy(prefs: Preferences())
        let list = [assessment("small", mb: 200, score: 0.95), assessment("big", mb: 2000, score: 0.8),
                    assessment("kept", mb: 5000, score: 0.2, verdict: .keep)]
        XCTAssertEqual(policy.pick(from: list, system: tight, lastNotified: [:], lastAnyNotification: nil, now: Date())?.id, "big")
        XCTAssertNil(policy.pick(from: list, system: roomy, lastNotified: [:], lastAnyNotification: nil, now: Date()))
    }

    func testCooldownsAndCPUHogs() {
        let policy = SuggestionPolicy(prefs: Preferences())
        let now = Date()
        let list = [assessment("big", mb: 2000, score: 0.8)]
        XCTAssertNil(policy.pick(from: list, system: tight, lastNotified: ["big": now.addingTimeInterval(-600)], lastAnyNotification: nil, now: now))
        XCTAssertNil(policy.pick(from: list, system: tight, lastNotified: [:], lastAnyNotification: now.addingTimeInterval(-60), now: now))
        let hog = [assessment("hog", mb: 100, score: 0.9, cpu: 95)]
        XCTAssertEqual(policy.pick(from: hog, system: roomy, lastNotified: [:], lastAnyNotification: nil, now: now)?.id, "hog")
    }

    func testCPUHistoryAverages() {
        var h = CPUHistory(window: 3)
        func g(_ cpu: Double) -> AppGroup {
            AppGroup(id: "a", kind: .app, name: "a", bundleID: "a", bundlePath: nil, mainPID: 1, pids: [1], memoryBytes: 0, cpuPercent: cpu, hostedCommands: [], hostedCPUPercent: 0)
        }
        _ = h.record([g(10)]); _ = h.record([g(20)]); _ = h.record([g(30)])
        XCTAssertEqual(h.record([g(90)])["a"]!, (20 + 30 + 90) / 3, accuracy: 0.001)
    }

    func testPreferencesDecodeKeepsDefaultsForMissingKeys() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"minAppMemoryMB": 999}"#.utf8))
        XCTAssertEqual(p.minAppMemoryMB, 999)
        XCTAssertEqual(p.memoryTriggerPercent, Preferences().memoryTriggerPercent)
    }
}

final class LiveSamplerTests: XCTestCase {
    func testSamplersReadThisMac() {
        let sampler = ProcessSampler()
        _ = sampler.sample()
        let procs = sampler.sample()
        XCTAssertGreaterThan(procs.count, 5)
        XCTAssertTrue(procs.contains { $0.pid == getpid() && $0.footprintBytes > 0 })

        let system = SystemSampler()
        _ = system.sample()
        let s = system.sample()
        XCTAssertGreaterThan(s.totalMemory, 0)
        XCTAssertGreaterThan(s.usedMemory, 0)
        XCTAssertGreaterThan(s.diskTotal, 0)
        _ = AudioActivity.pidsPlayingAudio() // must not crash
    }
}

final class RecommendationTests: XCTestCase {
    var home: URL!
    override func setUp() { home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func write(_ rel: String, mb: Int) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: mb * 1_048_576).write(to: url)
    }

    /// Sets a file's (and folder's) modified and opened dates to `days` ago.
    func age(_ rel: String, days: Double) throws {
        var url = home.appendingPathComponent(rel)
        var rv = URLResourceValues()
        rv.contentModificationDate = Date().addingTimeInterval(-days * 86_400)
        rv.contentAccessDate = rv.contentModificationDate
        try url.setResourceValues(rv)
    }

    func scanner() -> DiskScanner {
        var sc = DiskScanner(home: home)
        sc.minCacheBytes = 2 * 1_048_576
        sc.largeFileBytes = 3 * 1_048_576
        sc.minArtifactBytes = 2 * 1_048_576
        sc.oldDownloadBytes = 2 * 1_048_576
        sc.minAppBytes = 1
        sc.appFolders = [home.appendingPathComponent("Apps")]
        sc.appLastUsed = { _ in nil }
        sc.useSpotlight = false // temp folders aren't indexed; exercise the folder walk
        return sc
    }

    func testDiskScanFindsCachesLargeFilesAndTrash() throws {
        try write("Library/Developer/Xcode/DerivedData/App-abc/Build/big.o", mb: 6)
        try write("Library/Developer/Xcode/Archives/2026/App.xcarchive/x", mb: 3)
        try write("Library/Developer/CoreSimulator/Devices/ABC/data", mb: 3)
        try write("Library/Caches/com.spotify.client/Data/blob", mb: 4)
        try write("Library/Caches/tiny/blob", mb: 1)
        try write(".cache/huggingface/model.bin", mb: 5)
        try write("Movies/trip.mov", mb: 5); try age("Movies/trip.mov", days: 200)
        try write("Movies/editing-now.mov", mb: 5)          // opened today: active work
        try write("Documents/notes.txt", mb: 1)
        try write("Library/Mail/huge.mbox", mb: 9)          // inside ~/Library: never a "large file"
        try write(".Trash/old.mov", mb: 2)

        let report = scanner().scan()
        func item(_ name: String) -> DiskItem? { report.items.first { $0.name == name } }

        XCTAssertEqual(item("Xcode build data")?.kind, .cache)
        XCTAssertTrue(item("Xcode build data")!.canTrash)
        XCTAssertNotNil(item("Xcode archives")?.caution)
        XCTAssertEqual(item("Simulator devices")?.canTrash, false)
        XCTAssertEqual(item("Spotify client cache")?.kind, .cache)
        XCTAssertNil(item("tiny"), "below the cache threshold")
        XCTAssertEqual(item("huggingface")?.kind, .cache)
        XCTAssertEqual(item("trip.mov")?.kind, .largeFile)
        XCTAssertEqual(item("trip.mov")?.suggestMove, true, "not opened in 200 days: move it off the Mac")
        XCTAssertNil(item("editing-now.mov"), "recently opened files are active work")
        XCTAssertNil(item("notes.txt"))
        XCTAssertNil(item("huge.mbox"))
        XCTAssertNil(item("big.o"), "files inside a listed cache aren't repeated")
        XCTAssertEqual(item("Trash")?.kind, .trash)
        XCTAssertEqual(item("Trash")?.canTrash, false)
        XCTAssertEqual(report.items.map { $0.bytes ?? 0 }, report.items.map { $0.bytes ?? 0 }.sorted(by: >))
        XCTAssertGreaterThan(report.reclaimableBytes, 18 * 1_048_576)
    }

    func testStaleProjectsAppsAndDownloadsButNeverActiveWork() throws {
        // A project untouched for 60 days: its node_modules is fair game.
        try write("Code/old-site/package.json", mb: 0)
        try write("Code/old-site/node_modules/react/index.js", mb: 3)
        for f in ["Code/old-site/package.json", "Code/old-site/node_modules/react/index.js", "Code/old-site/node_modules/react",
                  "Code/old-site/node_modules"] { try age(f, days: 60) }
        // A project you're working on (fresh files): never suggested.
        try write("Code/live-app/Cargo.toml", mb: 0)
        try write("Code/live-app/target/debug/app", mb: 3)
        try age("Code/live-app/target/debug/app", days: 60); try age("Code/live-app/target", days: 60)
        // An old project whose build folder was just written to (a build running now): skipped.
        try write("Code/building/Package.swift", mb: 0); try age("Code/building/Package.swift", days: 90)
        try write("Code/building/.build/out.o", mb: 3)

        // Downloads: one old, one recent.
        try write("Downloads/Old Installer.dmg", mb: 4); try age("Downloads/Old Installer.dmg", days: 120)
        try write("Downloads/this-week.zip", mb: 4)

        // Apps: unused for 200 days, an Apple app, a protected one, a running one, one with no record.
        func app(_ name: String, _ id: String) throws {
            try write("Apps/\(name).app/Contents/MacOS/\(name)", mb: 1)
            let plist = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleExecutable": name]
            try (plist as NSDictionary).write(to: home.appendingPathComponent("Apps/\(name).app/Contents/Info.plist"))
        }
        try app("OldGame", "com.example.oldgame")
        try app("Keynote Clone", "com.apple.fake")
        try app("Kept", "com.example.kept")
        try app("Running", "com.example.running")
        try app("Mystery", "com.example.mystery")

        var sc = scanner()
        sc.isKept = { $0 == "com.example.kept" }
        sc.runningAppPaths = [home.appendingPathComponent("Apps/Running.app").path]
        sc.appLastUsed = { $0.lastPathComponent == "Mystery.app" ? nil : Date().addingTimeInterval(-200 * 86_400) }
        let report = sc.scan()
        func item(_ name: String) -> DiskItem? { report.items.first { $0.name == name } }

        XCTAssertEqual(item("old-site › node_modules")?.kind, .buildArtifact)
        XCTAssertTrue(item("old-site › node_modules")!.reason.contains("npm install"))
        XCTAssertNil(item("live-app › target"), "active project")
        XCTAssertNil(item("building › .build"), "build folder written today")
        XCTAssertEqual(item("Old Installer.dmg")?.kind, .oldDownload)
        XCTAssertNil(item("this-week.zip"))
        XCTAssertEqual(report.items(.unusedApp).map(\.name), ["OldGame"])
        XCTAssertNotNil(item("OldGame")?.caution)

        // A background scan stays out of Desktop, Documents and Downloads (no permission prompts).
        try write("Documents/Code/old-docs-site/package.json", mb: 0)
        try write("Documents/Code/old-docs-site/node_modules/x/index.js", mb: 3)
        for f in ["Documents/Code/old-docs-site/package.json", "Documents/Code/old-docs-site/node_modules/x/index.js",
                  "Documents/Code/old-docs-site/node_modules/x", "Documents/Code/old-docs-site/node_modules"] { try age(f, days: 60) }
        sc.avoidProtectedFolders = true
        let quiet = sc.scan()
        XCTAssertNil(quiet.items.first { $0.name == "Old Installer.dmg" }, "Downloads not read")
        XCTAssertNil(quiet.items.first { $0.name == "old-docs-site › node_modules" }, "Documents not read")
        XCTAssertNotNil(quiet.items.first { $0.name == "old-site › node_modules" }, "other folders still scanned")
        sc.avoidProtectedFolders = false
        XCTAssertNotNil(sc.scan().items.first { $0.name == "old-docs-site › node_modules" })
    }

    func testBulkSizingMatchesFtsAndSizeCacheReuse() throws {
        for i in 0..<5 { try write("tree/a\(i)/b/c/file\(i).bin", mb: 1) }
        try write("tree/top.bin", mb: 2)
        let tree = home.appendingPathComponent("tree")
        XCTAssertEqual(DiskScanner.allocatedSize(tree), DiskScanner.ftsSize(tree.path))
        XCTAssertGreaterThanOrEqual(DiskScanner.allocatedSize(tree), 7 * 1_048_576)
        XCTAssertEqual(DiskScanner.allocatedSize(home.appendingPathComponent("tree/top.bin")), DiskScanner.ftsSize(tree.path + "/top.bin"))

        let cache = SizeCache()
        var measured = 0
        func size() -> Int64 { cache.size(of: tree, now: Date(), measure: { measured += 1; return DiskScanner.allocatedSize($0) }) }
        let first = size()
        XCTAssertEqual(size(), first)
        XCTAssertEqual(measured, 1, "unchanged folder: remembered size reused")
        try write("tree/new.bin", mb: 1) // changes the folder's own modification time
        XCTAssertGreaterThan(size(), first)
        XCTAssertEqual(measured, 2, "folder changed: measured again")
        cache.reuse = false
        _ = size()
        XCTAssertEqual(measured, 3, "Rescan measures fresh")
    }

    func testPrettyNamesAndDurations() {
        XCTAssertEqual(DiskScanner.prettyCacheName("com.spotify.client"), "Spotify client cache")
        XCTAssertEqual(DiskScanner.prettyCacheName("Homebrew"), "Homebrew")
        XCTAssertEqual(HumanFormat.duration(minutes: 0.5), "under a minute")
        XCTAssertEqual(HumanFormat.duration(minutes: 90), "1.5 h")
        XCTAssertEqual(HumanFormat.duration(minutes: 1440 * 5), "5 days")
        XCTAssertEqual(HumanFormat.duration(minutes: 1440 * 120), "4 months")
    }

    func testAppReasons() {
        let g = AppGroup(id: "s", kind: .app, name: "Spotify", bundleID: "s", bundlePath: nil, mainPID: 1, pids: [1],
                         memoryBytes: 1 << 30, cpuPercent: 0, hostedCommands: [], hostedCPUPercent: 0)
        let f = FeatureVector(bundleID: "s", memoryMB: 1024, cpuPercent: 12, minutesSinceActive: 180, foregroundMinutesToday: 0,
                              avgDailyMinutes14d: 0.2, daysUsed14d: 1, launches7d: 0, hourOfDay: 12, isWeekend: 0,
                              playingAudio: 0, timesKept: 0, timesQuit: 2)
        let a = Assessment(group: g, features: f, score: 0.9, usedModel: false, verdict: .deadweight, cpuAverage: 12)
        XCTAssertEqual(a.reasons, ["Idle 3 h", "Rarely used (1 of 14 days)", "12% CPU", "You quit it 2× before"])
        var p = a; p.verdict = .protected(.playingAudio)
        XCTAssertEqual(p.reasons.first, "Playing audio")
        var r = a; r.verdict = .protected(.recentlyUsed(minutes: 16))
        XCTAssertEqual(r.reasons, ["Used 16 min ago", "Rarely used (1 of 14 days)", "12% CPU", "You quit it 2× before"])
    }
}

final class AlertTests: XCTestCase {
    func snap(mem: Double = 0.5, cpu: Double = 10, diskUsed: Double = 0.5, pressure: MemoryPressure = .normal) -> SystemSnapshot {
        SystemSnapshot(totalMemory: 32 << 30, usedMemory: UInt64(mem * Double(32 << 30)), pressure: pressure, cpuPercent: cpu,
                       diskTotal: 1_000_000_000_000, diskFree: Int64((1 - diskUsed) * 1_000_000_000_000))
    }

    func testThresholdsSustainRepeatRecoverAndSnooze() {
        var m = ThresholdMonitor(prefs: Preferences())
        let t0 = Date()
        XCTAssertEqual(m.update(snap(mem: 0.9), now: t0), [.memory])
        XCTAssertEqual(m.update(snap(mem: 0.9), now: t0.addingTimeInterval(600)), [], "no repeat within an hour")
        XCTAssertEqual(m.update(snap(mem: 0.9), now: t0.addingTimeInterval(3700)), [.memory], "repeats hourly while over")
        _ = m.update(snap(mem: 0.5), now: t0.addingTimeInterval(3800)) // recovered
        XCTAssertEqual(m.update(snap(mem: 0.9), now: t0.addingTimeInterval(3900)), [.memory], "re-armed after recovery")

        // CPU must stay over 97% for 2 minutes.
        XCTAssertEqual(m.update(snap(cpu: 99), now: t0), [])
        XCTAssertEqual(m.update(snap(cpu: 99), now: t0.addingTimeInterval(60)), [])
        XCTAssertEqual(m.update(snap(cpu: 99), now: t0.addingTimeInterval(125)), [.cpu])
        _ = m.update(snap(cpu: 50), now: t0.addingTimeInterval(130))
        XCTAssertEqual(m.update(snap(cpu: 99), now: t0.addingTimeInterval(135)), [], "spike after a dip starts the clock again")

        // Disk at 99%+ used; snoozing silences it.
        var d = ThresholdMonitor(prefs: Preferences())
        d.snooze(.disk, until: t0.addingTimeInterval(3600))
        XCTAssertEqual(d.update(snap(diskUsed: 0.995), now: t0), [])
        XCTAssertEqual(d.update(snap(diskUsed: 0.995), now: t0.addingTimeInterval(3601)), [.disk])

        var off = Preferences(); off.alertsEnabled = false
        var o = ThresholdMonitor(prefs: off)
        XCTAssertEqual(o.update(snap(mem: 0.99, cpu: 100, diskUsed: 1), now: t0), [])
    }

    func assessment(_ name: String, mb: Double, cpu: Double = 0, idle: Double = 300, verdict: Verdict = .deadweight) -> Assessment {
        let g = AppGroup(id: name, kind: .app, name: name, bundleID: name, bundlePath: nil, mainPID: 1, pids: [1],
                         memoryBytes: UInt64(mb * 1_048_576), cpuPercent: cpu, hostedCommands: [], hostedCPUPercent: 0)
        let f = FeatureVector(bundleID: name, memoryMB: mb, cpuPercent: cpu, minutesSinceActive: idle, foregroundMinutesToday: 0,
                              avgDailyMinutes14d: 0, daysUsed14d: 1, launches7d: 0, hourOfDay: 12, isWeekend: 0,
                              playingAudio: 0, timesKept: 0, timesQuit: 0)
        return Assessment(group: g, features: f, score: 0.9, usedModel: false, verdict: verdict, cpuAverage: cpu)
    }

    func testRecommendationsInAlerts() {
        let list = [assessment("Claude", mb: 4000, cpu: 60, verdict: .protected(.frontmost)),
                    assessment("Spotify", mb: 400), assessment("Acrobat", mb: 480, verdict: .keep),
                    assessment("Game", mb: 300, cpu: 80, verdict: .keep)]
        let m = AlertRecommender.memory(snap(mem: 0.88), list)
        XCTAssertEqual(m.title, "Memory is 88% full")
        XCTAssertTrue(m.body.contains("Quit Spotify"), m.body)          // deadweight first, even if smaller
        XCTAssertFalse(m.body.contains("Claude ("), "protected apps aren't recommended")
        XCTAssertEqual(m.action, AlertAction(kind: .quit, target: "Spotify", label: "Quit Spotify"))

        let c = AlertRecommender.cpu(snap(cpu: 99), list)
        XCTAssertEqual(c.action?.label, "Quit Game")

        let busyOnly = AlertRecommender.cpu(snap(cpu: 99), [list[0]])
        XCTAssertNil(busyOnly.action)
        XCTAssertTrue(busyOnly.body.contains("Busiest: Claude"), busyOnly.body)

        let report = DiskReport(items: [
            DiskItem(name: "uv", path: "/c/uv", bytes: 5 << 30, kind: .cache, reason: ""),
            DiskItem(name: "old-site › node_modules", path: "/p/nm", bytes: 2 << 30, kind: .buildArtifact, reason: ""),
            DiskItem(name: "OldGame", path: "/A/OldGame.app", bytes: 1 << 30, kind: .unusedApp, reason: ""),
            DiskItem(name: "trip.mov", path: "/m/trip.mov", bytes: 12 << 30, kind: .largeFile, reason: "", suggestMove: true),
        ], scannedAt: Date())
        let d = AlertRecommender.disk(snap(diskUsed: 0.995), report)
        XCTAssertEqual(d.title, "Disk is 100% full")
        XCTAssertTrue(d.body.contains("Clear uv"), d.body)
        XCTAssertTrue(d.body.contains("old-site › node_modules"), d.body)
        XCTAssertTrue(d.body.contains("uninstall OldGame"), d.body)
        XCTAssertTrue(d.body.contains("move trip.mov"), d.body)
        XCTAssertEqual(d.action, AlertAction(kind: .trash, target: "/c/uv", label: "Trash uv"))
        XCTAssertNil(AlertRecommender.disk(snap(diskUsed: 0.995), nil).action)
    }
}
