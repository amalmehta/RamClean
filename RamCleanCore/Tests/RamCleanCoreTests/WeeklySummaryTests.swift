import XCTest
@testable import RamCleanCore

final class WeeklySummaryTests: XCTestCase {
    private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private let gib: UInt64 = 1 << 30

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// Fixtures/week-events.jsonl: the week of Monday 12 October 2026, with a week of answers
    /// before it and a few events the next Monday.
    private func fixture() throws -> [HabitEvent] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "week-events", withExtension: "jsonl", subdirectory: "Fixtures"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("events.jsonl"))
        return HabitStore.allEvents(in: dir)
    }

    private func fixtureWeek() throws -> WeeklySummary {
        let week = WeeklySummary.week(containing: date("2026-10-15T12:00:00Z"), calendar: utc)
        return WeeklySummary.make(events: try fixture(), interval: week)
    }

    func testFixtureLoadsEveryEvent() throws {
        XCTAssertEqual(try fixture().count, 43)
    }

    func testWeekRunsMondayToMonday() {
        let week = WeeklySummary.week(containing: date("2026-10-18T23:59:59Z"), calendar: utc)
        XCTAssertEqual(week.start, date("2026-10-12T00:00:00Z"))
        XCTAssertEqual(week.end, date("2026-10-19T00:00:00Z"))
        XCTAssertEqual(WeeklySummary.week(containing: date("2026-10-12T00:00:00Z"), calendar: utc), week)
        XCTAssertEqual(WeeklySummary.week(before: date("2026-10-19T09:00:00Z"), calendar: utc), week)
    }

    func testMemoryFreedCountsQuitsThatHappened() throws {
        let s = try fixtureWeek()
        // Spotify 1 GB, Slack 2 + 1 + 1 + 1 + 1 GB, Notion 512 MB. Zoom never quit; next Monday's quit is next week's.
        XCTAssertEqual(s.quits, 7)
        XCTAssertEqual(s.memoryFreed, 7 * gib + gib / 2)
    }

    func testDiskReclaimedCountsTheWeeksCleanups() throws {
        let s = try fixtureWeek()
        // Trash 3 GB, brew cleanup 1 GB, moved off 10 GB, and an older-format event with no size.
        XCTAssertEqual(s.diskItems, 4)
        XCTAssertEqual(s.diskReclaimed, 14 * gib)
    }

    func testAcceptedVersusDismissed() throws {
        let s = try fixtureWeek()
        XCTAssertEqual(s.accepted, 8, "every Quit answer, including the one that never quit")
        XCTAssertEqual(s.dismissed, 6, "Keep and Always keep")
        XCTAssertEqual(s.reopened, 1)
    }

    func testTopDeadweightAndKeepers() throws {
        let s = try fixtureWeek()
        XCTAssertEqual(s.deadweight.map(\.name), ["Spotify", "Slack"])
        XCTAssertEqual(s.deadweight.first.map { [$0.quits, $0.keeps] }, [3, 1])
        XCTAssertEqual(s.keepers.map(\.name), ["Google Chrome", "Figma", "Xcode"])
        let listed = Set((s.deadweight + s.keepers).map(\.key))
        XCTAssertFalse(listed.contains("us.zoom.xos"), "the quit that never happened is taken back")
        XCTAssertFalse(listed.contains("notion.id"), "a reset app has nothing learned")
    }

    func testLabelsThatFlippedThisWeek() throws {
        let s = try fixtureWeek()
        XCTAssertEqual(s.flipped, [
            LabelFlip(key: "com.figma.Desktop", name: "Figma", from: .deadweight, to: .keep),
            LabelFlip(key: "com.tinyspeck.slackmacgap", name: "Slack", from: .keep, to: .deadweight),
        ])
    }

    func testLastWeekOfTheFixtureIsCountedSeparately() throws {
        let s = WeeklySummary.make(events: try fixture(), interval: WeeklySummary.week(before: date("2026-10-12T09:00:00Z"), calendar: utc))
        XCTAssertEqual(s.accepted, 3)
        XCTAssertEqual(s.dismissed, 3)
        XCTAssertEqual(s.diskReclaimed, 5 * gib)
        XCTAssertTrue(s.flipped.isEmpty, "nothing was learned before it to flip from")
    }

    func testTopListsStopAtFive() {
        let start = date("2026-10-12T09:00:00Z")
        var events: [HabitEvent] = []
        for i in 0..<7 {
            for n in 0...i { events.append(HabitEvent(date: start.addingTimeInterval(Double(i * 100 + n)), kind: .kept, key: "app\(i)", name: "App \(i)")) }
        }
        let s = WeeklySummary.make(events: events, interval: WeeklySummary.week(containing: start, calendar: utc))
        XCTAssertEqual(s.keepers.map(\.name), ["App 6", "App 5", "App 4", "App 3", "App 2"], "the most clear-cut first")
        XCTAssertTrue(s.deadweight.isEmpty)
    }

    func testOnlyTheLastTenAnswersCount() {
        let start = date("2026-10-12T09:00:00Z")
        let kinds: [HabitEventKind] = Array(repeating: .quitBySuggestion, count: 6) + Array(repeating: .kept, count: 6)
        let events = kinds.enumerated().map { HabitEvent(date: start.addingTimeInterval(Double($0.offset)), kind: $0.element, key: "a", name: "A") }
        let app = WeeklySummary.learned(events)["a"]
        XCTAssertEqual(app?.quits, 4)
        XCTAssertEqual(app?.keeps, 6)
        XCTAssertEqual(app?.label, .keep)
    }

    func testNotificationText() throws {
        let text = try fixtureWeek().notificationText
        XCTAssertEqual(text.title, "Your week with RamClean")
        XCTAssertTrue(text.body.hasPrefix("Freed 7.5 GB of memory over 7 quits and reclaimed 14 GB of disk."), text.body)
        XCTAssertTrue(text.body.contains("You took 8 of 14 suggestions."))
        XCTAssertTrue(text.body.hasSuffix("Changed its mind about Figma and 1 more."))
    }

    func testEmptyWeek() {
        let s = WeeklySummary.make(events: [], interval: WeeklySummary.week(containing: Date(), calendar: utc))
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.notificationText.body, "")
    }

    func testNotificationIsDueOnceFromMondayNine() {
        let sentLastWeek = date("2026-10-05T09:00:00Z")
        XCTAssertFalse(WeeklySummary.notificationDue(now: date("2026-10-12T08:59:00Z"), lastSent: sentLastWeek, calendar: utc))
        XCTAssertTrue(WeeklySummary.notificationDue(now: date("2026-10-12T09:00:00Z"), lastSent: sentLastWeek, calendar: utc))
        XCTAssertTrue(WeeklySummary.notificationDue(now: date("2026-10-14T15:00:00Z"), lastSent: sentLastWeek, calendar: utc),
                      "a Mac asleep on Monday morning gets it at its next check")
        XCTAssertFalse(WeeklySummary.notificationDue(now: date("2026-10-12T10:00:00Z"), lastSent: date("2026-10-12T09:00:30Z"), calendar: utc))
        XCTAssertFalse(WeeklySummary.notificationDue(now: date("2026-10-18T22:00:00Z"), lastSent: date("2026-10-12T09:00:30Z"), calendar: utc))
        XCTAssertTrue(WeeklySummary.notificationDue(now: date("2026-10-19T09:01:00Z"), lastSent: date("2026-10-12T09:00:30Z"), calendar: utc))
    }

    func testResettingAnAppForgetsItsAnswers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HabitStore(directory: dir), now = date("2026-10-14T10:00:00Z")
        store.recordDecision(.quitBySuggestion, key: "k", name: "K", bytes: gib, at: now)
        store.recordDecision(.quitBySuggestion, key: "k", name: "K", at: now)
        store.recordDecision(.kept, key: "other", name: "Other", at: now)
        store.forget(key: "k", name: "K", at: now.addingTimeInterval(60))
        XCTAssertEqual(store.stats(for: "k", now: now).recentAnswers, [])
        XCTAssertEqual(store.stats(for: "k", now: now).timesQuit, 0)
        XCTAssertEqual(store.stats(for: "other", now: now).recentAnswers, [.kept])

        let events = HabitStore.allEvents(in: dir)
        XCTAssertEqual(events.first?.bytes, gib, "bytes survive the round trip")
        let s = WeeklySummary.make(events: events, interval: WeeklySummary.week(containing: now, calendar: utc))
        XCTAssertEqual(s.accepted, 2, "the week's counts keep what happened")
        XCTAssertEqual(s.deadweight, [])
        XCTAssertEqual(s.keepers.map(\.key), ["other"])
    }

    func testModelForgetsOneAppsAnswers() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DeadweightModel(directory: dir)
        func example(_ id: String, _ label: Label) -> TrainingExample {
            let f = FeatureVector(bundleID: id, memoryMB: 900, cpuPercent: 1, minutesSinceActive: 600, foregroundMinutesToday: 0,
                                  avgDailyMinutes14d: 1, daysUsed14d: 1, launches7d: 1, hourOfDay: 14, isWeekend: 0,
                                  playingAudio: 0, timesKept: 0, timesQuit: 0)
            return TrainingExample(date: Date(), features: f, label: label, source: "test")
        }
        model.add(example("a", .deadweight)); model.add(example("a", .keep)); model.add(example("b", .keep))
        XCTAssertEqual(model.forget(key: "a"), 2)
        XCTAssertEqual(model.examples.map(\.features.bundleID), ["b"])
        XCTAssertEqual(DeadweightModel(directory: dir).examples.count, 1, "saved to disk")
        XCTAssertEqual(model.forget(key: "missing"), 0)
    }

    func testOlderEventsWithoutBytesStillDecode() throws {
        let line = #"{"id":"00000000-0000-0000-0000-000000000001","date":"2026-10-12T09:00:00Z","kind":"quitBySuggestion","key":"k","name":"K"}"#
        let e = try HabitStore.decoder.decode(HabitEvent.self, from: Data(line.utf8))
        XCTAssertNil(e.bytes)
        XCTAssertEqual(e.kind, .quitBySuggestion)
    }

    func testPutBackTakesItsSpaceOffTheWeek() {
        let week = WeeklySummary.week(containing: date("2026-10-15T12:00:00Z"), calendar: utc)
        func e(_ kind: HabitEventKind, _ bytes: UInt64, _ at: String) -> HabitEvent {
            HabitEvent(date: date(at), kind: kind, key: "disk", name: "x", detail: nil, bytes: bytes)
        }
        let s = WeeklySummary.make(events: [e(.movedToTrash, 3 * gib, "2026-10-13T10:00:00Z"), e(.movedToTrash, gib, "2026-10-13T10:00:00Z"),
                                            e(.putBack, gib, "2026-10-13T10:01:00Z")], interval: week)
        XCTAssertEqual(s.diskItems, 1)
        XCTAssertEqual(s.diskReclaimed, 3 * gib)
        // A put-back of something moved before the week can't go below zero.
        let lone = WeeklySummary.make(events: [e(.putBack, gib, "2026-10-13T10:00:00Z")], interval: week)
        XCTAssertEqual(lone.diskItems, 0)
        XCTAssertEqual(lone.diskReclaimed, 0)
    }
}
