import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Observer-Vertrag, Nachholen auf Anforderung und die Messhaken (Plan 05-08, Pattern 8, D-15).
///
/// Ohne HealthKit prüfbar: die Zyklen enden an der Sperre des Kerns, die Sonde an unbekannten
/// Typen, und `rowID(from:)` liest ein Archiv, das der Test selbst herstellt.
final class LaneControlsTests: XCTestCase {

    private let heartRate = "HKQuantityTypeIdentifierHeartRate"

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

    private func withProtectedData(
        _ available: Bool?, on sdk: OpenWearablesHealthSDK, _ body: () -> Void
    ) {
        let previous = sdk.protectedDataAvailableCache
        sdk.protectedDataAvailableCache = available
        defer { sdk.protectedDataAvailableCache = previous }
        body()
    }

    /// Setzt die Obergrenze des Observer-Wartens, `var` als Testnaht.
    private func withObserverCap(_ seconds: TimeInterval, _ body: () -> Void) {
        let previous = OpenWearablesHealthSDK.observerCompletionCap
        OpenWearablesHealthSDK.observerCompletionCap = seconds
        defer { OpenWearablesHealthSDK.observerCompletionCap = previous }
        body()
    }

    /// Thread-sicherer Zähler für Rückmeldungen, die auf beliebigen Threads kommen.
    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - OneShot

    func testOneShotRunsItsActionExactlyOnceEvenWhenFiredTwice() {
        let counter = Counter()
        let shot = OneShot { counter.increment() }

        XCTAssertFalse(shot.hasFired)
        XCTAssertTrue(shot.fire(), "der erste Aufruf führt aus")
        XCTAssertFalse(shot.fire(), "der zweite tut nichts")
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(shot.hasFired)
    }

    func testOneShotRunsOnceUnderConcurrentFiresAndATimer() {
        for _ in 0..<20 {
            let counter = Counter()
            let shot = OneShot { counter.increment() }
            shot.fireAfter(0.002)
            DispatchQueue.concurrentPerform(iterations: 64) { _ in shot.fire() }
            spin(0.05)
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testOneShotTimerFiresWhenNobodyElseDoes() {
        let counter = Counter()
        let shot = OneShot { counter.increment() }
        shot.fireAfter(0.02)

        XCTAssertTrue(waitUntil { counter.count == 1 })
        spin(0.05)
        XCTAssertEqual(counter.count, 1)
        XCTAssertFalse(shot.fire(), "nach dem Zeitgeber tut ein späterer Aufruf nichts")
    }

    func testObserverCompletionsFireEachShotOnceAndForgetFiredOnes() {
        let completions = ObserverCompletions()
        let a = Counter()
        let b = Counter()
        let early = OneShot { a.increment() }
        completions.add(early)
        early.fire()
        completions.add(OneShot { b.increment() })
        XCTAssertEqual(completions.count, 1, "was schon gefeuert hat, braucht keinen Platz")

        XCTAssertEqual(completions.fireAll(), 1)
        XCTAssertEqual(completions.fireAll(), 0, "zweimal ergibt nichts")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(completions.count, 0)
    }

    // MARK: - Observer-Vertrag

    /// Im Modus upstream bleibt es beim Original: erst der Auslöser, dann sofort die Rückmeldung.
    func testUpstreamAnswersTheObserverImmediatelyAfterTriggering() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .upstream) { sdk, _ in
                var order: [String] = []
                sdk.handleObserverWake(
                    typeIdentifier: heartRate,
                    completionHandler: { order.append("completion") },
                    trigger: { order.append("trigger:\($0 ?? "-")") }
                )
                XCTAssertEqual(order, ["trigger:\(heartRate)", "completion"])
                XCTAssertEqual(sdk.observerCompletions.count, 0, "nichts wird zurückgehalten")
            }
        }
    }

    /// Im Modus lanes bleibt die Rückmeldung aus, bis jemand die Live-Runde meldet, und kommt dann
    /// genau einmal.
    func testLanesHoldsTheObserverCompletionUntilTheLiveRoundIsDone() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                withObserverCap(30) {
                    let counter = Counter()
                    var triggered: [String?] = []
                    sdk.handleObserverWake(
                        typeIdentifier: heartRate,
                        completionHandler: { counter.increment() },
                        trigger: { triggered.append($0) }
                    )
                    XCTAssertEqual(triggered, [heartRate])
                    spin(0.05)
                    XCTAssertEqual(counter.count, 0, "vor der Live-Runde keine Rückmeldung")

                    sdk.fireObserverCompletions()
                    sdk.fireObserverCompletions()
                    XCTAssertEqual(counter.count, 1, "danach genau eine")
                }
            }
        }
    }

    /// Spätestens nach der Obergrenze kommt die Rückmeldung, auch ohne dass ein Zyklus lief, und
    /// ein späteres Feuern ändert nichts.
    func testLanesAnswersTheObserverAtTheLatestAfterTheCap() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                withObserverCap(0.05) {
                    let counter = Counter()
                    sdk.handleObserverWake(typeIdentifier: heartRate, completionHandler: { counter.increment() }, trigger: { _ in })

                    XCTAssertTrue(waitUntil { counter.count == 1 })
                    sdk.fireObserverCompletions()
                    spin(0.1)
                    XCTAssertEqual(counter.count, 1, "genau einmal, auch mit Zeitgeber und Zyklus")
                }
            }
        }
    }

    /// Mit einem echten Zyklus (hier: gesperrt, der Kern endet vor jeder Abfrage) kommt die
    /// Rückmeldung vom Zyklus, lange vor der Obergrenze.
    func testTheCycleAnswersTheObserverLongBeforeTheCap() throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable(), "HealthKit nicht verfügbar")
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                withObserverCap(30) {
                    withProtectedData(false, on: sdk) {
                        withTrackedTypes([HKQuantityType(.heartRate)], on: sdk) {
                            let counter = Counter()
                            var outcome: SyncOutcome?
                            sdk.handleObserverWake(
                                typeIdentifier: heartRate,
                                completionHandler: { counter.increment() },
                                trigger: { identifier in
                                    sdk.sync(trigger: .observer(identifier)) { outcome = $0 }
                                }
                            )

                            XCTAssertTrue(waitUntil(timeout: 5) { counter.count == 1 && outcome != nil })
                            spin(0.1)
                            XCTAssertEqual(counter.count, 1)
                            XCTAssertEqual(outcome?.status, .deferredLocked)
                            XCTAssertEqual(outcome?.trigger, .observer(heartRate))
                            XCTAssertEqual(sdk.observerCompletions.count, 0)
                        }
                    }
                }
            }
        }
    }

    /// Ein Auslöser, den der Slot abweist, hat nichts, worauf der Observer warten könnte.
    func testASkippedRunAnswersTheObserverToo() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                guard let holder = sdk.beginSyncRun() else { return XCTFail("slot") }
                defer { sdk.finishSync(generation: holder) }

                withObserverCap(30) {
                    withTrackedTypes([HKQuantityType(.heartRate)], on: sdk) {
                        let counter = Counter()
                        var outcome: SyncOutcome?
                        sdk.handleObserverWake(
                            typeIdentifier: heartRate,
                            completionHandler: { counter.increment() },
                            trigger: { identifier in
                                sdk.sync(trigger: .observer(identifier)) { outcome = $0 }
                            }
                        )
                        XCTAssertTrue(waitUntil { outcome != nil })
                        XCTAssertEqual(outcome?.status, .skippedBusy)
                        XCTAssertEqual(counter.count, 1)
                    }
                }
            }
        }
    }

    /// Review ME-01: Ein Observer-Lauf im Hintergrund bekommt eine Frist knapp vor dem Ende seiner
    /// Hintergrundzeit, statt ohne Frist zu laufen und mitten im Upload suspendiert zu werden.
    func testAnObserverRunInTheBackgroundGetsADeadlineInsideItsBackgroundTime() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(OpenWearablesHealthSDK.observerDeadline(now: now, backgroundTimeRemaining: 30), now.addingTimeInterval(25))
        XCTAssertEqual(OpenWearablesHealthSDK.observerDeadline(now: now, backgroundTimeRemaining: 3), now, "nie in der Vergangenheit")
        XCTAssertEqual(
            OpenWearablesHealthSDK.observerDeadline(now: now, backgroundTimeRemaining: .greatestFiniteMagnitude),
            now.addingTimeInterval(295), "unbegrenzte Zeit wird gedeckelt"
        )
    }

    // MARK: - requestBackfill

    func testRequestBackfillQueuesATypeWithoutTouchingItsAnchor() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.heartRate)], on: sdk) {
                        let anchor = Data([1, 2, 3, 4])
                        sdk.saveAnchorData(anchor, typeIdentifier: heartRate, userKey: sdk.userKey())
                        let anchorKey = sdk.anchorKey(typeIdentifier: heartRate, userKey: sdk.userKey())

                        let accepted = sdk.requestBackfill(
                            typeIdentifiers: [heartRate, "HKQuantityTypeIdentifierNotTracked"]
                        )

                        XCTAssertTrue(accepted)
                        let entries = sdk.makeBackfillStore().load().entries
                        XCTAssertEqual(Set(entries.keys), [heartRate], "der unbekannte Identifier wird ignoriert")
                        XCTAssertEqual(entries[heartRate]?.state, .pending)
                        XCTAssertEqual(entries[heartRate]?.origin, "request")
                        XCTAssertEqual(sdk.defaults.data(forKey: anchorKey), anchor, "Anchor-Bytes unverändert")

                        let journal = sdk.journalEntries().filter { $0.kind == "backfill" }
                        XCTAssertEqual(journal.count, 1)
                        XCTAssertTrue(journal.first?.note?.contains("request:HeartRate") ?? false, journal.first?.note ?? "")
                        XCTAssertFalse(journal.first?.note?.contains("NotTracked") ?? true)

                        // Der angestoßene Zyklus endet an der Sperre und lässt den Eintrag, wie er ist.
                        XCTAssertTrue(waitUntil { !sdk.isSyncInProgress })
                        spin(0.1)
                        XCTAssertEqual(sdk.makeBackfillStore().load().entries[heartRate]?.state, .pending)
                    }
                }
            }
        }
    }

    /// Ein Typ, der schon nachholt, behält seinen Stand: ein zweiter Aufruf beginnt nicht von vorn.
    func testRequestBackfillKeepsTheProgressOfATypeThatIsAlreadyCatchingUp() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.heartRate)], on: sdk) {
                        var plan = BackfillPlan.empty()
                        let begin = Date(timeIntervalSince1970: 1_790_000_000)
                        plan.start(typeId: heartRate, now: begin, daysBack: 14, origin: "bootstrap")
                        plan.advance(typeId: heartRate, to: begin.addingTimeInterval(-5 * 86_400), boundaryIds: ["x"])
                        try? sdk.makeBackfillStore().save(plan)
                        let progressed = plan.entries[heartRate]

                        XCTAssertTrue(sdk.requestBackfill(typeIdentifiers: [heartRate]))

                        XCTAssertEqual(sdk.makeBackfillStore().load().entries[heartRate], progressed)
                        XCTAssertTrue(waitUntil { !sdk.isSyncInProgress })
                        spin(0.1)
                    }
                }
            }
        }
    }

    private final class MemoryLedgerStorage: MirrorDedupeStorage {
        var data: Data?
        func loadDedupeState() -> Data? { data }
        func saveDedupeState(_ data: Data?) { self.data = data }
    }

    /// Ohne das Zurücksetzen gälte das erneute Senden eines Messwerts als Spiegelkopie und käme nie an.
    /// Nur die angeforderten Typen werden vergessen, die anderen Messwerte bleiben bekannt.
    func testRequestBackfillForgetsTheMirrorKeysOfThoseTypesOnly() {
        let bodyMass = "HKQuantityTypeIdentifierBodyMass"
        let bodyFat = "HKQuantityTypeIdentifierBodyFatPercentage"
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                let previous = sdk.mirrorDedupe
                sdk.mirrorDedupe = MirrorDedupeLedger(storage: MemoryLedgerStorage())
                defer { sdk.mirrorDedupe = previous }
                let moment = Date(timeIntervalSince1970: 1_790_000_000)
                let massKey = MeasurementKey(type: bodyMass, start: moment, end: moment, value: 80.1)
                let fatKey = MeasurementKey(type: bodyFat, start: moment, end: moment, value: 0.21)
                sdk.mirrorDedupe.commit([massKey, fatKey])
                XCTAssertEqual(sdk.mirrorDedupe.count, 2)

                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage)], on: sdk) {
                        XCTAssertTrue(sdk.requestBackfill(typeIdentifiers: [bodyMass]))

                        XCTAssertEqual(sdk.mirrorDedupe.count, 1)
                        XCTAssertEqual(sdk.mirrorDedupe.filterMirrored(["x"], key: { _ in massKey }).kept, ["x"],
                                       "der Gewichtswert gilt wieder als neu")
                        XCTAssertTrue(sdk.mirrorDedupe.filterMirrored(["x"], key: { _ in fatKey }).kept.isEmpty,
                                      "das Körperfett bleibt bekannt")
                        XCTAssertTrue(waitUntil { !sdk.isSyncInProgress })
                        spin(0.1)
                    }
                }
            }
        }
    }

    /// ME-04: Ein Typ, der schon nachholt, behält auch seinen Spiegel-Abgleich. Zurückgesetzt wird
    /// nur, was wirklich neu vorgemerkt wurde; sonst gingen Spiegelkopien alter Messwerte doppelt raus.
    func testRequestBackfillForATypeThatIsAlreadyCatchingUpKeepsItsMirrorKeys() {
        let bodyMass = "HKQuantityTypeIdentifierBodyMass"
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                let previous = sdk.mirrorDedupe
                sdk.mirrorDedupe = MirrorDedupeLedger(storage: MemoryLedgerStorage())
                defer { sdk.mirrorDedupe = previous }
                let moment = Date(timeIntervalSince1970: 1_790_000_000)
                sdk.mirrorDedupe.commit([MeasurementKey(type: bodyMass, start: moment, end: moment, value: 80.1)])

                var plan = BackfillPlan.empty()
                plan.start(typeId: bodyMass, now: moment, daysBack: 14, origin: "bootstrap")
                try? sdk.makeBackfillStore().save(plan)

                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.bodyMass)], on: sdk) {
                        XCTAssertTrue(sdk.requestBackfill(typeIdentifiers: [bodyMass]))
                        XCTAssertEqual(sdk.mirrorDedupe.count, 1, "nichts neu vorgemerkt, nichts vergessen")
                        XCTAssertTrue(waitUntil { !sdk.isSyncInProgress })
                        spin(0.1)
                    }
                }
            }
        }
    }

    /// ME-04: Die App erfährt, was neu vorgemerkt wurde und was schon lief, statt eines bloßen `true`.
    func testRequestBackfillTypesTellsNewlyQueuedFromAlreadyPendingAndIgnored() {
        let steps = "HKQuantityTypeIdentifierStepCount"
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                var plan = BackfillPlan.empty()
                plan.start(typeId: heartRate, now: Date(timeIntervalSince1970: 1_790_000_000), daysBack: 14, origin: "bootstrap")
                try? sdk.makeBackfillStore().save(plan)

                withProtectedData(false, on: sdk) {
                    withTrackedTypes([HKQuantityType(.heartRate), HKQuantityType(.stepCount)], on: sdk) {
                        let result = sdk.requestBackfillTypes([heartRate, steps, "HKQuantityTypeIdentifierNotTracked"])

                        XCTAssertEqual(result.queued, [steps])
                        XCTAssertEqual(result.alreadyPending, [heartRate])
                        XCTAssertEqual(result.ignored, ["HKQuantityTypeIdentifierNotTracked"])
                        XCTAssertFalse(result.failed)
                        XCTAssertEqual(sdk.makeBackfillStore().load().entries[steps]?.origin, "request")
                        XCTAssertTrue(waitUntil { !sdk.isSyncInProgress })
                        spin(0.1)
                    }
                }
            }
        }
    }

    func testRequestBackfillWithOnlyUnknownTypesDoesNothing() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                withTrackedTypes([HKQuantityType(.heartRate)], on: sdk) {
                    XCTAssertFalse(sdk.requestBackfill(typeIdentifiers: ["HKQuantityTypeIdentifierNotTracked", ""]))
                    XCTAssertFalse(sdk.requestBackfill(typeIdentifiers: []))
                    XCTAssertTrue(sdk.makeBackfillStore().load().entries.isEmpty)
                    XCTAssertTrue(sdk.journalEntries().filter { $0.kind == "backfill" }.isEmpty)
                    XCTAssertFalse(sdk.isSyncInProgress, "kein Zyklus wurde angestoßen")
                }
            }
        }
    }

    func testRequestBackfillInUpstreamModeDoesNothing() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .upstream) { sdk, directory in
                withTrackedTypes([HKQuantityType(.heartRate)], on: sdk) {
                    XCTAssertFalse(sdk.requestBackfill(typeIdentifiers: [heartRate]))
                    XCTAssertTrue(sdk.makeBackfillStore().load().entries.isEmpty)
                    XCTAssertFalse(FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("health_lanes").path
                    ), "keine Datei entstanden")
                    XCTAssertTrue(sdk.journalEntries().filter { $0.kind == "backfill" }.isEmpty)
                    XCTAssertFalse(sdk.isSyncInProgress)
                }
            }
        }
    }

    // MARK: - Anchor-Sonde (Spike S1)

    private func archivedAnchor(_ value: Int) -> Data {
        // swiftlint:disable:next force_try
        try! NSKeyedArchiver.archivedData(withRootObject: HKQueryAnchor(fromValue: value), requiringSecureCoding: true)
    }

    func testRowIDReadsTheValueOfAnArchivedAnchor() {
        XCTAssertEqual(AnchorProbe.rowID(from: archivedAnchor(4711)), 4711)
        XCTAssertEqual(AnchorProbe.rowID(from: archivedAnchor(0)), 0, "ein Typ ohne je einen Eintrag steht auf 0")
        XCTAssertEqual(AnchorProbe.rowID(from: archivedAnchor(7_635_000)), 7_635_000)
    }

    /// Das Archiv vom Gerät: `$objects[1]` trägt `rowid` und `clientToken` (Recherche, Befund 7).
    func testRowIDReadsTheLayoutSeenOnTheDevice() throws {
        let archive: [String: Any] = [
            "$archiver": "NSKeyedArchiver",
            "$version": 100_000,
            "$top": ["root": 1],
            "$objects": ["$null", ["rowid": 6_234_440, "clientToken": "token"]] as [Any]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        XCTAssertEqual(AnchorProbe.rowID(from: data), 6_234_440)
    }

    func testRowIDOfSomethingUnreadableIsNil() throws {
        XCTAssertNil(AnchorProbe.rowID(from: Data()))
        XCTAssertNil(AnchorProbe.rowID(from: Data("kein Archiv".utf8)))
        let withoutRow = try PropertyListSerialization.data(
            fromPropertyList: ["$objects": ["$null", ["other": 1]] as [Any]], format: .binary, options: 0
        )
        XCTAssertNil(AnchorProbe.rowID(from: withoutRow))
        let notADictionary = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)
        XCTAssertNil(AnchorProbe.rowID(from: notADictionary))
    }

    func testTheProbeNoteNamesTheMeasurementsAndNothingElse() {
        let result = AnchorProbeResult(
            typeIdentifier: "HKQuantityTypeIdentifierBodyMass", probeRowID: 6_234_440, walkRowID: 6_234_440,
            sameAnchor: true, probeMs: 12, walkMs: 340, error: nil
        )
        XCTAssertEqual(
            OpenWearablesHealthSDK.spikeNote(result, short: "BodyMass"),
            "S1 BodyMass probe=6234440 walk=6234440 same=true probeMs=12 walkMs=340"
        )
        let failed = AnchorProbeResult(
            typeIdentifier: "HKQuantityTypeIdentifierBodyMass", probeRowID: nil, walkRowID: 5,
            sameAnchor: false, probeMs: 3, walkMs: 9, error: "probe=locked"
        )
        XCTAssertEqual(
            OpenWearablesHealthSDK.spikeNote(failed, short: "BodyMass"),
            "S1 BodyMass probe=nil walk=5 same=false probeMs=3 walkMs=9 error=probe=locked"
        )
    }

    /// Ein Typ, den die Verfolgung nicht kennt, wird nie abgefragt: Fehlertext, kein HealthKit-Zugriff,
    /// ein Journal-Eintrag je Typ, nichts festgeschrieben. Die Rückmeldung kommt auf der Hauptschlange.
    func testProbingAnUnknownTypeReportsItWithoutTouchingAnything() {
        withIsolatedDefaults { defaults in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                let anchorsBefore = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("anchor.") }
                var results: [AnchorProbeResult]?
                var onMain = false
                sdk.probeAnchors(typeIdentifiers: ["HKQuantityTypeIdentifierNoSuchType", "HKCategoryTypeIdentifierAlsoNot"]) {
                    onMain = Thread.isMainThread
                    results = $0
                }

                XCTAssertTrue(waitUntil { results != nil })
                XCTAssertTrue(onMain)
                XCTAssertEqual(results?.count, 2)
                XCTAssertEqual(results?.first?.error, "unknown type")
                XCTAssertEqual(results?.first?.sameAnchor, false)
                XCTAssertNil(results?.first?.probeRowID)

                let spikes = sdk.journalEntries().filter { $0.kind == "spike" }
                XCTAssertEqual(spikes.count, 2)
                XCTAssertEqual(
                    spikes.first?.note,
                    "S1 NoSuchType probe=nil walk=nil same=false probeMs=0 walkMs=0 error=unknown type"
                )
                XCTAssertEqual(
                    defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("anchor.") }.sorted(),
                    anchorsBefore.sorted(), "die Sonde schreibt keinen Anchor"
                )
                XCTAssertFalse(sdk.lanesAnchorProbe, "der Schalter bleibt, wie er war")
            }
        }
    }

    func testProbingNothingStillAnswers() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                var results: [AnchorProbeResult]?
                sdk.probeAnchors(typeIdentifiers: []) { results = $0 }
                XCTAssertTrue(waitUntil { results != nil })
                XCTAssertEqual(results, [])
            }
        }
    }

    // MARK: - Szenario 4: hängender Abruf

    #if DEBUG
    /// Das Einmal-Flag wirkt auf genau den nächsten `fetchLive`-Aufruf: der hängt (die Completion
    /// kommt nie), der übernächste verhält sich wieder normal.
    func testTheHangFlagActsOnExactlyTheNextLiveFetch() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                let reader = HealthKitReader(sdk: sdk, generation: 1)
                sdk.debugHangNextLiveFetch()

                let hung = Counter()
                reader.fetchLive(typeId: "HKQuantityTypeIdentifierNoSuchType", anchor: Data(), limit: 1) { _ in hung.increment() }
                spin(0.2)
                XCTAssertEqual(hung.count, 0, "die Completion des ersten Aufrufs kommt nie")

                let normal = Counter()
                var failure: ReadFailure?
                reader.fetchLive(typeId: "HKQuantityTypeIdentifierNoSuchType", anchor: Data(), limit: 1) {
                    if case .failure(let reason) = $0 { failure = reason }
                    normal.increment()
                }
                XCTAssertEqual(normal.count, 1, "das Flag ist verbraucht")
                XCTAssertEqual(failure, .other("unknown type"))
                XCTAssertFalse(sdk.consumeHangNextLiveFetch())

                let notes = sdk.journalEntries().filter { $0.kind == "spike" }.compactMap { $0.note }
                XCTAssertEqual(notes.count, 2)
                XCTAssertEqual(notes.first, "hang armed")
                XCTAssertTrue(notes.last?.hasPrefix("hang fired") ?? false, notes.last ?? "")
            }
        }
    }

    func testTheHangFlagIsNotSetWithoutTheCall() {
        withIsolatedDefaults { _ in
            withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                XCTAssertFalse(sdk.consumeHangNextLiveFetch())
                sdk.debugHangNextLiveFetch()
                XCTAssertTrue(sdk.consumeHangNextLiveFetch())
                XCTAssertFalse(sdk.consumeHangNextLiveFetch(), "ein Einmal-Flag")
            }
        }
    }
    #endif
}
