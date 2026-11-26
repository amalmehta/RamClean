import XCTest
@testable import RamCleanCore

/// When quitting an app yourself counts as a "deadweight" answer.
final class ManualQuitTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: ForegroundLog

    func testAppInBackgroundForMinutesWasNotInUse() {
        var log = ForegroundLog()
        log.activated("notes", at: at(0))
        log.activated("safari", at: at(30))
        XCTAssertFalse(log.wasInUse("notes", at: at(300)))   // Dock → Quit, 4.5 min after leaving it
        XCTAssertFalse(log.wasInUse("never-in-front", at: at(300)))
    }

    func testSwitchingToAnAppJustToQuitItDoesNotCountAsUse() {
        var log = ForegroundLog()
        log.activated("notes", at: at(0))
        log.activated("safari", at: at(30))
        log.activated("notes", at: at(300))                  // click it, Cmd-Q
        XCTAssertFalse(log.wasInUse("notes", at: at(303)))
        // macOS brings Safari forward, sometimes before the quit is reported.
        log.activated("safari", at: at(303))
        XCTAssertFalse(log.wasInUse("notes", at: at(303.5)))
    }

    func testAppUsedInTheLastMinuteWasInUse() {
        var log = ForegroundLog()
        log.activated("notes", at: at(0))
        XCTAssertTrue(log.wasInUse("notes", at: at(120)))    // in front for 2 min, then Cmd-Q
        log.activated("safari", at: at(120))
        XCTAssertTrue(log.wasInUse("notes", at: at(150)))    // left it 30 s ago
        XCTAssertFalse(log.wasInUse("notes", at: at(200)))   // left it 80 s ago
    }

    func testBouncingBackToAnAppYouJustUsedCountsAsUse() {
        var log = ForegroundLog()
        log.activated("notes", at: at(0))
        log.activated("safari", at: at(100))
        log.activated("notes", at: at(130))                  // back after 30 s, then Cmd-Q
        XCTAssertTrue(log.wasInUse("notes", at: at(132)))
    }

    func testForgetDropsTheApp() {
        var log = ForegroundLog()
        log.activated("notes", at: at(0))
        log.forget("notes")
        XCTAssertFalse(log.wasInUse("notes", at: at(1)))
        log.activated("notes", at: at(2))                    // relaunched: a fresh stint
        XCTAssertEqual(log.stints["notes"]?.count, 1)
    }

    // MARK: shouldLearn

    func learn(regular: Bool = true, byRamClean: Bool = false, alwaysKept: Bool = false,
               verdict: Verdict? = .keep, inUse: Bool = false) -> Bool {
        ManualQuit.shouldLearn(isRegular: regular, quitByRamClean: byRamClean, alwaysKept: alwaysKept,
                               verdict: verdict, wasInUse: inUse)
    }

    func testOnlyUnprotectedIdleDockAppsYouQuitAreLearned() {
        XCTAssertTrue(learn())
        XCTAssertTrue(learn(verdict: .deadweight))
        XCTAssertTrue(learn(verdict: .protected(.recentlyUsed(minutes: 5))))
        XCTAssertTrue(learn(verdict: .protected(.frontmost)))  // in front only to be quit
        XCTAssertFalse(learn(regular: false))
        XCTAssertFalse(learn(byRamClean: true))
        XCTAssertFalse(learn(alwaysKept: true))
        XCTAssertFalse(learn(inUse: true))
        XCTAssertFalse(learn(verdict: nil))
        XCTAssertFalse(learn(verdict: .protected(.system)))
        XCTAssertFalse(learn(verdict: .protected(.itself)))
        XCTAssertFalse(learn(verdict: .protected(.alwaysKeep)))
        XCTAssertFalse(learn(verdict: .protected(.menuBarUtility)))
        XCTAssertFalse(learn(verdict: .protected(.hostsCommandLine(["claude"]))))
        XCTAssertFalse(learn(verdict: .protected(.busyWork(cpu: 80))))
    }

    // MARK: One a day, and reopening flips it

    func row(_ id: String, _ source: String, at date: Date) -> TrainingExample {
        TrainingExample(date: date, features: FeatureVector(bundleID: id, memoryMB: 500, cpuPercent: 0, minutesSinceActive: 90,
                                                            foregroundMinutesToday: 0, avgDailyMinutes14d: 1, daysUsed14d: 1,
                                                            launches7d: 1, hourOfDay: 10, isWeekend: 0, playingAudio: 0,
                                                            timesKept: 0, timesQuit: 0),
                        label: .deadweight, source: source)
    }

    func testAtMostOneManualQuitPerAppPerDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9))!
        let evening = morning.addingTimeInterval(10 * 3600)
        let nextDay = morning.addingTimeInterval(24 * 3600)
        let rows = [row("xcode", ManualQuit.source, at: morning), row("maps", "notification", at: morning)]
        XCTAssertTrue(ManualQuit.learnedToday("xcode", in: rows, now: evening, calendar: calendar))
        XCTAssertFalse(ManualQuit.learnedToday("xcode", in: rows, now: nextDay, calendar: calendar))
        XCTAssertFalse(ManualQuit.learnedToday("maps", in: rows, now: evening, calendar: calendar)) // a tapped answer doesn't count
        // Reopened and flipped to keep: the row is a "regret" now, so a later quit that day is learned.
        var flipped = rows
        flipped[0].source = "regret"
        XCTAssertFalse(ManualQuit.learnedToday("xcode", in: flipped, now: evening, calendar: calendar))
    }

    func testReopeningWithinHalfAnHourReturnsTheQuit() {
        var recent = RecentManualQuits()
        recent.learned("notes", at: at(0))
        recent.learned("maps", at: at(0))
        XCTAssertEqual(recent.reopened("notes", at: at(5 * 60)), at(0))
        XCTAssertNil(recent.reopened("notes", at: at(6 * 60)))            // already resolved
        XCTAssertNil(recent.reopened("maps", at: at(31 * 60)))            // too late: it stays "quit"
        XCTAssertNil(recent.reopened("never-quit", at: at(60)))
    }

    func testReopenedManualQuitBecomesKeep() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DeadweightModel(directory: dir)
        model.add(row("notes", "notification", at: at(-3600)))
        model.add(row("notes", ManualQuit.source, at: at(0)))
        var recent = RecentManualQuits()
        recent.learned("notes", at: at(0))
        let quitAt = try! XCTUnwrap(recent.reopened("notes", at: at(120)))
        XCTAssertTrue(model.relabelLatest(key: "notes", since: quitAt, to: .keep))
        XCTAssertEqual(model.examples.map(\.label), [.deadweight, .keep])  // the earlier tapped answer is untouched
        XCTAssertEqual(model.count(source: ManualQuit.source), 0)
    }

    // MARK: Stored answers

    func testManualQuitAnswersAreCountedAndForgotten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func row(_ id: String, _ source: String) -> TrainingExample {
            TrainingExample(date: t0, features: FeatureVector(bundleID: id, memoryMB: 500, cpuPercent: 0, minutesSinceActive: 90,
                                                              foregroundMinutesToday: 0, avgDailyMinutes14d: 1, daysUsed14d: 1,
                                                              launches7d: 1, hourOfDay: 10, isWeekend: 0, playingAudio: 0,
                                                              timesKept: 0, timesQuit: 0),
                            label: .deadweight, source: source)
        }
        let model = DeadweightModel(directory: dir)
        model.add(row("notes", ManualQuit.source))
        model.add(row("notes", "notification"))
        model.add(row("maps", ManualQuit.source))
        XCTAssertEqual(model.count(source: ManualQuit.source), 2)
        XCTAssertEqual(DeadweightModel(directory: dir).count(source: ManualQuit.source), 2) // read back from training.jsonl

        XCTAssertEqual(model.forget(key: "notes"), 2)
        XCTAssertEqual(model.count(source: ManualQuit.source), 1)
        XCTAssertEqual(DeadweightModel(directory: dir).count(source: ManualQuit.source), 1)

        model.reset()
        XCTAssertEqual(model.count(source: ManualQuit.source), 0)
        XCTAssertEqual(DeadweightModel(directory: dir).examples.count, 0)
    }
}
