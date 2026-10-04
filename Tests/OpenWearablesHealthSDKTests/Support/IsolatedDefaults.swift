import XCTest
@testable import OpenWearablesHealthSDK

extension XCTestCase {

    /// Läuft `body` gegen eine frische, eigene Defaults-Suite statt gegen die echte Suite
    /// `com.openwearables.healthsdk.state`.
    ///
    /// Anchors und `fullDone.*` liegen in dieser Suite. Ein Test, der sie anfasst, würde
    /// sonst den Sync-Stand der Host-App überschreiben oder lesen. Der Singleton gehört der
    /// ganzen Suite, deshalb wird der alte Wert gemerkt und danach zurückgesetzt, und die
    /// Test-Suite wird restlos entfernt.
    ///
    /// Grenze: `lazy var mirrorDedupe` hält die Suite, die beim ersten Zugriff galt. Wer
    /// das Ledger testet, braucht eine eigene Naht; die Adoption berührt es nicht.
    ///
    /// Zusammen mit `withIsolatedSDK` nutzen, außen die Defaults, innen das SDK.
    func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let sdk = OpenWearablesHealthSDK.shared
        let previous = sdk.defaults

        let suiteName = "ow-sdk-tests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Defaults-Suite \(suiteName) ließ sich nicht anlegen")
            return
        }

        defer {
            sdk.defaults = previous
            suite.removePersistentDomain(forName: suiteName)
        }

        sdk.defaults = suite
        body(suite)
    }
}
