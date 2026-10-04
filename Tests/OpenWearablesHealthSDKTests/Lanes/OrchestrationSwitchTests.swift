import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Die Weiche zwischen Zwei-Spuren-Steuerung und Original-Ablauf (Plan 05-08, D-13, SYNC-13).
///
/// Ohne HealthKit prüfbar: der gesperrte lanes-Lauf endet an der Vorabprüfung des Kerns, bevor
/// etwas abgefragt wird, und der laufende Zyklus wird durch einen Eintrag im Register ersetzt.
final class OrchestrationSwitchTests: XCTestCase {

    private static let key = "lanes.orchestration"

    // MARK: - Hilfen

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func withTrackedTypes(
        _ types: [HKSampleType], on sdk: OpenWearablesHealthSDK, _ body: () -> Void
    ) {
        let previous = sdk.trackedTypes
        sdk.trackedTypes = types
        defer { sdk.trackedTypes = previous }
        body()
    }

    /// Setzt den Sperrzustands-Cache. `UIApplication` fasst der Test nie an.
    private func withProtectedData(
        _ available: Bool?, on sdk: OpenWearablesHealthSDK, _ body: () -> Void
    ) {
        let previous = sdk.protectedDataAvailableCache
        sdk.protectedDataAvailableCache = available
        defer { sdk.protectedDataAvailableCache = previous }
        body()
    }

    private func result(
        _ status: SyncOutcome.Status = .transferred, live: Int = 0, pending: Bool = false,
        needsCatchUp: Bool = false, perType: [String: Int] = [:]
    ) -> CycleResult {
        CycleResult(
            status: status, liveRecords: live, backfillRecords: 0, perType: perType,
            deletionsQueued: 0, backfillPending: pending, needsCatchUp: needsCatchUp, events: []
        )
    }

    // MARK: - Schalter

    func testWithoutAKeyTheOrchestrationIsLanes() {
        withIsolatedDefaults { defaults in
            XCTAssertNil(defaults.object(forKey: Self.key))
            XCTAssertEqual(OpenWearablesHealthSDK.shared.orchestration, .lanes)
        }
    }

    func testTheUpstreamValueSelectsTheOriginalFlow() {
        withIsolatedDefaults { defaults in
            defaults.set("upstream", forKey: Self.key)
            XCTAssertEqual(OpenWearablesHealthSDK.shared.orchestration, .upstream)
        }
    }

    func testAnUnknownValueFallsBackToLanes() {
        withIsolatedDefaults { defaults in
            defaults.set("kaputt", forKey: Self.key)
            XCTAssertEqual(OpenWearablesHealthSDK.shared.orchestration, .lanes)
            defaults.set(42, forKey: Self.key)
            XCTAssertEqual(OpenWearablesHealthSDK.shared.orchestration, .lanes)
        }
    }

    /// Der Schalter muss im Kaltstart wirken, bevor `configure()` lief: er liegt nur in der
    /// Suite. Eine frisch erzeugte `UserDefaults` derselben Suite steht für den neuen Prozess.
    func testTheSettingSurvivesAColdStartWithoutConfigure() {
        let sdk = OpenWearablesHealthSDK.shared
        let previous = sdk.defaults
        let suiteName = "ow-orchestration-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else { return XCTFail("Suite") }
        defer {
            sdk.defaults = previous
            suite.removePersistentDomain(forName: suiteName)
        }
        sdk.defaults = suite

        sdk.orchestration = .upstream
        guard let coldStart = UserDefaults(suiteName: suiteName) else { return XCTFail("Suite") }
        XCTAssertEqual(coldStart.string(forKey: Self.key), "upstream")

        sdk.defaults = coldStart
        XCTAssertEqual(sdk.orchestration, .upstream)

        sdk.orchestration = .lanes
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.string(forKey: Self.key), "lanes")
    }

    /// Umschalten mitten im Lauf: der alte Lauf ist fenced und schreibt nichts mehr fest.
    func testSwitchingDuringARunFencesItAndJournalsTheSwitch() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: nil) { sdk, _ in
                XCTAssertEqual(sdk.orchestration, .lanes, "Vorbedingung: Standard")
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                defer { sdk.finishSync(generation: generation) }
                XCTAssertFalse(sdk.isSyncCancelled(generation: generation))

                sdk.orchestration = .upstream

                XCTAssertTrue(sdk.isSyncCancelled(generation: generation), "der Wechsel fenced den Lauf")
                let switches = sdk.journalEntries().filter { $0.kind == "switch" }
                XCTAssertEqual(switches.count, 1)
                XCTAssertEqual(switches.first?.note, "lanes→upstream")
                XCTAssertEqual(sdk.orchestration, .upstream)
            }
        }
    }

    func testSettingTheSameValueDoesNotDisturbARunningRun() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                defer { sdk.finishSync(generation: generation) }

                sdk.orchestration = .lanes

                XCTAssertFalse(sdk.isSyncCancelled(generation: generation))
                XCTAssertTrue(sdk.journalEntries().filter { $0.kind == "switch" }.isEmpty)
            }
        }
    }

    // MARK: - lanes: gesperrt

    /// SYNC-10 im lanes-Modus: nichts bewegt sich, der Nachholbedarf überlebt einen Neustart,
    /// und `state.json` entsteht nie (Pattern 9: der Rückweg findet "kein offener Export").
    func testALockedLanesRunIsDeferredAndPersistsTheCatchUp() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable(), "HealthKit nicht verfügbar")
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, directory in
                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                        var seen: [SyncOutcome] = []
                        let previous = sdk.onRunCompleted
                        sdk.onRunCompleted = { seen.append($0) }
                        defer { sdk.onRunCompleted = previous }

                        var completions: [SyncOutcome] = []
                        sdk.sync(trigger: .app("locked-test")) { completions.append($0) }

                        XCTAssertTrue(waitUntil { !completions.isEmpty })
                        spin(0.2)

                        XCTAssertEqual(completions.count, 1)
                        XCTAssertEqual(seen, completions, "onRunCompleted genau einmal, dasselbe Ergebnis")
                        XCTAssertEqual(completions.first?.status, .deferredLocked)
                        XCTAssertEqual(completions.first?.orchestration, .lanes)
                        XCTAssertEqual(completions.first?.trigger, .app("locked-test"))
                        XCTAssertTrue(sdk.lanesNeedsCatchUp, "der Nachholbedarf ist persistiert")
                        XCTAssertFalse(FileManager.default.fileExists(atPath: sdk.syncStateFilePath().path))
                        XCTAssertFalse(sdk.isSyncInProgress, "der Slot ist wieder frei")

                        let runs = sdk.journalEntries().filter { $0.kind == "run" }
                        XCTAssertEqual(runs.count, 1)
                        XCTAssertEqual(runs.first?.status, "deferredLocked")
                        XCTAssertEqual(runs.first?.orchestration, "lanes")
                        _ = directory
                    }
                }
            }
        }
    }

    /// Ein späterer sauberer Lauf löscht den Nachholbedarf, ein misslungener nicht: er hat
    /// nicht nachgeholt, was die Sperre liegen ließ.
    func testTheCatchUpFlagStaysUntilARunEndsCleanly() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                sdk.lanesNeedsCatchUp = true

                sdk.updateLanesNeedsCatchUp(with: result(.skippedBusy))
                XCTAssertTrue(sdk.lanesNeedsCatchUp, "ein übersprungener Lauf ändert nichts")
                sdk.updateLanesNeedsCatchUp(with: result(.failed("network(-1009)")))
                XCTAssertTrue(sdk.lanesNeedsCatchUp, "ein Fehlschlag auch nicht")
                sdk.updateLanesNeedsCatchUp(with: result(.partial(.budget)))
                XCTAssertTrue(sdk.lanesNeedsCatchUp)

                sdk.updateLanesNeedsCatchUp(with: result(.upToDate))
                XCTAssertFalse(sdk.lanesNeedsCatchUp, "sauber beendet: nachgeholt")

                sdk.updateLanesNeedsCatchUp(with: result(.deferredLocked, needsCatchUp: true))
                XCTAssertTrue(sdk.lanesNeedsCatchUp, "gesperrt setzt ihn")
                sdk.updateLanesNeedsCatchUp(with: result(.transferred, live: 3))
                XCTAssertFalse(sdk.lanesNeedsCatchUp)
            }
        }
    }

    // MARK: - Weiche je Aufruf

    func testUpstreamWithATakenSlotReportsSkippedBusyAsUpstream() {
        withIsolatedSDK(orchestration: .upstream) { sdk, _ in
            guard let holder = sdk.beginSyncRun() else { return XCTFail("slot") }
            defer { sdk.finishSync(generation: holder) }

            withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                var outcome: SyncOutcome?
                sdk.sync(trigger: .app("busy")) { outcome = $0 }
                XCTAssertTrue(waitUntil { outcome != nil })
                XCTAssertEqual(outcome?.status, .skippedBusy)
                XCTAssertEqual(outcome?.orchestration, .upstream)
            }
        }
    }

    /// Hält ein Lauf des Originals den Slot (nach einem Wechsel mitten im Lauf), meldet lanes
    /// `skippedBusy` mit dem eigenen Modus und lässt den Halter in Ruhe.
    func testLanesWithASlotHeldByAnotherRunReportsSkippedBusyAndKeepsTheHolder() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let holder = sdk.beginSyncRun() else { return XCTFail("slot") }
                defer { sdk.finishSync(generation: holder) }

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var outcome: SyncOutcome?
                    sdk.sync(trigger: .observer("HKQuantityTypeIdentifierBodyMass")) { outcome = $0 }
                    XCTAssertTrue(waitUntil { outcome != nil })
                    XCTAssertEqual(outcome?.status, .skippedBusy)
                    XCTAssertEqual(outcome?.orchestration, .lanes)
                    XCTAssertEqual(outcome?.trigger, .observer("HKQuantityTypeIdentifierBodyMass"))
                    XCTAssertTrue(sdk.isSyncInProgress)
                    XCTAssertFalse(sdk.isSyncCancelled(generation: holder))
                }
            }
        }
    }

    func testEveryCallReadsTheSwitchAgain() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable(), "HealthKit nicht verfügbar")
        withIsolatedDefaults { defaults in
            withIsolatedSDK(orchestration: nil) { sdk, _ in
                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                        var first: SyncOutcome?
                        sdk.sync { first = $0 }
                        XCTAssertTrue(waitUntil { first != nil })
                        XCTAssertEqual(first?.orchestration, .lanes)

                        // Von außen umgestellt (zweiter Prozess, Diagnose): der nächste Aufruf folgt.
                        defaults.set("upstream", forKey: Self.key)
                        guard let holder = sdk.beginSyncRun() else { return XCTFail("slot") }
                        defer { sdk.finishSync(generation: holder) }
                        var second: SyncOutcome?
                        sdk.sync { second = $0 }
                        XCTAssertTrue(waitUntil { second != nil })
                        XCTAssertEqual(second?.orchestration, .upstream)
                    }
                }
            }
        }
    }

    // MARK: - Auslöser während eines laufenden Zyklus

    /// Pattern 1: ein Auslöser während eines lanes-Zyklus wird nicht verworfen. Er wartet auf die
    /// nächste Live-Runde, und der laufende Zyklus behält seinen Slot.
    func testATriggerDuringARunningCycleWaitsForTheNextLiveRound() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                var waiters: [(CycleResult) -> Void] = []
                sdk.registerActiveLanesCycle(ActiveLanesCycle(generation: generation) { waiter in
                    waiters.append(waiter)
                    return true
                })
                defer {
                    _ = sdk.releaseActiveLanesCycle(generation: generation)
                    sdk.finishSync(generation: generation)
                }

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var outcome: SyncOutcome?
                    sdk.sync(trigger: .unlock) { outcome = $0 }

                    XCTAssertEqual(waiters.count, 1, "die Live-Runde wurde angefordert")
                    spin(0.1)
                    XCTAssertNil(outcome, "es wird auf die Runde gewartet, nichts ist verworfen")
                    XCTAssertTrue(sdk.isSyncInProgress)
                    XCTAssertFalse(sdk.isSyncCancelled(generation: generation), "der Zyklus behält seinen Slot")

                    waiters[0](result(.transferred, live: 3, pending: true, perType: ["HKQuantityTypeIdentifierBodyMass": 3]))

                    XCTAssertTrue(waitUntil { outcome != nil })
                    XCTAssertEqual(outcome?.status, .transferred)
                    XCTAssertEqual(outcome?.liveRecords, 3)
                    XCTAssertEqual(outcome?.perType, ["HKQuantityTypeIdentifierBodyMass": 3])
                    XCTAssertEqual(outcome?.backfillPending, true)
                    XCTAssertEqual(outcome?.orchestration, .lanes)
                    XCTAssertEqual(outcome?.trigger, .unlock)
                    XCTAssertEqual(sdk.journalEntries().filter { $0.kind == "run" }.count, 1)
                }
            }
        }
    }

    /// Die Antwort auf die Live-Runde sagt auch, wenn das iPhone mittendrin gesperrt wurde.
    func testALiveRoundThatFindsTheDeviceLockedPersistsTheCatchUp() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                var waiters: [(CycleResult) -> Void] = []
                sdk.registerActiveLanesCycle(ActiveLanesCycle(generation: generation) { waiter in
                    waiters.append(waiter)
                    return true
                })
                defer {
                    _ = sdk.releaseActiveLanesCycle(generation: generation)
                    sdk.finishSync(generation: generation)
                }

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var outcome: SyncOutcome?
                    sdk.sync(trigger: .network) { outcome = $0 }
                    XCTAssertEqual(waiters.count, 1)
                    waiters[0](result(.deferredLocked, needsCatchUp: true))
                    XCTAssertTrue(waitUntil { outcome != nil })
                    XCTAssertEqual(outcome?.status, .deferredLocked)
                    XCTAssertTrue(sdk.lanesNeedsCatchUp)
                }
            }
        }
    }

    /// Endet der Zyklus gerade (der Kern läuft nicht mehr, der Slot ist noch belegt), geht der
    /// Auslöser nicht verloren: er läuft nach dem Ende als eigener Zyklus.
    func testATriggerThatArrivesWhileTheCycleIsEndingRunsAfterwards() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable(), "HealthKit nicht verfügbar")
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                sdk.registerActiveLanesCycle(ActiveLanesCycle(generation: generation) { _ in false })

                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                        var outcome: SyncOutcome?
                        sdk.sync(trigger: .network) { outcome = $0 }
                        spin(0.1)
                        XCTAssertNil(outcome, "der Auslöser ist vorgemerkt, nicht beantwortet")

                        // Das Ende des Zyklus: Slot frei, Register leer, Vorgemerktes läuft.
                        sdk.finishSync(generation: generation)
                        let deferred = sdk.releaseActiveLanesCycle(generation: generation)
                        XCTAssertEqual(deferred.count, 1)
                        sdk.runDeferredLanesTriggers(deferred)

                        XCTAssertTrue(waitUntil { outcome != nil })
                        XCTAssertEqual(outcome?.trigger, .network)
                        XCTAssertEqual(outcome?.status, .deferredLocked, "ein eigener Zyklus lief")
                        XCTAssertFalse(sdk.isSyncInProgress)
                    }
                }
            }
        }
    }

    /// Ein Zyklus, der seinen Slot verloren hat (Frist, Abbruch), nimmt keine Live-Runden mehr an.
    func testACycleThatLostItsSlotIsNotAskedForALiveRound() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable(), "HealthKit nicht verfügbar")
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let old = sdk.beginSyncRun() else { return XCTFail("slot") }
                var asked = 0
                sdk.registerActiveLanesCycle(ActiveLanesCycle(generation: old) { _ in
                    asked += 1
                    return true
                })
                sdk.cancelSync()
                defer {
                    _ = sdk.releaseActiveLanesCycle(generation: old)
                    sdk.finishSync(generation: old)
                }

                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                        var outcome: SyncOutcome?
                        sdk.sync(trigger: .foreground) { outcome = $0 }
                        XCTAssertTrue(waitUntil { outcome != nil })
                        XCTAssertEqual(asked, 0, "der abgebrochene Zyklus wird nicht gefragt")
                        XCTAssertEqual(outcome?.status, .skippedBusy, "der Slot gehört ihm noch 60 Sekunden")
                    }
                }
            }
        }
    }

    // MARK: - Frist an den laufenden Zyklus (Review ME-01)

    /// Ein Auslöser mit Frist (BGTask der App oder des SDK) wartet auf die Live-Runde eines Zyklus,
    /// der vielleicht keine Frist hat. Seine Frist gilt dann für den Zyklus: gibt der Auslöser seinen
    /// Task zurück, läuft der fremde Zyklus sonst ohne Frist weiter und wird suspendiert.
    func testATriggerWithADeadlineHandsItsDeadlineToTheRunningCycle() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                var tightened: [Date] = []
                var waiters: [(CycleResult) -> Void] = []
                sdk.registerActiveLanesCycle(ActiveLanesCycle(
                    generation: generation,
                    requestLiveRound: { waiter in
                        waiters.append(waiter)
                        return true
                    },
                    tighten: { tightened.append($0) }
                ))
                defer {
                    _ = sdk.releaseActiveLanesCycle(generation: generation)
                    sdk.finishSync(generation: generation)
                }

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var answered = 0
                    let deadline = Date().addingTimeInterval(25)
                    sdk.sync(trigger: .sdkRefresh, deadline: deadline) { _ in answered += 1 }
                    XCTAssertEqual(tightened, [deadline])

                    sdk.sync(trigger: .foreground) { _ in answered += 1 }
                    XCTAssertEqual(tightened, [deadline], "ohne eigene Frist bleibt die des Zyklus")

                    // Die Runde beantworten, damit kein Wartender in den nächsten Test hineinreicht.
                    for waiter in waiters { waiter(result(.upToDate)) }
                    XCTAssertTrue(waitUntil { answered == 2 })
                }
            }
        }
    }

    /// Der Ablauf-Handler eines BGTasks der App erreicht den Zyklus des SDK über dieselbe Funktion
    /// wie die Ablauf-Handler des SDK: die Frist wird "jetzt".
    func testExpireRunningSyncSetsTheDeadlineOfTheRunningCycleToNow() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                var tightened: [Date] = []
                sdk.registerActiveLanesCycle(ActiveLanesCycle(
                    generation: generation, requestLiveRound: { _ in true }, tighten: { tightened.append($0) }
                ))
                defer {
                    _ = sdk.releaseActiveLanesCycle(generation: generation)
                    sdk.finishSync(generation: generation)
                }

                let before = Date()
                sdk.expireRunningSync()

                XCTAssertEqual(tightened.count, 1)
                XCTAssertGreaterThanOrEqual(tightened.first ?? .distantPast, before)
                XCTAssertLessThanOrEqual(tightened.first ?? .distantFuture, Date())
            }
        }
    }

    // MARK: - Wartende eines hängenden oder abgelösten Zyklus (Review ME-03)

    private final class Clock {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_791_100_800)
        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    /// Übernimmt ein neuer Lauf den Slot eines hängenden Zyklus, bekommen dessen Wartende ihre
    /// Antwort (`partial(expired)`). Sonst kam die Completion von `sync` nie, und die App hielt ihren
    /// Anspruch bis zu 15 Minuten.
    func testATakeoverAnswersTheTriggersWaitingOnTheSupersededCycle() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                let clock = Clock()
                let previousNow = sdk.now
                sdk.now = { clock.now }
                defer { sdk.now = previousNow }

                guard let old = sdk.beginSyncRun() else { return XCTFail("slot") }
                var waiters: [(CycleResult) -> Void] = []
                sdk.registerActiveLanesCycle(ActiveLanesCycle(
                    generation: old,
                    requestLiveRound: { waiter in
                        waiters.append(waiter)
                        return true
                    },
                    abandon: { result in
                        let pending = waiters
                        waiters = []
                        for waiter in pending { waiter(result) }
                    }
                ))

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var outcome: SyncOutcome?
                    sdk.sync(trigger: .unlock) { outcome = $0 }
                    XCTAssertEqual(waiters.count, 1)

                    clock.advance(151)
                    guard let new = sdk.beginSyncRun() else { return XCTFail("Übernahme erwartet") }
                    defer {
                        sdk.finishSync(generation: new)
                        sdk.finishSync(generation: old)
                    }

                    XCTAssertTrue(waitUntil { outcome != nil })
                    XCTAssertEqual(outcome?.status, .partial(.expired))
                    XCTAssertEqual(outcome?.trigger, .unlock)
                    sdk.lanesCycleLock.lock()
                    let registered = sdk.activeLanesCycle?.generation
                    sdk.lanesCycleLock.unlock()
                    XCTAssertNil(registered, "das Register des alten Zyklus ist abgeräumt")
                }
            }
        }
    }

    /// Hängt der Zyklus und übernimmt niemand, bekommt der Wartende seine Antwort, sobald die Sperre
    /// des Zyklus abgelaufen ist. Eine späte Antwort des Zyklus kommt danach nicht mehr durch.
    func testAWaiterOnACycleThatStopsLivingIsAnsweredOnceItsLeaseHasExpired() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                let clock = Clock()
                let previousNow = sdk.now
                let previousInterval = OpenWearablesHealthSDK.handOverCheckInterval
                sdk.now = { clock.now }
                OpenWearablesHealthSDK.handOverCheckInterval = 0.05
                defer {
                    sdk.now = previousNow
                    OpenWearablesHealthSDK.handOverCheckInterval = previousInterval
                }

                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                var waiters: [(CycleResult) -> Void] = []
                sdk.registerActiveLanesCycle(ActiveLanesCycle(generation: generation) { waiter in
                    waiters.append(waiter)
                    return true
                })
                defer {
                    _ = sdk.releaseActiveLanesCycle(generation: generation)
                    sdk.finishSync(generation: generation)
                }

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var outcomes: [SyncOutcome] = []
                    sdk.sync(trigger: .network) { outcomes.append($0) }
                    XCTAssertEqual(waiters.count, 1)

                    spin(0.3)
                    XCTAssertTrue(outcomes.isEmpty, "solange der Zyklus lebt, wird auf seine Runde gewartet")

                    clock.advance(151)
                    XCTAssertTrue(waitUntil { !outcomes.isEmpty })
                    XCTAssertEqual(outcomes.first?.status, .partial(.expired))

                    waiters[0](result(.transferred, live: 3))
                    spin(0.2)
                    XCTAssertEqual(outcomes.count, 1, "die späte Antwort kommt nicht noch einmal")
                }
            }
        }
    }

    // MARK: - Antworten an übergebene Auslöser zählen nicht doppelt (Review ME-06)

    /// Die Antwort an einen übergebenen Auslöser trägt die Zahlen seiner Runde, die das Ergebnis des
    /// Zyklus noch einmal enthält. Sie ist als `handedOver` gekennzeichnet, im Ergebnis und im Journal,
    /// damit Ledger und Auswertung sie nicht dazuzählen.
    func testTheAnswerToAHandedOverTriggerIsMarkedSoItsRecordsAreNotCountedTwice() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
                var waiters: [(CycleResult) -> Void] = []
                sdk.registerActiveLanesCycle(ActiveLanesCycle(generation: generation) { waiter in
                    waiters.append(waiter)
                    return true
                })
                defer {
                    _ = sdk.releaseActiveLanesCycle(generation: generation)
                    sdk.finishSync(generation: generation)
                }

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var outcome: SyncOutcome?
                    sdk.sync(trigger: .observer("HKQuantityTypeIdentifierStepCount")) { outcome = $0 }
                    waiters.first?(result(.transferred, live: 2, perType: ["HKQuantityTypeIdentifierStepCount": 2]))

                    XCTAssertTrue(waitUntil { outcome != nil })
                    XCTAssertEqual(outcome?.scope, .handedOver)
                    XCTAssertEqual(outcome?.records, 2, "die Zahlen der Runde bleiben lesbar")
                    let run = sdk.journalEntries().last { $0.kind == "run" }
                    XCTAssertEqual(run?.scope, "handedOver")
                }
            }
        }
    }

    func testAnOutcomeOfAWholeRunIsScopedRun() {
        let outcome = SyncOutcome(status: .upToDate, orchestration: .lanes, trigger: .unlock, started: Date(), finished: Date())
        XCTAssertEqual(outcome.scope, .run)
    }

    // MARK: - Ereignisse fürs Journal

    func testCoreEventsAreGroupedIntoOneEntryPerKindAndNeverFloodTheRing() {
        let events = (0..<30).map { "bootstrap:HKQuantityTypeIdentifierType\($0)" }
            + ["parked:HKQuantityTypeIdentifierHeartRate", "hold:HKQuantityTypeIdentifierStepCount:422",
               "locked:live:HKQuantityTypeIdentifierBodyMass", "planSaveFailed"]
        let grouped = LaneEventSummary.group(events)

        XCTAssertEqual(grouped.backfill.count, 30)
        XCTAssertEqual(grouped.rejected, ["parked:HKQuantityTypeIdentifierHeartRate", "hold:HKQuantityTypeIdentifierStepCount:422"])
        XCTAssertEqual(grouped.other, ["locked:live:HKQuantityTypeIdentifierBodyMass", "planSaveFailed"])

        let note = LaneEventSummary.note(grouped.backfill) { $0.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "") }
        XCTAssertEqual(note?.components(separatedBy: " ").count, 13, "zwölf Namen und ein Zähler")
        XCTAssertTrue(note?.hasSuffix("+18") ?? false)
        XCTAssertNil(LaneEventSummary.note([]) { $0 })
        XCTAssertFalse(note?.contains("HKQuantityTypeIdentifier") ?? true, "Kurznamen statt Identifier")
    }

    // MARK: - Status der Diagnose

    func testTheSyncStatusCarriesTheNewKeysInBothModes() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                sdk.lanesNeedsCatchUp = true
                var plan = BackfillPlan.empty()
                plan.start(typeId: "HKQuantityTypeIdentifierHeartRate", now: Date(), daysBack: 14, origin: "request")
                plan.start(typeId: "HKQuantityTypeIdentifierStepCount", now: Date(), daysBack: 14, origin: "request")
                plan.markDone(typeId: "HKQuantityTypeIdentifierStepCount")
                try? sdk.makeBackfillStore().save(plan)
                try? sdk.makeDeletionQueue().enqueue(
                    [DeletedRef(id: "a", type: "HKQuantityTypeIdentifierBodyMass"),
                     DeletedRef(id: "b", type: "HKQuantityTypeIdentifierBodyMass")],
                    sentAt: nil
                )
                try? sdk.makeDeletionQueue().markSent(ids: ["a"], at: Date())

                let status = sdk.getSyncStatusDict()
                XCTAssertEqual(status["orchestration"] as? String, "lanes")
                XCTAssertEqual(status["backfillPendingTypes"] as? Int, 1)
                XCTAssertEqual(status["needsCatchUp"] as? Bool, true)
                XCTAssertEqual(status["deletionsQueued"] as? Int, 2)
                XCTAssertEqual(status["deletionsUnsent"] as? Int, 1)
                XCTAssertNotNil(status["hasResumableSession"], "die bisherigen Schlüssel bleiben")
                XCTAssertNotNil(status["initialExportDone"])

                sdk.orchestration = .upstream
                XCTAssertEqual(sdk.getSyncStatusDict()["orchestration"] as? String, "upstream")
            }
        }
    }
}
