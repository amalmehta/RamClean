import AppKit
import XCTest
@testable import RamCleanCore

/// Times one round of the sampling RamClean does on every check.
/// Opt-in: RAMCLEAN_BENCH=1 swift test --filter SampleBenchmark
final class SampleBenchmark: XCTestCase {
    func testTimeSampling() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RAMCLEAN_BENCH"] == "1")
        let procs = ProcessSampler(), system = SystemSampler()
        _ = procs.sample(); _ = system.sample()
        for _ in 0..<3 {
            var t = Date(); let p = procs.sample(); let tp = Date().timeIntervalSince(t)
            t = Date(); _ = system.sample(); let ts = Date().timeIntervalSince(t)
            t = Date(); _ = AudioActivity.pidsPlayingAudio(); let ta = Date().timeIntervalSince(t)
            t = Date(); _ = AppGrouper.group(p, apps: []); let tg = Date().timeIntervalSince(t)
            print(String(format: "BENCH processes %.0f ms (%d), system %.0f ms, audio %.0f ms, grouping %.0f ms",
                         tp * 1000, p.count, ts * 1000, ta * 1000, tg * 1000))
        }
    }
}

/// Times judging every app with your real trained model (a copy of RamClean's data folder).
/// Opt-in: RAMCLEAN_BENCH=1 swift test --filter AssessBenchmark
final class AssessBenchmark: XCTestCase {
    func testTimeAssessing() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RAMCLEAN_BENCH"] == "1")
        let fm = FileManager.default
        let real = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RamClean")
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for f in ["training.jsonl", "habits.json", "meta.json"] {
            try? fm.copyItem(at: real.appendingPathComponent(f), to: dir.appendingPathComponent(f))
        }
        let model = DeadweightModel(directory: dir), store = HabitStore(directory: dir)
        try XCTSkipUnless(model.train().isTrained, "needs a trained model")
        let running = NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "",
                           bundlePath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular)
        }
        let groups = AppGrouper.group(ProcessSampler().sample(), apps: running)
        let assessor = Assessor(prefs: Preferences(), frontmostKey: nil, selfBundleID: nil, audioPIDs: [], cpuAverages: [:], now: Date())
        for _ in 0..<3 {
            let t = Date()
            let result = assessor.assess(groups, stats: { store.stats(for: $0, now: Date()) }, score: { model.score($0) })
            print(String(format: "BENCH assess %.0f ms for %d groups (%d scored by the model)",
                         Date().timeIntervalSince(t) * 1000, groups.count, result.filter(\.usedModel).count))
        }
    }
}
