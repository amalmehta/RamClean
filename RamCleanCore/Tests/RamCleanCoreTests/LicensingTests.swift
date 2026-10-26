import XCTest
@testable import RamCleanCore

/// Answers licence calls from a script instead of the network, and remembers what was asked.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    enum Reply { case json(Int, String), fail }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private(set) var calls: [(action: String, form: [String: String])] = []

    func reply(_ action: String, _ r: Reply) { lock.withLock { replies[action] = r } }

    func post(_ url: URL, form: [String: String]) async throws -> (status: Int, body: Data) {
        let action = url.lastPathComponent
        let reply = lock.withLock {
            calls.append((action, form))
            return replies[action]
        }
        switch reply {
        case .json(let status, let body): return (status, Data(body.utf8))
        case .fail, nil: throw URLError(.notConnectedToInternet)
        }
    }
}

@MainActor
final class LicensingTests: XCTestCase {
    let day: TimeInterval = 86_400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var keychain = MemoryStore(), defaults = MemoryStore()
    var http = FakeHTTP()

    let config = ProductConfig(name: "RamClean", price: "$5", trialDays: 14, offlineGraceDays: 14, recheckHours: 24,
                               checkoutURL: URL(string: "https://shop.example.com/buy/1")!,
                               websiteURL: URL(string: "https://example.com")!,
                               appcastURL: URL(string: "https://example.com/appcast.xml")!,
                               lemonSqueezyStoreID: 111, lemonSqueezyProductID: 222)

    func make(_ now: Date, config: ProductConfig? = nil) -> Licensing {
        Licensing(config: config ?? self.config, stores: [keychain, defaults], http: http, instanceName: "Test Mac", now: now)
    }

    func answer(_ flag: String, _ ok: Bool, store: Int = 111, product: Int = 222, status: String = "active", error: String? = nil) -> String {
        """
        {"\(flag)": \(ok), "error": \(error.map { "\"\($0)\"" } ?? "null"),
         "license_key": {"id": 1, "status": "\(status)", "key": "ABC-123"},
         "instance": {"id": "inst-1", "name": "Test Mac"},
         "meta": {"store_id": \(store), "product_id": \(product), "customer_email": "a@example.com"}}
        """
    }

    func testTrialCountsDownThenExpires() {
        XCTAssertEqual(make(t0).state(now: t0), .trial(daysLeft: 14))
        XCTAssertEqual(make(t0).state(now: t0 + 13.5 * day), .trial(daysLeft: 1))
        let ended = make(t0).state(now: t0 + 14 * day)
        XCTAssertEqual(ended, .expired(.trialOver))
        XCTAssertFalse(ended.unlocksActions)
        XCTAssertTrue(LicenceState.trial(daysLeft: 3).unlocksActions)
    }

    func testDeletingOneCopyDoesNotResetTheTrial() {
        _ = make(t0)
        defaults.values = [:]  // "defaults delete com.amalmehta.RamClean"
        XCTAssertEqual(make(t0 + 20 * day).state(now: t0 + 20 * day), .expired(.trialOver))
        XCTAssertNotNil(defaults.values[Licensing.trialStartKey], "the lost copy is written back")
        keychain.values = [:]
        XCTAssertEqual(make(t0 + 21 * day).trialStart, t0)
    }

    func testTurningTheClockBackDoesNotAddDays() {
        _ = make(t0 + 10 * day)  // first seen on day 10
        let l = make(t0 + 10 * day)
        XCTAssertEqual(l.state(now: t0 + 10 * day), .trial(daysLeft: 14))
        let rolledBack = make(t0)
        XCTAssertEqual(rolledBack.state(now: t0), .trial(daysLeft: 14), "the clock is treated as day 10, not day 0")
    }

    func testAFreeCopyHasNoTrialAndNothingLocked() {
        var free = config
        free.isFree = true
        let l = make(t0, config: free)
        XCTAssertEqual(l.state(now: t0 + 400 * day), .free, "even with a store set up, free wins")
        XCTAssertTrue(l.state(now: t0 + 400 * day).unlocksActions)
        XCTAssertFalse(l.needsCheck(now: t0 + 400 * day))
        XCTAssertTrue(ProductConfig.ramClean.isFree, "RamClean ships free; Pro comes later")
    }

    func testNothingLocksUntilSalesAreSetUp() {
        var unset = config
        unset.lemonSqueezyStoreID = 0
        let l = make(t0, config: unset)
        XCTAssertEqual(l.state(now: t0 + 100 * day), .salesNotSetUp)
        XCTAssertTrue(l.state(now: t0 + 100 * day).unlocksActions)
        XCTAssertFalse(ProductConfig.ramClean.salesReady, "the shipped placeholders aren't a real store")
    }

    func testActivateSendsKeyAndStoresLicence() async throws {
        http.reply("activate", .json(200, answer("activated", true)))
        let l = make(t0 + 30 * day)
        let state = try await l.activate(key: "  ABC-123\n", now: t0 + 30 * day)
        XCTAssertEqual(state, .licensed(email: "a@example.com"))
        XCTAssertEqual(http.calls.first?.form, ["license_key": "ABC-123", "instance_name": "Test Mac"])
        XCTAssertEqual(l.record?.instanceID, "inst-1")
        // Survives a relaunch, from either copy.
        defaults.values = [:]
        XCTAssertEqual(make(t0 + 31 * day).state(now: t0 + 31 * day), .licensed(email: "a@example.com"))
    }

    func testActivateRefusesOtherProductsAndShowsServerErrors() async {
        let l = make(t0)
        http.reply("activate", .json(200, answer("activated", true, product: 999)))
        await assertThrows(try await l.activate(key: "K", now: t0), .rejected("That licence key is for a different product."))
        http.reply("activate", .json(400, answer("activated", false, error: "This license key has reached the activation limit.")))
        await assertThrows(try await l.activate(key: "K", now: t0), .rejected("This license key has reached the activation limit."))
        http.reply("activate", .json(404, #"{"error": "license_key not found"}"#))
        await assertThrows(try await l.activate(key: "K", now: t0), .rejected("License_key not found."))
        http.reply("activate", .fail)
        do { try await l.activate(key: "K", now: t0); XCTFail("should throw") } catch let e as LicenceError {
            guard case .offline = e else { return XCTFail("expected offline, got \(e)") }
        } catch { XCTFail("\(error)") }
        XCTAssertNil(l.record)
        XCTAssertEqual(l.state(now: t0), .trial(daysLeft: 14))
    }

    func testOfflineGraceThenExpiryThenRecovery() async throws {
        http.reply("activate", .json(200, answer("activated", true)))
        let l = make(t0)
        try await l.activate(key: "ABC-123", now: t0)
        XCTAssertFalse(l.needsCheck(now: t0 + 3600))
        XCTAssertTrue(l.needsCheck(now: t0 + 25 * 3600))

        http.reply("validate", .fail)
        let problem = await l.refresh(now: t0 + 2 * day)
        if case .offline = problem {} else { XCTFail("expected offline, got \(String(describing: problem))") }
        XCTAssertEqual(l.state(now: t0 + 2 * day), .offlineGrace(daysLeft: 12))
        XCTAssertTrue(l.state(now: t0 + 2 * day).unlocksActions)
        XCTAssertTrue(l.needsCheck(now: t0 + 2 * day + 3600), "retries hourly while offline")
        XCTAssertEqual(l.state(now: t0 + 14 * day), .expired(.offlineTooLong))

        http.reply("validate", .json(200, answer("valid", true)))
        let fine = await l.refresh(now: t0 + 15 * day)
        XCTAssertNil(fine)
        XCTAssertEqual(l.state(now: t0 + 15 * day), .licensed(email: "a@example.com"))
        XCTAssertEqual(http.calls.last?.form, ["license_key": "ABC-123", "instance_id": "inst-1"])
    }

    func testServerTroubleIsOfflineNotARefusal() async throws {
        http.reply("activate", .json(200, answer("activated", true)))
        let l = make(t0)
        try await l.activate(key: "ABC-123", now: t0)
        for status in [500, 503, 429] {
            http.reply("validate", .json(status, "<html>oops</html>"))
            _ = await l.refresh(now: t0 + day)
            XCTAssertNotNil(l.record, "a \(status) keeps the licence")
        }
        XCTAssertEqual(l.state(now: t0 + day), .offlineGrace(daysLeft: 13))
    }

    func testRefundedKeyIsRemoved() async throws {
        http.reply("activate", .json(200, answer("activated", true)))
        let l = make(t0)
        try await l.activate(key: "ABC-123", now: t0)
        http.reply("validate", .json(200, answer("valid", true, status: "disabled")))
        let problem = await l.refresh(now: t0 + 20 * day)
        XCTAssertEqual(problem, .rejected("This licence key has been disabled."))
        XCTAssertNil(l.record)
        XCTAssertNil(keychain.values[Licensing.licenceKey])
        XCTAssertEqual(l.state(now: t0 + 20 * day), .expired(.trialOver))
    }

    func testDeactivateFreesTheActivationOrKeepsItWhenOffline() async throws {
        http.reply("activate", .json(200, answer("activated", true)))
        let l = make(t0)
        try await l.activate(key: "ABC-123", now: t0)
        http.reply("deactivate", .fail)
        do { try await l.deactivate(); XCTFail("should throw offline") } catch {}
        XCTAssertNotNil(l.record)
        http.reply("deactivate", .json(200, answer("deactivated", true)))
        try await l.deactivate()
        XCTAssertEqual(http.calls.last?.form, ["license_key": "ABC-123", "instance_id": "inst-1"])
        XCTAssertNil(l.record)
        XCTAssertNil(defaults.values[Licensing.licenceKey])
    }

    func testHandEditedFutureRecordDoesNotUnlock() throws {
        _ = make(t0)
        let forged = LicenceRecord(key: "X", instanceID: "i", activatedAt: t0, lastValidated: t0 + 400 * day)
        keychain.values[Licensing.licenceKey] = try JSONEncoder().encode(forged)
        XCTAssertEqual(make(t0 + 30 * day).state(now: t0 + 30 * day), .expired(.trialOver))
    }

    func testStateTextAndFormEncoding() {
        XCTAssertEqual(LicenceState.trial(daysLeft: 1).title, "Free trial: 1 day left")
        XCTAssertTrue(LicenceState.expired(.trialOver).detail(config).contains("$5"))
        XCTAssertEqual(LemonSqueezyClient.formEncode(["license_key": "A+B C", "instance_name": "Amal's Mac"]),
                       "instance_name=Amal%27s%20Mac&license_key=A%2BB%20C")
        XCTAssertEqual(LicenceRecord(key: "38b1460a-5104-4067-a91d-77b872934d51", instanceID: "", activatedAt: t0, lastValidated: t0).maskedKey,
                       "••••-4d51")
    }

    private func assertThrows(_ body: @autoclosure () async throws -> LicenceState, _ expected: LicenceError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LicenceError, expected, file: file, line: line)
        }
    }
}
