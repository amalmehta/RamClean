import Foundation

/// Everything about selling and updating RamClean, in one place. Change the values in
/// `ramClean` below; see docs/GO-LIVE.md for where each one comes from.
///
/// The website (`site/`) shows the price and Buy link too, so change them there as well.
public struct ProductConfig: Sendable {
    public var name: String
    /// Shown on the Buy button and in the Licence settings.
    public var price: String
    /// Days of the full app from first launch.
    public var trialDays: Int
    /// How long a licensed copy keeps working without reaching the licence server.
    public var offlineGraceDays: Int
    /// How often a licensed copy re-checks its key when online.
    public var recheckHours: Double
    /// Lemon Squeezy checkout link for the product (Products → Share).
    public var checkoutURL: URL
    public var websiteURL: URL
    /// Sparkle's update feed. The public signing key goes in project.yml (`SUPublicEDKey`).
    public var appcastURL: URL
    /// From Lemon Squeezy (Settings → Stores, and the product's page). Keys from any other
    /// store or product are refused. 0 means not set up yet.
    public var lemonSqueezyStoreID: Int
    public var lemonSqueezyProductID: Int
    /// Lemon Squeezy's public License API. It needs no secret key.
    public var licenceAPI: URL
    /// Free for everyone: no trial clock, no Buy button, nothing locked. The licence code stays
    /// for a paid Pro version later; set this to false and fill in the store to turn it on.
    public var isFree: Bool

    public init(name: String, price: String, trialDays: Int, offlineGraceDays: Int, recheckHours: Double,
                checkoutURL: URL, websiteURL: URL, appcastURL: URL,
                lemonSqueezyStoreID: Int, lemonSqueezyProductID: Int,
                licenceAPI: URL = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!, isFree: Bool = false) {
        self.name = name; self.price = price; self.trialDays = trialDays; self.offlineGraceDays = offlineGraceDays
        self.recheckHours = recheckHours; self.checkoutURL = checkoutURL; self.websiteURL = websiteURL
        self.appcastURL = appcastURL; self.lemonSqueezyStoreID = lemonSqueezyStoreID
        self.lemonSqueezyProductID = lemonSqueezyProductID; self.licenceAPI = licenceAPI
        self.isFree = isFree
    }

    /// Placeholder text that scripts/release.sh refuses to ship.
    public static let placeholder = "REPLACE-ME"

    public static let ramClean = ProductConfig(
        name: "RamClean",
        price: "$5",
        trialDays: 14,
        offlineGraceDays: 14,
        recheckHours: 24,
        checkoutURL: URL(string: "https://REPLACE-ME.lemonsqueezy.com/buy/REPLACE-ME")!,
        websiteURL: URL(string: "https://REPLACE-ME.example.com")!,
        appcastURL: URL(string: "https://REPLACE-ME.example.com/updates/appcast.xml")!,
        lemonSqueezyStoreID: 0,
        lemonSqueezyProductID: 0,
        isFree: true
    )

    /// True once the store and product IDs and the checkout link are filled in. Until then the
    /// trial clock runs but nothing is locked, so a development copy never locks its owner out.
    public var salesReady: Bool {
        lemonSqueezyStoreID > 0 && lemonSqueezyProductID > 0 && !checkoutURL.absoluteString.contains(Self.placeholder)
    }

    public var updatesReady: Bool { !appcastURL.absoluteString.contains(Self.placeholder) }
}
