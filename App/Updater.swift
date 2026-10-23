import Combine
import Foundation
import RamCleanCore
import Sparkle

/// Sparkle 2 updates from the appcast in ProductConfig. It only starts once both the feed and
/// the public signing key (`SUPublicEDKey` in project.yml) are filled in, so a development copy
/// never shows an "updater failed to start" error.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    let isConfigured: Bool
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    private override init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = ProductConfig.ramClean.updatesReady && !key.isEmpty
        super.init()
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProductConfig.ramClean.appcastURL.absoluteString
    }
}
