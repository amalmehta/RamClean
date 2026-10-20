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
