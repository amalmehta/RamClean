import XCTest
@testable import RamCleanCore

final class AutoCleanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let roomy = SystemSnapshot(totalMemory: 16 << 30, usedMemory: 6 << 30)
    private let tight = SystemSnapshot(totalMemory: 16 << 30, usedMemory: 14 << 30)
    private let pressured = SystemSnapshot(totalMemory: 16 << 30, usedMemory: 6 << 30, pressure: .warning)

    private func prefs(on: Bool = true) -> Preferences {
        var p = Preferences()
        p.autoCleanEnabled = on
        return p
    }

    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    private func assessment(_ name: String, mb: Double, idle: Double, verdict: Verdict = .deadweight,
                            kind: GroupKind = .app) -> Assessment {
        let g = AppGroup(id: name, kind: kind, name: name, bundleID: name, bundlePath: nil, mainPID: 1, pids: [1],
                         memoryBytes: UInt64(mb * 1_048_576), cpuPercent: 0, hostedCommands: [], hostedCPUPercent: 0)
        let f = FeatureVector(bundleID: name, memoryMB: mb, cpuPercent: 0, minutesSinceActive: idle, foregroundMinutesToday: 0,
                              avgDailyMinutes14d: 0, daysUsed14d: 0, launches7d: 0, hourOfDay: 12, isWeekend: 0,
                              playingAudio: 0, timesKept: 0, timesQuit: 0)
        return Assessment(group: g, features: f, score: 0.9, usedModel: false, verdict: verdict, cpuAverage: 0)
    }

    // MARK: When it runs

    func testOffByDefaultAndNeverRunsWhenOff() {
        XCTAssertFalse(Preferences().autoCleanEnabled)
        XCTAssertEqual(Preferences().autoCleanHours, 6)
        let policy = AutoCleanPolicy(prefs: prefs(on: false))
        XCTAssertNil(policy.due(clock: AutoCleanClock(), system: tight, diskFullInDays: 1, now: now))
    }

    func testFirstRunIsScheduledThenEverySixHours() {
        let policy = AutoCleanPolicy(prefs: prefs())
        XCTAssertEqual(policy.due(clock: AutoCleanClock(), system: roomy, diskFullInDays: nil, now: now),
                       AutoCleanPlan(quitApps: true, clearBuildFolders: true, trigger: .scheduled))
        XCTAssertNil(policy.due(clock: AutoCleanClock(lastScheduled: ago(5.9)), system: roomy, diskFullInDays: nil, now: now))
        XCTAssertEqual(policy.due(clock: AutoCleanClock(lastScheduled: ago(6)), system: roomy, diskFullInDays: nil, now: now)?.trigger, .scheduled)
        var p = prefs(); p.autoCleanHours = 12
        XCTAssertNil(AutoCleanPolicy(prefs: p).due(clock: AutoCleanClock(lastScheduled: ago(11)), system: roomy, diskFullInDays: nil, now: now))
    }

    func testTightMemoryBringsTheAppHalfForwardAtMostHourly() {
        let policy = AutoCleanPolicy(prefs: prefs())
        let clock = AutoCleanClock(lastScheduled: ago(2), lastApps: ago(2), lastDisk: ago(2))
        XCTAssertEqual(policy.due(clock: clock, system: tight, diskFullInDays: nil, now: now),
                       AutoCleanPlan(quitApps: true, clearBuildFolders: false, trigger: .memoryTight))
        // macOS's own pressure level counts even when % used looks fine.
        XCTAssertEqual(policy.due(clock: clock, system: pressured, diskFullInDays: nil, now: now)?.trigger, .memoryTight)
        let justRan = AutoCleanClock(lastScheduled: ago(2), lastApps: ago(0.5), lastDisk: ago(2))
        XCTAssertNil(policy.due(clock: justRan, system: tight, diskFullInDays: nil, now: now))
    }

    func testDiskForecastBringsTheDiskHalfForward() {
        let policy = AutoCleanPolicy(prefs: prefs())
        let clock = AutoCleanClock(lastScheduled: ago(2), lastApps: ago(2), lastDisk: ago(2))
        XCTAssertEqual(policy.due(clock: clock, system: roomy, diskFullInDays: 2.5, now: now),
                       AutoCleanPlan(quitApps: false, clearBuildFolders: true, trigger: .diskForecast))
        XCTAssertNil(policy.due(clock: clock, system: roomy, diskFullInDays: 3.5, now: now))
        XCTAssertNil(policy.due(clock: AutoCleanClock(lastScheduled: ago(2), lastDisk: ago(0.2)), system: roomy, diskFullInDays: 1, now: now))
    }

    func testClockRecordsEachHalf() {
        var clock = AutoCleanClock()
        clock.ran(AutoCleanPlan(quitApps: true, clearBuildFolders: false, trigger: .memoryTight), at: now)
        XCTAssertEqual(clock, AutoCleanClock(lastScheduled: nil, lastApps: now, lastDisk: nil))
        clock.ran(AutoCleanPlan(quitApps: true, clearBuildFolders: true, trigger: .scheduled), at: now)
        XCTAssertEqual(clock, AutoCleanClock(lastScheduled: now, lastApps: now, lastDisk: now))
    }

    // MARK: What it touches

    func testOnlyIdleBigDeadweightDockAppsAreQuit() {
        let policy = AutoCleanPolicy(prefs: prefs())
        let list = [
            assessment("Figma", mb: 1800, idle: 300),
            assessment("Slack", mb: 900, idle: 125),
            assessment("Notes", mb: 900, idle: 90),                                  // idle under 2 h
            assessment("Preview", mb: 120, idle: 600),                               // too small to matter
            assessment("Music", mb: 700, idle: 600, verdict: .protected(.busy(.playingAudio))),
            assessment("Xcode", mb: 4000, idle: 600, verdict: .protected(.alwaysKeep)),
            assessment("Mail", mb: 700, idle: 600, verdict: .keep),
            assessment("helper", mb: 700, idle: 600, kind: .background),
        ]
        XCTAssertEqual(policy.appsToQuit(list).map(\.group.name), ["Figma", "Slack"])
    }

    func testOnlySafeBuildFoldersThatStillExistAreTrashed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func folder(_ name: String, writtenDaysAgo days: Double = 60) throws -> String {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
            return url.path
        }
        let report = DiskReport(items: [
            DiskItem(name: "old-app › node_modules", path: try folder("a/node_modules"), bytes: 800 << 20, kind: .buildArtifact, reason: ""),
            DiskItem(name: "game › target", path: try folder("b/target"), bytes: 2 << 30, kind: .buildArtifact, reason: ""),
            DiskItem(name: "gone › build", path: dir.appendingPathComponent("c/build").path, bytes: 1 << 30, kind: .buildArtifact, reason: ""),
            DiskItem(name: "careful › .build", path: try folder("d/.build"), bytes: 1 << 30, kind: .buildArtifact, reason: "", caution: "Check first"),
            DiskItem(name: "npm cache", path: try folder("npm"), bytes: 3 << 30, kind: .cache, reason: ""),
            DiskItem(name: "film.mov", path: try folder("film.mov"), bytes: 9 << 30, kind: .largeFile, reason: ""),
            DiskItem(name: "empty › dist", path: try folder("e/dist"), bytes: 0, kind: .buildArtifact, reason: ""),
            // Listed as old by the scan, but a build wrote to it since: active work, left alone.
            DiskItem(name: "revived › .next", path: try folder("f/.next", writtenDaysAgo: 0.01), bytes: 1 << 30, kind: .buildArtifact, reason: ""),
        ], scannedAt: now)
        let policy = AutoCleanPolicy(prefs: prefs())
        XCTAssertEqual(Set(policy.foldersToTrash(report, now: now).map(\.name)), ["old-app › node_modules", "game › target"])
    }

    // MARK: The notification

    func testSummaryNamesWhatWasDoneAndStaysQuietWhenNothingWas() throws {
        XCTAssertNil(AutoCleanSummary.text(quit: [], trashed: [], trigger: .scheduled))
        let folders = [DiskItem(name: "a", path: "/a", bytes: 1_000_000_000, kind: .buildArtifact, reason: ""),
                       DiskItem(name: "b", path: "/b", bytes: 500_000_000, kind: .buildArtifact, reason: "")]
        let t = try XCTUnwrap(AutoCleanSummary.text(quit: [("Figma", 2 << 30), ("Slack", 1 << 30)], trashed: folders, trigger: .scheduled))
        XCTAssertEqual(t.title, "Freed 3 GB of memory and 1.5 GB of disk")
        XCTAssertEqual(t.body, "Quit Figma and Slack (idle, marked deadweight); moved 2 old project build folders to the Trash.")
        let m = try XCTUnwrap(AutoCleanSummary.text(quit: [("Figma", 2 << 30)], trashed: [], trigger: .memoryTight))
        XCTAssertEqual(m.body, "Memory was getting tight. Quit Figma (idle, marked deadweight).")
        let d = try XCTUnwrap(AutoCleanSummary.text(quit: [], trashed: [folders[0]], trigger: .diskForecast))
        XCTAssertEqual(d.body, "The disk was on course to fill. Moved 1 old project build folder to the Trash.")
        XCTAssertEqual(AutoCleanSummary.list(["A", "B", "C", "D", "E"]), "A, B and 3 more")
    }

    // MARK: Learning: an automatic quit isn't your answer

    func testAutoQuitsCountAsFreedButNotAsYourAnswers() {
        let t0 = now
        func e(_ m: Double, _ kind: HabitEventKind, _ key: String, bytes: UInt64? = nil) -> HabitEvent {
            HabitEvent(date: t0.addingTimeInterval(m * 60), kind: kind, key: key, name: key, bytes: bytes)
        }
        let events = [
            e(0, .quitBySuggestion, "Slack", bytes: 1 << 30),  // your answer: quit
            e(60, .autoQuit, "Slack", bytes: 1 << 30),          // automatic, then it never quit
            e(91, .neverQuit, "Slack"),
            e(100, .autoQuit, "Figma", bytes: 2 << 30),         // automatic, reopened: a keep
            e(110, .autoReopened, "Figma"),
            e(120, .autoQuit, "Zoom", bytes: 1 << 29),          // automatic, stayed closed
            e(150, .stayedClosed, "Zoom"),
        ]
        let week = DateInterval(start: t0.addingTimeInterval(-60), duration: 7 * 86_400)
        let s = WeeklySummary.make(events: events, interval: week)
        XCTAssertEqual(s.accepted, 1, "only your own Quit counts as accepting a suggestion")
        XCTAssertEqual(s.quits, 3, "your quit, Figma and Zoom; Slack's automatic quit never happened")
        XCTAssertEqual(s.memoryFreed, (1 << 30) + (2 << 30) + (1 << 29))
        XCTAssertEqual(s.reopened, 1)
        let learned = WeeklySummary.learned(events)
        XCTAssertEqual(learned["Slack"]?.label, .deadweight, "the automatic quit that didn't happen doesn't take back your answer")
        XCTAssertEqual(learned["Slack"]?.quits, 1)
        XCTAssertEqual(learned["Figma"]?.label, .keep)
        XCTAssertNil(learned["Zoom"], "staying closed after an automatic quit isn't an answer")
    }

    func testReopeningAfterAnAutoQuitIsAKeepInTheHabitLog() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HabitStore(directory: dir)
        store.recordDecision(.quitBySuggestion, key: "Figma", name: "Figma", at: now)
        store.log(.autoQuit, key: "Figma", name: "Figma", at: now.addingTimeInterval(3600))
        store.recordDecision(.autoReopened, key: "Figma", name: "Figma", at: now.addingTimeInterval(4000))
        let stats = store.stats(for: "Figma", now: now.addingTimeInterval(5000))
        XCTAssertEqual(stats.timesQuit, 1, "the automatic quit isn't counted as yours")
        XCTAssertEqual(stats.regrets, 1)
        XCTAssertEqual(stats.recentAnswers, [.quit, .kept], "your quit stays; the reopen adds a keep")
    }
}
