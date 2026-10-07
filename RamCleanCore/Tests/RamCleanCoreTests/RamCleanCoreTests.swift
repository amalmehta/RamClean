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
