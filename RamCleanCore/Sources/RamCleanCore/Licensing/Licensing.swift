import Foundation

/// A key activated on this Mac, and when the server last said it was good.
public struct LicenceRecord: Codable, Equatable, Sendable {
    public var key: String
    public var instanceID: String
    public var customerEmail: String?
    public var activatedAt: Date
    public var lastValidated: Date
    /// Set at the first failed check since the last good one; cleared when a check works.
    public var offlineSince: Date?

    public init(key: String, instanceID: String, customerEmail: String? = nil, activatedAt: Date, lastValidated: Date, offlineSince: Date? = nil) {
        self.key = key; self.instanceID = instanceID; self.customerEmail = customerEmail
        self.activatedAt = activatedAt; self.lastValidated = lastValidated; self.offlineSince = offlineSince
    }

    /// The key with all but its last part hidden, for showing in Settings.
    public var maskedKey: String { "••••-" + key.suffix(4) }
}

/// Where this copy stands. Monitoring always works; `unlocksActions` decides whether quitting,
/// trashing, moving files and learning from answers do.
public enum LicenceState: Equatable, Sendable {
    case trial(daysLeft: Int)
    case licensed(email: String?)
    /// Licensed, but the last check couldn't reach the server. Everything still works.
    case offlineGrace(daysLeft: Int)
    case expired(Expiry)
    /// ProductConfig has no store yet: a development copy, with nothing locked.
    case salesNotSetUp

    public enum Expiry: Equatable, Sendable { case trialOver, offlineTooLong }

    public var unlocksActions: Bool {
        if case .expired = self { return false }
        return true
    }

    public var isLicensed: Bool {
        switch self {
        case .licensed, .offlineGrace: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .trial(let d): return "Free trial: \(d) \(d == 1 ? "day" : "days") left"
        case .licensed: return "Licensed"
        case .offlineGrace: return "Licensed (offline)"
        case .expired(.trialOver): return "Trial ended"
        case .expired(.offlineTooLong): return "Licence check overdue"
        case .salesNotSetUp: return "Development copy"
        }
    }

    public func detail(_ config: ProductConfig) -> String {
        switch self {
        case .trial:
            return "Everything works during the trial. Afterwards RamClean keeps watching memory, CPU and disk, and quitting apps, clearing space and learning from your answers need a licence (\(config.price), once)."
        case .licensed(let email):
            return "Thank you for buying \(config.name)." + (email.map { " Registered to \($0)." } ?? "")
        case .offlineGrace(let d):
            return "\(config.name) couldn't reach the licence server. It keeps working for \(d) more \(d == 1 ? "day" : "days") and checks again whenever you're online."
        case .expired(.trialOver):
            return "\(config.name) still watches memory, CPU and disk. Buy a licence (\(config.price), once) to quit apps, clear space and keep learning from your answers."
        case .expired(.offlineTooLong):
            return "\(config.name) hasn't reached the licence server for \(config.offlineGraceDays) days. Connect to the internet and press Check Now."
        case .salesNotSetUp:
            return "Licensing isn't set up in ProductConfig yet (see docs/GO-LIVE.md), so nothing is locked."
        }
    }
}

/// The trial clock and the licence, kept in every store given (the Keychain and UserDefaults),
/// and checked against Lemon Squeezy.
///
/// Resetting the trial needs all copies deleted: the earliest trial start found wins, and is
/// written back to any store that lost it. The latest time seen is kept too, so turning the
/// clock back doesn't add days.
@MainActor
public final class Licensing {
    public let config: ProductConfig
    public let trialStart: Date
    public private(set) var record: LicenceRecord?
    private let stores: [SecureStore]
    private let client: LemonSqueezyClient
    private let instanceName: String
    private let lastSeen: Date
    private var lastAttempt: Date?

    static let trialStartKey = "trialStart", lastSeenKey = "lastSeen", licenceKey = "licence"
    private static let encoder = JSONEncoder(), decoder = JSONDecoder()

    /// `instanceName` labels this Mac in the customer's list of activations.
    public init(config: ProductConfig, stores: [SecureStore], http: HTTPClient, instanceName: String, now: Date = Date()) {
        self.config = config
        self.stores = stores
        self.client = LemonSqueezyClient(config: config, http: http)
        self.instanceName = instanceName
        func dates(_ key: String) -> [Date] { stores.compactMap { $0.data(for: key).flatMap { try? Self.decoder.decode(Date.self, from: $0) } } }
        trialStart = dates(Self.trialStartKey).min() ?? now
        lastSeen = max(dates(Self.lastSeenKey).max() ?? now, now)
        record = stores.compactMap { $0.data(for: Self.licenceKey).flatMap { try? Self.decoder.decode(LicenceRecord.self, from: $0) } }
            .max { $0.lastValidated < $1.lastValidated }
        write(Self.trialStartKey, trialStart)
        write(Self.lastSeenKey, lastSeen)
        saveRecord()
    }

    public func state(now: Date = Date()) -> LicenceState {
        guard config.salesReady else { return .salesNotSetUp }
        let now = max(now, lastSeen)
        let day: TimeInterval = 86_400
        func daysLeft(_ end: Date) -> Int { max(1, Int((end.timeIntervalSince(now) / day).rounded(.up))) }
        // A record dated in the future was edited by hand; it doesn't count.
        if let r = record, r.lastValidated <= now.addingTimeInterval(day) {
            let end = r.lastValidated.addingTimeInterval(Double(config.offlineGraceDays) * day)
            if now >= end { return .expired(.offlineTooLong) }
            return r.offlineSince == nil ? .licensed(email: r.customerEmail) : .offlineGrace(daysLeft: daysLeft(end))
        }
        let end = trialStart.addingTimeInterval(Double(config.trialDays) * day)
        return now < end ? .trial(daysLeft: daysLeft(end)) : .expired(.trialOver)
    }

    /// True when a licensed copy is due a check: every `recheckHours`, or hourly while offline.
    public func needsCheck(now: Date = Date()) -> Bool {
        guard config.salesReady, let r = record else { return false }
        guard let last = lastAttempt else { return true }
        let every = r.offlineSince == nil ? config.recheckHours * 3600 : 3600
        return now.timeIntervalSince(last) >= every
    }

    /// Activates the key on this Mac. Throws `LicenceError` with a message to show.
    @discardableResult
    public func activate(key raw: String, now: Date = Date()) async throws -> LicenceState {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenceError.rejected("Paste your licence key first.") }
        lastAttempt = now
        let check = try await client.activate(key: key, instanceName: instanceName)
        record = LicenceRecord(key: key, instanceID: check.instanceID ?? "", customerEmail: check.customerEmail,
                               activatedAt: now, lastValidated: now)
        saveRecord()
        return state(now: now)
    }

    /// Re-checks the key. Offline keeps the licence (the grace period runs); a refusal (refunded,
    /// disabled, or deactivated from another Mac) removes it. Returns the problem, if any.
    @discardableResult
    public func refresh(now: Date = Date()) async -> LicenceError? {
        guard let r = record else { return nil }
        lastAttempt = now
        do {
            let check = try await client.validate(key: r.key, instanceID: r.instanceID)
            guard record?.key == r.key else { return nil }
            record?.lastValidated = now
            record?.offlineSince = nil
            if let email = check.customerEmail { record?.customerEmail = email }
            saveRecord()
            return nil
        } catch let error as LicenceError {
            guard record?.key == r.key else { return nil }
            switch error {
            case .offline:
                if record?.offlineSince == nil { record?.offlineSince = now }
            case .rejected:
                record = nil
            case .notConfigured:
                return error
            }
            saveRecord()
            return error
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    /// Frees this Mac's activation so the key can be used on another one. If the server can't be
    /// reached it throws and keeps the licence; `forget()` removes it locally anyway.
    public func deactivate() async throws {
        guard let r = record else { return }
        try await client.deactivate(key: r.key, instanceID: r.instanceID)
        forget()
    }

    public func forget() {
        record = nil
        saveRecord()
    }

    private func write(_ key: String, _ date: Date) {
        let data = try? Self.encoder.encode(date)
        stores.forEach { $0.set(data, for: key) }
    }

    private func saveRecord() {
        let data = record.flatMap { try? Self.encoder.encode($0) }
        stores.forEach { $0.set(data, for: Self.licenceKey) }
    }
}
