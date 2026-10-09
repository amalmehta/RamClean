import XCTest
@testable import RamCleanCore

/// Times a real disk scan of your home folder: a first scan, then a refresh that reuses
/// remembered sizes. Opt-in: RAMCLEAN_BENCH=1 swift test --filter ScanBenchmark
final class ScanBenchmark: XCTestCase {
    func testTimeRealScan() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RAMCLEAN_BENCH"] == "1")
        let cache = SizeCache()
        for label in ["first scan", "refresh"] {
            var scanner = DiskScanner()
            scanner.sizeCache = cache
            let t0 = Date()
            var steps: [String] = []
            let report = scanner.scan(progress: { step, _ in steps.append(String(format: "%@ @%.1fs", step, Date().timeIntervalSince(t0))) })
            print("BENCH \(label): \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(report.items.count) items, \(cache.hits) cached sizes reused")
            print("BENCH   steps finished: " + steps.joined(separator: " · "))
        }
    }
}
