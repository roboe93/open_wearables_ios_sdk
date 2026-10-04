import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Typisiertes Laufergebnis (Plan 05-03, D-09, D-10, D-13).
///
/// Die App las bisher Logzeilen. Jetzt liefert jeder Lauf genau ein `SyncOutcome`, egal ob
/// die App, ein Observer, ein SDK-BGTask, das Entsperren oder das Netz ihn ausgelöst hat.
/// Die Tests laufen ohne HealthKit-Daten: die Statusableitung ist rein, die Wege "Slot
/// belegt", "kein Typ", "keine Anmeldung" und "nur nicht abfragbare Typen" enden vor der
/// ersten Abfrage, und der Upload läuft gegen `StubURLProtocol`.
final class OutcomeTests: XCTestCase {

    // MARK: - Hilfen

    private func status(
        completed: Bool = true,
        records: Int = 0,
        locked: Bool = false,
        rejected: Int? = nil,
        failure: String? = nil,
        budget: SyncOutcome.PartialReason? = nil,
        cancelled: Bool = false
    ) -> SyncOutcome.Status {
        RunStats.status(
            completed: completed, records: records, locked: locked,
            rejectedHTTPStatus: rejected, failure: failure,
            budgetReason: budget, cancelled: cancelled
        )
    }

    private func outcome(_ status: SyncOutcome.Status, trigger: SyncTrigger = .app("test")) -> SyncOutcome {
        SyncOutcome(
            status: status, records: 0, perType: [:], liveRecords: 0, backfillRecords: 0,
            deletionsQueued: 0, backfillPending: false, leaseTakenOver: false,
            orchestration: .upstream, trigger: trigger,
            started: Date(timeIntervalSince1970: 0), finished: Date(timeIntervalSince1970: 1)
        )
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Setzt `trackedTypes` nur für die Dauer von `body`, der Singleton gehört der ganzen Suite.
    private func withTrackedTypes(
        _ types: [HKSampleType], on sdk: OpenWearablesHealthSDK, _ body: () -> Void
    ) {
        let previous = sdk.trackedTypes
        sdk.trackedTypes = types
        defer { sdk.trackedTypes = previous }
        body()
    }

    /// Fängt `onRunCompleted` ab und stellt den alten Wert wieder her.
    private func observeRuns(
        on sdk: OpenWearablesHealthSDK, _ body: (_ seen: () -> [SyncOutcome]) -> Void
    ) {
        var seen: [SyncOutcome] = []
        let previous = sdk.onRunCompleted
        sdk.onRunCompleted = { seen.append($0) }
        defer { sdk.onRunCompleted = previous }
        body { seen }
    }

    private let payload: [String: Any] = [
        "provider": "apple",
        "data": ["records": [], "sleep": [], "workouts": []]
    ]

    /// Ein Upload innerhalb einer lebenden Generation. Gibt Ergebnis und die Statistik
    /// zurück, bevor `finishSync` sie aus dem Register nimmt.
    private func upload(
        on sdk: OpenWearablesHealthSDK,
        cancelFirst: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) -> (result: UploadResult?, stats: RunStats.Snapshot?) {
        guard let endpoint = sdk.syncEndpoint else {
            XCTFail("No sync endpoint", file: file, line: line)
            return (nil, nil)
        }
        guard let generation = sdk.beginSyncRun() else {
            XCTFail("Could not claim the sync slot", file: file, line: line)
            return (nil, nil)
        }
        defer { sdk.finishSync(generation: generation) }

        if cancelFirst { sdk.cancelSync() }

        var result: UploadResult?
        sdk.uploadCombinedPayloadReportingStatus(
            payload: payload, endpoint: endpoint, credential: "access-1", generation: generation
        ) { result = $0 }

        waitUntil { result != nil }
        return (result, sdk.runStats(for: generation)?.snapshot())
    }

    // MARK: - Statusableitung (rein)

    func testRejectedBeatsEverythingElse() {
        XCTAssertEqual(
            status(completed: false, records: 5, locked: true, rejected: 422, failure: "x",
                   budget: .budget, cancelled: true),
            .rejected(httpStatus: 422)
        )
    }

    func testLockedBeatsFailureAndPartialAndIsNeverClean() {
        XCTAssertEqual(
            status(completed: false, locked: true, failure: "x", budget: .budget, cancelled: true),
            .deferredLocked
        )
        // Auch ein Lauf, der vor dem Sperren schon etwas übertragen hat, bleibt "gesperrt":
        // er zählt nie als sauber (SYNC-10).
        XCTAssertEqual(status(completed: false, records: 7, locked: true), .deferredLocked)
    }

    func testFailureBeatsPartial() {
        XCTAssertEqual(
            status(completed: false, failure: "network(-1005)", budget: .budget, cancelled: true),
            .failed("network(-1005)")
        )
    }

    func testBudgetAndBackgroundTimeAreBothPartial() {
        XCTAssertEqual(status(completed: false, records: 3, budget: .budget), .partial(.budget))
        XCTAssertEqual(
            status(completed: false, budget: .backgroundTime, cancelled: true), .partial(.backgroundTime),
            "ein Budget ist die genauere Auskunft als ein bloßes Abgebrochen"
        )
    }

    func testCancelledIsPartialWithItsOwnReason() {
        XCTAssertEqual(status(completed: false, cancelled: true), .partial(.cancelled))
    }

    func testUnfinishedWithoutAnyReasonIsPartialIncomplete() {
        XCTAssertEqual(status(completed: false), .partial(.incomplete))
        XCTAssertEqual(status(completed: false, records: 4), .partial(.incomplete))
    }

    func testFinishedWithRecordsIsTransferredAndWithoutIsUpToDate() {
        XCTAssertEqual(status(completed: true, records: 12), .transferred)
        XCTAssertEqual(status(completed: true, records: 0), .upToDate)
    }

    /// Ein Lauf, der alle Typen geschafft hat, ist nicht "partial", auch wenn kurz vor
    /// dem Ende eine Budgetgrenze gestreift wurde.
    func testFinishedRunIgnoresABudgetFlag() {
        XCTAssertEqual(status(completed: true, records: 2, budget: .budget), .transferred)
    }

    // MARK: - statusKey und journalValue (Vertrag mit analyze_runs.py)

    func testStatusKeysFollowTheJournalContract() {
        XCTAssertEqual(outcome(.transferred).statusKey, "transferred")
        XCTAssertEqual(outcome(.upToDate).statusKey, "upToDate")
        XCTAssertEqual(outcome(.partial(.budget)).statusKey, "partial:budget")
        XCTAssertEqual(outcome(.partial(.backgroundTime)).statusKey, "partial:backgroundTime")
        XCTAssertEqual(outcome(.partial(.cancelled)).statusKey, "partial:cancelled")
        XCTAssertEqual(outcome(.partial(.incomplete)).statusKey, "partial:incomplete")
        XCTAssertEqual(outcome(.deferredLocked).statusKey, "deferredLocked")
        XCTAssertEqual(outcome(.skippedBusy).statusKey, "skippedBusy")
        XCTAssertEqual(outcome(.rejected(httpStatus: 422)).statusKey, "rejected:422")
        XCTAssertEqual(outcome(.failed("no auth")).statusKey, "failed:no auth")
    }

    func testTriggerJournalValues() {
        XCTAssertEqual(
            SyncTrigger.observer("HKQuantityTypeIdentifierHeartRate").journalValue,
            "observer:HKQuantityTypeIdentifierHeartRate"
        )
        XCTAssertEqual(SyncTrigger.observer(nil).journalValue, "observer")
        XCTAssertEqual(SyncTrigger.app("refresh").journalValue, "app:refresh")
        XCTAssertEqual(SyncTrigger.sdkRefresh.journalValue, "sdkRefresh")
        XCTAssertEqual(SyncTrigger.sdkProcessing.journalValue, "sdkProcessing")
        XCTAssertEqual(SyncTrigger.unlock.journalValue, "unlock")
        XCTAssertEqual(SyncTrigger.foreground.journalValue, "foreground")
        XCTAssertEqual(SyncTrigger.network.journalValue, "network")
        XCTAssertEqual(SyncTrigger.restore.journalValue, "restore")
        XCTAssertEqual(SyncTrigger.kickoff.journalValue, "kickoff")
    }

    // MARK: - RunStats

    func testStatsAccumulateConfirmedRecordsPerType() {
        let stats = RunStats()
        stats.addConfirmed(typeIdentifier: "HKQuantityTypeIdentifierHeartRate", count: 5)
        stats.addConfirmed(typeIdentifier: "HKQuantityTypeIdentifierHeartRate", count: 3)
        stats.addConfirmed(typeIdentifier: "HKQuantityTypeIdentifierBodyMass", count: 1)
        stats.addConfirmed(typeIdentifier: "HKQuantityTypeIdentifierStepCount", count: 0)

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.perType, [
            "HKQuantityTypeIdentifierHeartRate": 8,
            "HKQuantityTypeIdentifierBodyMass": 1
        ])
        XCTAssertEqual(snapshot.records, 9)
    }

    func testStatsKeepTheFirstRejectionAndTheFirstFailure() {
        let stats = RunStats()
        stats.recordRejected(httpStatus: 422)
        stats.recordRejected(httpStatus: 400)
        stats.recordFailure("first")
        stats.recordFailure("second")
        stats.markBudgetHit(.backgroundTime)
        stats.markBudgetHit(.budget)

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.rejectedHTTPStatus, 422)
        XCTAssertEqual(snapshot.failure, "first")
        XCTAssertEqual(snapshot.budgetReason, .backgroundTime)
    }

    func testRunStatsLiveAndDieWithTheirGeneration() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            XCTAssertNotNil(sdk.runStats(for: generation), "beginSyncRun legt die Statistik an")

            sdk.finishSync(generation: generation)
            XCTAssertNil(sdk.runStats(for: generation), "finishSync nimmt sie wieder heraus")
        }
    }

    // MARK: - Slot belegt

    func testBusySlotYieldsSkippedBusyOnceAndKeepsTheHoldersSlot() {
        withIsolatedSDK { sdk, _ in
            guard let holder = sdk.beginSyncRun() else {
                return XCTFail("The holder should claim the slot")
            }
            defer { sdk.finishSync(generation: holder) }

            observeRuns(on: sdk) { seen in
                var completions: [SyncOutcome] = []
                sdk.collectAllData(
                    fullExport: false, isBackground: false,
                    trigger: .observer("HKQuantityTypeIdentifierHeartRate"), deadline: nil
                ) { completions.append($0) }

                XCTAssertTrue(waitUntil { !completions.isEmpty })
                spin(0.2)

                XCTAssertEqual(completions.count, 1, "genau ein Ergebnis über die Completion")
                XCTAssertEqual(seen(), completions, "onRunCompleted feuert einmal mit demselben Ergebnis")
                XCTAssertEqual(completions.first?.status, .skippedBusy)
                XCTAssertEqual(completions.first?.trigger, .observer("HKQuantityTypeIdentifierHeartRate"))
                XCTAssertEqual(completions.first?.orchestration, .upstream)
                XCTAssertEqual(completions.first?.records, 0)
                XCTAssertTrue(sdk.isSyncInProgress, "der Halter behält den Slot")
                XCTAssertFalse(sdk.isSyncCancelled(generation: holder), "und wird nicht verdrängt")
            }
        }
    }

    func testPublicSyncReportsSkippedBusyWhileTheSlotIsHeld() {
        withIsolatedSDK { sdk, _ in
            guard let holder = sdk.beginSyncRun() else {
                return XCTFail("The holder should claim the slot")
            }
            defer { sdk.finishSync(generation: holder) }

            withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                var result: SyncOutcome?
                sdk.sync(trigger: .app("ui")) { result = $0 }

                XCTAssertTrue(waitUntil { result != nil })
                XCTAssertEqual(result?.status, .skippedBusy)
                XCTAssertEqual(result?.trigger, .app("ui"))
            }
        }
    }

    // MARK: - Vorprüfungen von sync(...)

    func testSyncWithoutTrackedTypesIsUpToDateWithZeroRecords() {
        withIsolatedSDK { sdk, _ in
            withTrackedTypes([], on: sdk) {
                observeRuns(on: sdk) { seen in
                    var result: SyncOutcome?
                    sdk.sync(trigger: .foreground) { result = $0 }

                    XCTAssertTrue(waitUntil { result != nil })
                    spin(0.1)
                    XCTAssertEqual(result?.status, .upToDate)
                    XCTAssertEqual(result?.records, 0)
                    XCTAssertEqual(result?.trigger, .foreground)
                    XCTAssertEqual(seen().count, 1, "auch ein Lauf ohne Arbeit wird gemeldet")
                }
            }
        }
    }

    func testSyncWithoutCredentialsFailsWithNoAuth() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.volatileStore = [:]
            XCTAssertFalse(sdk.hasAuth, "Vorbedingung des Tests")

            withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                var result: SyncOutcome?
                sdk.sync { result = $0 }

                XCTAssertTrue(waitUntil { result != nil })
                XCTAssertEqual(result?.status, .failed("no auth"))
                XCTAssertEqual(result?.trigger, .app("manual"), "Vorgabe des öffentlichen Aufrufs")
            }
        }
    }

    /// Nur Typen, die HealthKit nicht abfragen lässt (Blutdruck-Korrelation): der Lauf
    /// endet nach dem Anlegen der Generation und vor der ersten Abfrage.
    func testOnlyUnqueryableTypesEndAsUpToDateAndReleaseTheSlot() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable(), "HealthKit nicht verfügbar")
        withIsolatedSDK { sdk, _ in
            withTrackedTypes([HKCorrelationType(.bloodPressure)], on: sdk) {
                var result: SyncOutcome?
                sdk.sync(trigger: .network) { result = $0 }

                XCTAssertTrue(waitUntil { result != nil })
                XCTAssertEqual(result?.status, .upToDate)
                XCTAssertEqual(result?.trigger, .network)
                XCTAssertEqual(result?.orchestration, .upstream)
                XCTAssertFalse(sdk.isSyncInProgress, "der Slot ist wieder frei")
                XCTAssertGreaterThanOrEqual(result?.finished ?? .distantPast, result?.started ?? .distantFuture)
            }
        }
    }

    // MARK: - Frist (deadline)

    /// Eine abgelaufene Frist beendet den Lauf vor der ersten Abfrage mit einem
    /// Budget-Grund. Ohne Frist ändert sich am Ablauf nichts (alle 0.15-Tests bleiben grün).
    func testExpiredDeadlineStopsBeforeTheFirstFetchAsPartialBudget() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable(), "HealthKit nicht verfügbar")
        withIsolatedDefaults { defaults in
            withIsolatedSDK { sdk, _ in
                // Erst-Export erledigt: der Lauf ist inkrementell und braucht kein
                // Start-Log (das fasst UIApplication an, und die gibt es im Test nicht).
                defaults.set(true, forKey: sdk.fullDoneKey())

                withTrackedTypes([HKQuantityType(.stepCount)], on: sdk) {
                    var result: SyncOutcome?
                    sdk.sync(trigger: .sdkRefresh, deadline: Date(timeIntervalSinceNow: -1)) { result = $0 }

                    XCTAssertTrue(waitUntil { result != nil })
                    XCTAssertEqual(result?.status, .partial(.budget))
                    XCTAssertEqual(result?.records, 0)
                    XCTAssertEqual(result?.trigger, .sdkRefresh)
                    XCTAssertFalse(result?.backfillPending ?? true, "inkrementell, kein offener Export")
                    XCTAssertFalse(sdk.isSyncInProgress)
                }
            }
        }
    }

    // MARK: - syncNow (deprecated Hülle)

    func testSyncNowCallsItsCompletionExactlyOnce() {
        withIsolatedSDK { sdk, _ in
            withTrackedTypes([], on: sdk) {
                var calls = 0
                // swiftlint:disable:next deprecated
                sdk.syncNow { calls += 1 }

                XCTAssertTrue(waitUntil { calls > 0 })
                spin(0.2)
                XCTAssertEqual(calls, 1)
            }
        }
    }

    // MARK: - Upload meldet seinen Status

    func testUploadAcceptedCarriesTheStatusAndLeavesTheStatsClean() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(202) }
            let run = upload(on: sdk)

            XCTAssertEqual(run.result, .accepted(202))
            XCTAssertNil(run.stats?.rejectedHTTPStatus)
            XCTAssertNil(run.stats?.failure)
        }
    }

    func testUploadRejectedRecordsTheHTTPStatusInTheStatsOfItsGeneration() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(422, #"{"detail":"bad record"}"#) }
            let run = upload(on: sdk)

            XCTAssertEqual(run.result, .rejected(422))
            XCTAssertEqual(run.stats?.rejectedHTTPStatus, 422)
            XCTAssertEqual(
                RunStats.status(
                    completed: false, records: 0, locked: false,
                    rejectedHTTPStatus: run.stats?.rejectedHTTPStatus, failure: run.stats?.failure,
                    budgetReason: nil, cancelled: false
                ),
                .rejected(httpStatus: 422)
            )
        }
    }

    func testUploadServerErrorIsAFailureNotARejection() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(500) }
            let run = upload(on: sdk)

            XCTAssertEqual(run.result, .failed("HTTP 500"))
            XCTAssertNil(run.stats?.rejectedHTTPStatus)
            XCTAssertEqual(run.stats?.failure, "HTTP 500")
        }
    }

    func testUploadTransportErrorIsAFailure() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .failure(URLError(.networkConnectionLost)) }
            let run = upload(on: sdk)

            XCTAssertEqual(run.result, .failed("network(-1005)"))
            XCTAssertEqual(run.stats?.failure, "network(-1005)")
        }
    }

    /// Das alte Verhalten bleibt: ein abgelehntes Refresh-Token meldet `onAuthError` und
    /// ist ein Auth-Fehler, keine Ablehnung der Daten.
    func testUploadWithRejectedRefreshIsAnAuthFailure() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(401) }
            let run = upload(on: sdk)

            XCTAssertEqual(run.result, .failed("auth 401"))
            XCTAssertNil(run.stats?.rejectedHTTPStatus)
        }
    }

    func testUploadRetriedAfterRefreshIsAcceptedWithTheRetryStatus() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { request in
                if request.url?.path.hasSuffix("/token/refresh") == true {
                    return .status(200, #"{"access_token":"access-2","refresh_token":"refresh-2"}"#)
                }
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2"
                    ? .status(202) : .status(401)
            }
            let run = upload(on: sdk)

            XCTAssertEqual(run.result, .accepted(202))
        }
    }

    func testUploadOfACancelledRunIsCancelledAndMarksTheStats() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(200) }
            let run = upload(on: sdk, cancelFirst: true)

            XCTAssertEqual(run.result, .cancelled)
            XCTAssertEqual(run.stats?.cancelled, true)
        }
    }
}
