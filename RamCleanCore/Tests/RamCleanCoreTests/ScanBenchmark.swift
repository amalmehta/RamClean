import XCTest
@testable import RamCleanCore

/// Times each step of a real disk scan of your home folder. Opt-in: RAMCLEAN_BENCH=1 swift test --filter ScanBenchmark
final class ScanBenchmark: XCTestCase {
    func testTimeRealScan() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RAMCLEAN_BENCH"] == "1")
        var last = Date(), lastStep = "start"
        let t0 = Date()
        let report = DiskScanner().scan(progress: { step, _ in
            print(String(format: "BENCH %-45@ %6.1fs", lastStep as NSString, Date().timeIntervalSince(last)))
            last = Date(); lastStep = step
        })
        print(String(format: "BENCH %-45@ %6.1fs", lastStep as NSString, Date().timeIntervalSince(last)))
        print(String(format: "BENCH TOTAL %.1fs, %d items", Date().timeIntervalSince(t0), report.items.count))
    }
}
