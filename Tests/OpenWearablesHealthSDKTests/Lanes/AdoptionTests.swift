import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Die Neu-Export-Falle (Befund 4, Recherche vom 04.10.2026):
///
/// 0.14 und 0.15 werten `fullDone.<userKey>` aus, das am iPhone 18 Pro unter dem falschen
/// Schlüssel (`user.none`) steht. Ohne Adoption beginnt der erste Lauf nach dem Update
/// einen Export über das ganze Fenster und alle Typen. Diese Tests laufen gegen die
/// Fixture des echten Gerätezustands und gegen die Ränder der Adoption.
final class AdoptionTests: XCTestCase {

    // MARK: - Aufbau

    /// Fixture-Gerät: Anchors für den Nutzer, `fullDone.user.none = false`, kein
    /// `fullDone.user.<id>`, keine `state.json`. Eigene Defaults-Suite, eigenes
    /// Zustandsverzeichnis, Nutzer im In-Memory-Schlüsselbund.
    private func withLegacyDevice(
        _ body: (OpenWearablesHealthSDK, UserDefaults, URL) -> Void
    ) {
        withIsolatedDefaults { defaults in
            withIsolatedSDK(userId: LegacyDeviceState.userId) { sdk, stateDirectory in
                LegacyDeviceState.install(into: defaults)
                body(sdk, defaults, stateDirectory)
            }
        }
    }

    private func anchorSnapshot(_ defaults: UserDefaults) -> [String: Data] {
        var result: [String: Data] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("anchor.") {
            if let data = value as? Data { result[key] = data }
        }
        return result
    }

    private func directoryListing(_ url: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        return (enumerator?.allObjects as? [String] ?? []).sorted()
    }

    // MARK: - Fixture selbst

    func testFixtureHasTheMeasuredShape() {
        withLegacyDevice { sdk, defaults, stateDirectory in
            XCTAssertEqual(sdk.userKey(), LegacyDeviceState.userKey)
            XCTAssertEqual(LegacyDeviceState.anchors.count, 40)
            XCTAssertEqual(sdk.anchorCount(forUserKey: LegacyDeviceState.userKey), 40)

            XCTAssertEqual(defaults.object(forKey: "fullDone.user.none") as? Bool, false)
            XCTAssertNil(defaults.object(forKey: sdk.fullDoneKey()),
                         "Am Gerät fehlt fullDone unter dem Nutzerschlüssel vollständig")
            XCTAssertNil(sdk.loadSyncState(), "Am Gerät gab es keine offene Sitzung")
            XCTAssertEqual(directoryListing(stateDirectory), [])
        }
    }

    func testFixtureIdentifiersAreTypesTheSDKKnows() {
        let known = Set(HealthDataType.allCases.compactMap { $0.toHKSampleType()?.identifier })
        let fixture = Set(LegacyDeviceState.anchors.map { $0.typeIdentifier })

        XCTAssertEqual(fixture.count, LegacyDeviceState.anchors.count, "Typ doppelt in der Fixture")
        XCTAssertTrue(fixture.isSubset(of: known),
                      "Unbekannte Typen in der Fixture: \(fixture.subtracting(known).sorted())")
    }

    // MARK: - Die Falle und ihre Auflösung

    /// Gegenprobe: ohne Adoption eskaliert dieselbe Entscheidung zum Export. Das ist die
    /// Falle, die Befund 4 beschreibt.
    func testWithoutAdoptionTheFixtureStateEscalatesToFullExport() {
        withLegacyDevice { sdk, defaults, _ in
            let fullDone = defaults.bool(forKey: sdk.fullDoneKey())
            XCTAssertFalse(fullDone)

            let escalates = OpenWearablesHealthSDK.effectiveFullExport(
                existingFullExport: sdk.loadSyncState()?.fullExport,
                fullDone: fullDone,
                requested: false
            )
            XCTAssertTrue(escalates, "Ohne Adoption beginnt das Update einen Neu-Export")
        }
    }

    func testAdoptionOfTheFixtureStateAvoidsTheFullExport() {
        withLegacyDevice { sdk, defaults, _ in
            XCTAssertTrue(sdk.adoptLegacyStateIfNeeded())

            XCTAssertEqual(defaults.object(forKey: sdk.fullDoneKey()) as? Bool, true)
            XCTAssertTrue(sdk.isInitialExportDone())

            let escalates = OpenWearablesHealthSDK.effectiveFullExport(
                existingFullExport: sdk.loadSyncState()?.fullExport,
                fullDone: sdk.isInitialExportDone(),
                requested: false
            )
            XCTAssertFalse(escalates, "Mit Adoption läuft der erste Lauf inkrementell")
        }
    }

    /// `isInitialExportDone()` ist die einzige Lesestelle. Sie adoptiert selbst, auch wenn
    /// kein `configure()` vorausging (etwa im Hintergrundstart eines frischen Prozesses).
    func testIsInitialExportDoneAdoptsOnFirstRead() {
        withLegacyDevice { sdk, defaults, _ in
            XCTAssertNil(defaults.object(forKey: sdk.fullDoneKey()))
            XCTAssertTrue(sdk.isInitialExportDone())
            XCTAssertEqual(defaults.object(forKey: sdk.fullDoneKey()) as? Bool, true)
        }
    }

    /// Die Statusauskunft für die App liest dieselbe Stelle.
    func testSyncStatusReportsTheInitialExportAsDoneOnTheFixtureState() {
        withLegacyDevice { sdk, _, _ in
            let status = sdk.getSyncStatusDict()
            XCTAssertEqual(status["initialExportDone"] as? Bool, true)
            XCTAssertEqual(status["isFullExport"] as? Bool, false)
        }
    }

    // MARK: - Ränder, an denen nicht adoptiert werden darf

    /// Ausdrückliches `false` unter dem echten Schlüssel stammt aus `signOut`
    /// (`resetAllAnchors`): dort ist ein Neu-Export gewollt.
    func testExplicitFalseAfterSignOutIsNotOverridden() {
        withLegacyDevice { sdk, defaults, _ in
            defaults.set(false, forKey: sdk.fullDoneKey())

            XCTAssertFalse(sdk.adoptLegacyStateIfNeeded())
            XCTAssertEqual(defaults.object(forKey: sdk.fullDoneKey()) as? Bool, false)
            XCTAssertFalse(sdk.isInitialExportDone())
        }
    }

    func testFreshInstallWithoutAnchorsIsNotAdopted() {
        withIsolatedDefaults { defaults in
            withIsolatedSDK(userId: LegacyDeviceState.userId) { sdk, _ in
                defaults.set(false, forKey: "fullDone.user.none")

                XCTAssertFalse(sdk.adoptLegacyStateIfNeeded())
                XCTAssertNil(defaults.object(forKey: sdk.fullDoneKey()))
                XCTAssertFalse(sdk.isInitialExportDone())
            }
        }
    }

    /// Anchors eines anderen Nutzers zählen nicht, auch nicht bei ähnlichem Präfix.
    func testAnchorsOfAnotherUserDoNotTriggerAdoption() {
        withIsolatedDefaults { defaults in
            withIsolatedSDK(userId: LegacyDeviceState.userId) { sdk, _ in
                let other = "user.\(LegacyDeviceState.userId)0"
                defaults.set(Data([1, 2, 3]), forKey: "anchor.\(other).HKQuantityTypeIdentifierStepCount")
                defaults.set(Data([1, 2, 3]), forKey: "anchor.user.somebody-else.HKQuantityTypeIdentifierStepCount")

                XCTAssertEqual(sdk.anchorCount(forUserKey: LegacyDeviceState.userKey), 0)
                XCTAssertFalse(sdk.adoptLegacyStateIfNeeded())
                XCTAssertNil(defaults.object(forKey: sdk.fullDoneKey()))
            }
        }
    }

    func testOpenFullExportSessionIsNotTouchedAndBlocksAdoption() {
        withLegacyDevice { sdk, defaults, _ in
            _ = sdk.startNewSyncState(fullExport: true, types: [])
            let before = try? Data(contentsOf: sdk.syncStateFilePath())
            XCTAssertNotNil(before)

            XCTAssertFalse(sdk.adoptLegacyStateIfNeeded())

            XCTAssertNil(defaults.object(forKey: sdk.fullDoneKey()))
            XCTAssertEqual(try? Data(contentsOf: sdk.syncStateFilePath()), before,
                           "Ein offener Export bleibt byte-gleich")
            XCTAssertEqual(sdk.loadSyncState()?.fullExport, true)
        }
    }

    /// Eine laufende inkrementelle Sitzung ist kein offener Export und blockiert nicht.
    func testOpenIncrementalSessionDoesNotBlockAdoptionAndStaysUntouched() {
        withLegacyDevice { sdk, defaults, _ in
            _ = sdk.startNewSyncState(fullExport: false, types: [])
            let before = try? Data(contentsOf: sdk.syncStateFilePath())

            XCTAssertTrue(sdk.adoptLegacyStateIfNeeded())

            XCTAssertEqual(defaults.object(forKey: sdk.fullDoneKey()) as? Bool, true)
            XCTAssertEqual(try? Data(contentsOf: sdk.syncStateFilePath()), before)
        }
    }

    /// Die Sitzung eines anderen Nutzers ist nicht unser offener Export. Die Adoption
    /// darf sie aber auch nicht löschen: `loadSyncState()` räumt so eine Datei ab, die
    /// Adoption liest deshalb ohne Nebenwirkung.
    func testSessionOfAnotherUserNeitherBlocksNorIsDeletedByAdoption() {
        withLegacyDevice { sdk, defaults, _ in
            let foreign = SyncState(
                userKey: "user.somebody-else",
                fullExport: true,
                createdAt: Date(),
                typeProgress: [:],
                totalSentCount: 0,
                completedTypes: [],
                currentTypeIndex: 0,
                sessionId: nil
            )
            sdk.saveSyncState(foreign)
            let before = try? Data(contentsOf: sdk.syncStateFilePath())
            XCTAssertNotNil(before)

            XCTAssertTrue(sdk.adoptLegacyStateIfNeeded())

            XCTAssertEqual(defaults.object(forKey: sdk.fullDoneKey()) as? Bool, true)
            XCTAssertEqual(try? Data(contentsOf: sdk.syncStateFilePath()), before,
                           "Die Datei des anderen Nutzers bleibt unberührt")
        }
    }

    func testWithoutSignedInUserNothingIsAdopted() {
        withIsolatedDefaults { defaults in
            withIsolatedSDK(userId: LegacyDeviceState.userId) { sdk, _ in
                OpenWearablesHealthSdkKeychain.volatileStore = [:]
                XCTAssertEqual(sdk.userKey(), "user.none")
                defaults.set(Data([1, 2, 3]), forKey: "anchor.user.none.HKQuantityTypeIdentifierStepCount")

                XCTAssertFalse(sdk.adoptLegacyStateIfNeeded())
                XCTAssertNil(defaults.object(forKey: "fullDone.user.none"))
            }
        }
    }

    // MARK: - Was die Adoption schreibt

    func testSecondCallDoesNothing() {
        withLegacyDevice { sdk, defaults, _ in
            XCTAssertTrue(sdk.adoptLegacyStateIfNeeded())
            let keysAfterFirst = Set(defaults.dictionaryRepresentation().keys)

            XCTAssertFalse(sdk.adoptLegacyStateIfNeeded())
            XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys), keysAfterFirst)
            XCTAssertEqual(defaults.object(forKey: sdk.fullDoneKey()) as? Bool, true)
        }
    }

    /// Arbeitsregel "Bestehende Daten respektieren": genau ein Boolean, sonst nichts.
    func testAdoptionWritesExactlyOneBooleanAndLeavesAnchorsAndFilesUntouched() {
        withLegacyDevice { sdk, defaults, stateDirectory in
            let keysBefore = Set(defaults.dictionaryRepresentation().keys)
            let anchorsBefore = anchorSnapshot(defaults)
            let filesBefore = directoryListing(stateDirectory)
            XCTAssertEqual(anchorsBefore.count, 40)

            XCTAssertTrue(sdk.adoptLegacyStateIfNeeded())

            let keysAfter = Set(defaults.dictionaryRepresentation().keys)
            XCTAssertEqual(keysAfter.subtracting(keysBefore), [sdk.fullDoneKey()])
            XCTAssertTrue(keysBefore.subtracting(keysAfter).isEmpty, "Es darf kein Schlüssel verschwinden")

            XCTAssertEqual(anchorSnapshot(defaults), anchorsBefore, "Anchors bleiben byte-gleich")
            XCTAssertEqual(defaults.object(forKey: "fullDone.user.none") as? Bool, false,
                           "Der Wert unter user.none bleibt, wie er war")
            XCTAssertEqual(directoryListing(stateDirectory), filesBefore,
                           "Keine Datei entsteht oder verschwindet (state.json, Outbox)")
        }
    }

    // MARK: - Reine Entscheidung

    func testOpenExportStaysAnExport() {
        XCTAssertTrue(OpenWearablesHealthSDK.effectiveFullExport(
            existingFullExport: true, fullDone: true, requested: false))
    }

    func testEffectiveFullExportTruthTable() {
        let cases: [(existing: Bool?, fullDone: Bool, requested: Bool, expected: Bool)] = [
            (nil, false, false, true),    // Erst-Export nie abgeschlossen: erzwingt Export
            (nil, false, true, true),
            (nil, true, false, false),    // der Normalfall nach der Adoption
            (nil, true, true, true),      // ausdrücklich angefordert
            (false, true, false, false),  // inkrementelle Sitzung bleibt inkrementell
            (false, false, false, true),
            (true, true, false, true),
            (true, false, false, true),
        ]
        for c in cases {
            XCTAssertEqual(
                OpenWearablesHealthSDK.effectiveFullExport(
                    existingFullExport: c.existing, fullDone: c.fullDone, requested: c.requested),
                c.expected,
                "existing=\(String(describing: c.existing)) fullDone=\(c.fullDone) requested=\(c.requested)"
            )
        }
    }
}
