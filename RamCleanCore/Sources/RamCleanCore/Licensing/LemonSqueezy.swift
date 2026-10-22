import Foundation

/// The one network call licensing needs: a form POST. Tests swap in a fake.
public protocol HTTPClient: Sendable {
    func post(_ url: URL, form: [String: String]) async throws -> (status: Int, body: Data)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func post(_ url: URL, form: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(LemonSqueezyClient.formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public enum LicenceError: Error, Equatable, LocalizedError {
    /// Couldn't reach the server, or it had a problem: try again later, the licence stays.
    case offline(String)
    /// The server said no: wrong key, activation limit, refunded, or another product's key.
    case rejected(String)
    /// The store and product IDs aren't filled in yet (ProductConfig).
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .offline(let why): return "Couldn't reach the licence server (\(why)). Check your internet connection and try again."
        case .rejected(let why): return why
        case .notConfigured: return "This copy of RamClean isn't set up for sales yet."
        }
    }
}

/// What the server said about a key.
public struct LicenceCheck: Equatable, Sendable {
    public var instanceID: String?
    /// active, inactive, expired or disabled.
    public var status: String
    public var customerEmail: String?
}

/// Lemon Squeezy's License API: activate a key on this Mac, validate it, deactivate it.
/// https://docs.lemonsqueezy.com/api/license-api
public struct LemonSqueezyClient: Sendable {
    public let config: ProductConfig
    public let http: HTTPClient

    public init(config: ProductConfig, http: HTTPClient) { self.config = config; self.http = http }

    public func activate(key: String, instanceName: String) async throws -> LicenceCheck {
        let r = try await call("activate", ["license_key": key, "instance_name": instanceName])
        guard r.activated == true else { throw LicenceError.rejected(r.error.map(Self.sentence) ?? "That licence key wasn't accepted.") }
        let check = try checked(r)
        guard check.instanceID != nil else { throw LicenceError.offline("no activation ID in the answer") }
        return check
    }

    public func validate(key: String, instanceID: String) async throws -> LicenceCheck {
        let r = try await call("validate", ["license_key": key, "instance_id": instanceID])
        guard r.valid == true else { throw LicenceError.rejected(r.error.map(Self.sentence) ?? "This licence is no longer valid.") }
        return try checked(r)
    }

    public func deactivate(key: String, instanceID: String) async throws {
        let r = try await call("deactivate", ["license_key": key, "instance_id": instanceID])
        guard r.deactivated == true else { throw LicenceError.rejected(r.error ?? "Couldn't deactivate this Mac.") }
    }

    /// Any Lemon Squeezy store's keys validate against the same API, so the answer must name ours.
    private func checked(_ r: Response) throws -> LicenceCheck {
        guard let meta = r.meta, meta.storeId == config.lemonSqueezyStoreID, meta.productId == config.lemonSqueezyProductID else {
            throw LicenceError.rejected("That licence key is for a different product.")
        }
        let status = r.licenseKey?.status ?? "active"
        guard status != "expired", status != "disabled" else { throw LicenceError.rejected("This licence key has been \(status).") }
        return LicenceCheck(instanceID: r.instance?.id, status: status, customerEmail: meta.customerEmail)
    }

    private func call(_ action: String, _ form: [String: String]) async throws -> Response {
        guard config.salesReady else { throw LicenceError.notConfigured }
        let status: Int, body: Data
        do {
            (status, body) = try await http.post(config.licenceAPI.appendingPathComponent(action), form: form)
        } catch {
            throw LicenceError.offline(error.localizedDescription)
        }
        // Server trouble or rate limiting says nothing about the key.
        if status == 0 || status == 429 || status >= 500 { throw LicenceError.offline("the server answered \(status)") }
        guard let r = try? Self.decoder.decode(Response.self, from: body) else {
            if (200..<300).contains(status) { throw LicenceError.offline("an answer RamClean couldn't read") }
            throw LicenceError.rejected("That licence key wasn't accepted (\(status)).")
        }
        return r
    }

    private static func sentence(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst() + (s.hasSuffix(".") ? "" : ".")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    struct Response: Decodable {
        var activated: Bool?
        var valid: Bool?
        var deactivated: Bool?
        var error: String?
        var licenseKey: Key?
        var instance: Instance?
        var meta: Meta?

        struct Key: Decodable { var status: String? }
        struct Instance: Decodable { var id: String }
        struct Meta: Decodable {
            var storeId: Int
            var productId: Int
            var customerEmail: String?
        }
    }
}
