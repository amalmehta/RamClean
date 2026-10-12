import XCTest
@testable import RamCleanCore

/// Times a real disk scan of your home folder: a first scan, a refresh that reuses remembered
/// sizes, and a scan after an app relaunch (sizes reloaded from disk).
/// Opt-in: RAMCLEAN_BENCH=1 swift test --filter ScanBenchmark
final class ScanBenchmark: XCTestCase {
    func testTimeRealScan() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RAMCLEAN_BENCH"] == "1")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ramclean-bench-sizes.json")
        try? FileManager.default.removeItem(at: file)
        var cache = SizeCache()
        for label in ["first scan", "refresh", "after relaunch"] {
            if label == "after relaunch" { cache.save(to: file); cache = SizeCache(contentsOf: file) }
            var scanner = DiskScanner()
            scanner.sizeCache = cache
            let t0 = Date()
            var firstCache: Double?, lastCache = 0.0
            let report = scanner.scan(progress: { _, found in
                let caches = found.filter { $0.kind == .cache }.count
                if caches > 0 { firstCache = firstCache ?? Date().timeIntervalSince(t0); lastCache = Date().timeIntervalSince(t0) }
            })
            print(String(format: "BENCH %@: %.1fs total; caches shown from %.1fs to %.1fs; %d items",
                         label, Date().timeIntervalSince(t0), firstCache ?? -1, lastCache, report.items.count))
        }
    }
}

