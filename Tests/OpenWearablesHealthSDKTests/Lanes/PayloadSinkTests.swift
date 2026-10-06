import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Der Paket-Sender der Spuren (Plan 05-07): Paketformat, Löschungen hinter dem Schalter,
/// Herkunft der Pakete und die Abbildung der Serverantworten. Echte `HKQuantitySample`-Objekte
/// brauchen keinen Health-Store.
final class PayloadSinkTests: XCTestCase {

    private let weight = "HKQuantityTypeIdentifierBodyMass"
    private let steps = "HKQuantityTypeIdentifierStepCount"
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private final class LedgerStorage: MirrorDedupeStorage {
        var data: Data?
        func loadDedupeState() -> Data? { data }
        func saveDedupeState(_ data: Data?) { self.data = data }
    }

    private struct Harness {
        let sdk: OpenWearablesHealthSDK
        let directory: URL
        let queue: DeletionQueue
        let backfill: FileBackfillStore
        let generation: Int

        func sink(sendDeletions: Bool?, credential: String = "access-1") -> PayloadSink {
            guard let endpoint = sdk.syncEndpoint else { preconditionFailure("kein Endpunkt") }
            return PayloadSink(
                sdk: sdk, endpoint: endpoint, credential: credential, generation: generation,
                deletions: queue, backfill: backfill, sendDeletions: sendDeletions
            )
        }
    }

    /// Eigener Ledger je Test: `lazy var mirrorDedupe` hält sonst die Suite des ersten Zugriffs und
    /// ließe Messwerte zwischen Tests überleben.
    private func withHarness(
        orchestration: SyncOrchestration = .upstream, _ body: (Harness) throws -> Void
    ) throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: orchestration) { sdk, directory in
                let previousLedger = sdk.mirrorDedupe
                sdk.mirrorDedupe = MirrorDedupeLedger(storage: LedgerStorage())
                defer { sdk.mirrorDedupe = previousLedger }

                guard let generation = sdk.beginSyncRun() else {
                    return XCTFail("Slot ließ sich nicht belegen")
                }
                defer { sdk.finishSync(generation: generation) }

                try body(Harness(
                    sdk: sdk, directory: directory,
                    queue: sdk.makeDeletionQueue(), backfill: sdk.makeBackfillStore(),
                    generation: generation
                ))
            }
        }
    }

    private func weightSample(_ kilos: Double, offset: TimeInterval = 0) -> HKQuantitySample {
        let date = epoch.addingTimeInterval(offset)
        return HKQuantitySample(
            type: HKQuantityType(.bodyMass),
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kilos),
            start: date, end: date
        )
    }

    private func heartRateSample(_ bpm: Double, offset: TimeInterval = 0) -> HKQuantitySample {
        let date = epoch.addingTimeInterval(offset)
        return HKQuantitySample(
            type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: bpm),
            start: date, end: date
        )
    }

    private func sleepSample(offset: TimeInterval = 0) -> HKCategorySample {
        let date = epoch.addingTimeInterval(offset)
        return HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: date, end: date.addingTimeInterval(1800)
        )
    }

    private func stepsSample(_ count: Double, offset: TimeInterval = 0) -> HKQuantitySample {
        let date = epoch.addingTimeInterval(offset)
        return HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: count),
            start: date, end: date.addingTimeInterval(60)
        )
    }

    private func ref(_ id: String, type: String? = nil) -> DeletedRef {
        DeletedRef(id: id, type: type ?? weight)
    }

    private func deliver(
        _ sink: PayloadSink, _ items: [HKSample], deleted: [DeletedRef] = [], lane: Lane = .live,
        file: StaticString = #filePath, line: UInt = #line
    ) -> DeliveryResult? {
        var result: DeliveryResult?
        sink.deliver(items, deleted: deleted, lane: lane) { result = $0 }
        waitUntil { result != nil }
        if result == nil { XCTFail("Der Rückruf kam nie", file: file, line: line) }
        return result
    }

    private func sentBodies() -> [[String: Any]] {
        StubURLProtocol.recorded(matching: "/sync").compactMap { $0.json }
    }

    private func dataSection(_ body: [String: Any]) -> [String: Any] {
        body["data"] as? [String: Any] ?? [:]
    }

    private func deletedIds(_ body: [String: Any]) -> [String]? {
        (dataSection(body)["deleted"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
    }

    // MARK: buildCombinedPayload bleibt additiv

    func testThePayloadWithoutTheNewArgumentsHasNoDeletedKeyAndTheOldShape() {
        withIsolatedSDK { sdk, _ in
            let payload = sdk.buildCombinedPayload(samples: [weightSample(80)])
            let data = payload["data"] as? [String: Any]
            XCTAssertEqual(Set(data?.keys ?? [:].keys), ["workouts", "records", "sleep"])
            XCTAssertNil(payload["syncType"], "ohne Sitzungsdatei und ohne Angabe: keine Herkunft, wie bisher")
            XCTAssertNil(payload["syncSessionId"])
        }
    }

    func testWithoutAnAttributionTheRunningSyncSessionStillDecides() {
        withIsolatedSDK { sdk, _ in
            let state = sdk.startNewSyncState(fullExport: true, types: [])
            let payload = sdk.buildCombinedPayload(samples: [])
            XCTAssertEqual(payload["syncSessionId"] as? String, state.sessionId)
            XCTAssertEqual(payload["syncType"] as? String, "historical")
        }
    }

    func testALiveAttributionCarriesSyncTypeLiveAndNoSessionId() {
        withIsolatedSDK { sdk, _ in
            let payload = sdk.buildCombinedPayload(samples: [], attribution: (sessionId: nil, syncType: "live"))
            XCTAssertEqual(payload["syncType"] as? String, "live")
            XCTAssertNil(payload["syncSessionId"])
        }
    }

    func testAHistoricalAttributionCarriesBothFields() {
        withIsolatedSDK { sdk, _ in
            let payload = sdk.buildCombinedPayload(samples: [], attribution: (sessionId: "S", syncType: "historical"))
            XCTAssertEqual(payload["syncType"] as? String, "historical")
            XCTAssertEqual(payload["syncSessionId"] as? String, "S")
        }
    }

    func testAnExplicitAttributionBeatsAnOpenHistoricalSyncState() {
        withIsolatedSDK { sdk, _ in
            _ = sdk.startNewSyncState(fullExport: true, types: [])
            let payload = sdk.buildCombinedPayload(samples: [], attribution: (sessionId: nil, syncType: "live"))
            XCTAssertEqual(payload["syncType"] as? String, "live", "Pitfall 7: ein Live-Paket ist nie historical")
            XCTAssertNil(payload["syncSessionId"])
        }
    }

    func testDeletedRefsBecomeIdTypePairsUnderData() throws {
        try withIsolatedSDK { sdk, _ in
            let payload = sdk.buildCombinedPayload(samples: [], deleted: [ref("d-1"), ref("d-2", type: steps)])
            let data = try XCTUnwrap(payload["data"] as? [String: Any])
            let deleted = try XCTUnwrap(data["deleted"] as? [[String: String]])
            XCTAssertEqual(deleted, [["id": "d-1", "type": weight], ["id": "d-2", "type": steps]])
        }
    }

    func testAnEmptyDeletedListLeavesNoKey() {
        withIsolatedSDK { sdk, _ in
            let data = sdk.buildCombinedPayload(samples: [], deleted: [])["data"] as? [String: Any]
            XCTAssertNil(data?["deleted"])
        }
    }

    // MARK: Schalter aus (Standard)

    func testSwitchOffSendsNoDeletedKeyAndReportsNotSent() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [weightSample(80)], deleted: [ref("gone")])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            let bodies = sentBodies()
            XCTAssertEqual(bodies.count, 1)
            XCTAssertNil(dataSection(bodies[0])["deleted"], "Railway bekommt das Feld nicht (T-05-26)")
            XCTAssertEqual((dataSection(bodies[0])["records"] as? [Any])?.count, 1)
        }
    }

    func testSwitchOffNeverReadsTheQueueNorMarksAnything() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("alt-1"), ref("alt-2")], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: false), [weightSample(80)], deleted: [ref("gone")])

            XCTAssertEqual(h.queue.stats().unsent, 2, "die Altlasten bleiben ungesendet")
        }
    }

    func testOnlyDeletionsAndSwitchOffMeansNoRequestAtAll() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [], deleted: [ref("gone")])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertEqual(StubURLProtocol.requests.count, 0)
        }
    }

    func testTheSwitchDefaultsToTheSdkSettingWhenNoneIsGiven() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: nil), [weightSample(80)], deleted: [ref("gone")])
            XCTAssertNil(dataSection(sentBodies()[0])["deleted"], "Standard aus")

            h.sdk.lanesSendDeletions = true
            StubURLProtocol.install { _ in .status(202) }
            _ = deliver(h.sink(sendDeletions: nil), [weightSample(81, offset: 5)], deleted: [ref("gone-2")])
            XCTAssertEqual(deletedIds(sentBodies()[0]), ["gone-2"])
        }
    }

    // MARK: Schalter an

    func testSwitchOnSendsTheDeletionAndOlderUnsentEntriesAndMarksThemSent() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("alt-1"), ref("alt-2", type: steps)], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("neu")])

            XCTAssertEqual(result, .accepted(sentDeleted: true))
            let bodies = sentBodies()
            XCTAssertEqual(bodies.count, 1)
            XCTAssertEqual(deletedIds(bodies[0]), ["neu", "alt-1", "alt-2"])
            let pairs = (dataSection(bodies[0])["deleted"] as? [[String: String]]) ?? []
            XCTAssertEqual(pairs.last, ["id": "alt-2", "type": steps])
            XCTAssertEqual(h.queue.stats().unsent, 0, "die Altlasten sind nach 2xx als gesendet markiert")
        }
    }

    func testSwitchOnWithOnlyDeletionsSendsAPackageWithoutRecords() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: true), [], deleted: [ref("nur-loeschung")])

            XCTAssertEqual(result, .accepted(sentDeleted: true))
            let bodies = sentBodies()
            XCTAssertEqual(bodies.count, 1)
            XCTAssertEqual(deletedIds(bodies[0]), ["nur-loeschung"])
            XCTAssertEqual((dataSection(bodies[0])["records"] as? [Any])?.count, 0)
        }
    }

    func testSwitchOnWithNothingToSendAtAllMeansNoRequestAndNotSent() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("alt")], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: true), [], deleted: [])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertEqual(StubURLProtocol.requests.count, 0)
            XCTAssertEqual(h.queue.stats().unsent, 1)
        }
    }

    func testAPackageWithoutAnyDeletionAndAnEmptyQueueHasNoDeletedKeyEvenWithTheSwitchOn() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertNil(dataSection(sentBodies()[0])["deleted"])
        }
    }

    func testAnOwnDeletionAlreadyInTheQueueIsSentOnlyOnce() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("doppelt"), ref("alt")], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("doppelt")])

            XCTAssertEqual(deletedIds(sentBodies()[0]), ["doppelt", "alt"])
        }
    }

    func testAtMostFiveHundredDeletionsGoOutPerPackageAndTheRestStaysUnsent() throws {
        try withHarness { h in
            try h.queue.enqueue((1...600).map { ref("alt-\($0)") }, sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("n1"), ref("n2"), ref("n3")])

            let ids = deletedIds(sentBodies()[0]) ?? []
            XCTAssertEqual(ids.count, 500)
            XCTAssertEqual(Array(ids.prefix(3)), ["n1", "n2", "n3"])
            XCTAssertEqual(ids[3], "alt-1", "die ältesten Altlasten zuerst")
            XCTAssertEqual(h.queue.stats().unsent, 600 - 497, "nur die mitgeschickten sind markiert")
        }
    }

    func testTheOwnDeletionsOfAPackageAlwaysGoOutCompletely() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("alt")], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            let own = (1...520).map { ref("own-\($0)") }
            let result = deliver(h.sink(sendDeletions: true), [], deleted: own)

            XCTAssertEqual(result, .accepted(sentDeleted: true))
            XCTAssertEqual(deletedIds(sentBodies()[0])?.count, 520, "gekürzt würden sie fälschlich als gesendet geführt")
            XCTAssertEqual(h.queue.stats().unsent, 1, "für Altlasten war kein Platz")
        }
    }

    // MARK: Antworten des Servers

    func testA422IsRejectedAndNothingIsCommittedOrMarked() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("alt")], sentAt: nil)
            StubURLProtocol.install { _ in .status(422, #"{"detail":"nope"}"#) }

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("neu")])

            XCTAssertEqual(result, .rejected(httpStatus: 422))
            XCTAssertEqual(h.queue.stats().unsent, 1)

            // Der Ledger hat den Messwert nicht festgeschrieben: eine Wiederholung sendet ihn wieder.
            StubURLProtocol.install { _ in .status(202) }
            _ = deliver(h.sink(sendDeletions: false), [weightSample(80)])
            XCTAssertEqual((dataSection(sentBodies()[0])["records"] as? [Any])?.count, 1)
        }
    }

    /// HI-02: Weist der Server ein Paket mit Löschungen ab (unbekanntes Feld `deleted`, eine Altlast),
    /// geht es einmal ohne Löschungen erneut raus. Sonst würden gültige Samples halbiert und am Ende
    /// geparkt, nur weil die Löschungen mitfuhren.
    func testARejectedPackageWithDeletionsIsRetriedOnceWithoutThem() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("alt")], sentAt: nil)
            let lock = NSLock()
            var calls = 0
            StubURLProtocol.install { _ in
                lock.lock()
                calls += 1
                let first = calls == 1
                lock.unlock()
                return first ? .status(422, #"{"detail":"deleted"}"#) : .status(202)
            }

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("neu")])

            XCTAssertEqual(result, .accepted(sentDeleted: false), "die Löschungen gingen nicht durch")
            let bodies = sentBodies()
            XCTAssertEqual(bodies.count, 2)
            XCTAssertEqual(deletedIds(bodies[0]), ["neu", "alt"])
            XCTAssertNil(dataSection(bodies[1])["deleted"], "die Wiederholung kommt ohne Löschungen")
            XCTAssertEqual((dataSection(bodies[1])["records"] as? [Any])?.count, 1)
            XCTAssertEqual(h.queue.stats().unsent, 1, "die Altlast bleibt ungesendet in der Warteschlange")
        }
    }

    func testARejectionThatAlsoHitsThePackageWithoutDeletionsStaysRejected() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(422) }

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("neu")])

            XCTAssertEqual(result, .rejected(httpStatus: 422))
            XCTAssertEqual(sentBodies().count, 2, "genau eine Wiederholung")
        }
    }

    func testARejectedPackageWithoutDeletionsIsNotRetried() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(422) }

            let result = deliver(h.sink(sendDeletions: false), [weightSample(80)], deleted: [ref("neu")])

            XCTAssertEqual(result, .rejected(httpStatus: 422))
            XCTAssertEqual(sentBodies().count, 1)
        }
    }

    func testA503IsFailedAndNothingIsMarked() throws {
        try withHarness { h in
            try h.queue.enqueue([ref("alt")], sentAt: nil)
            StubURLProtocol.install { _ in .status(503) }

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)])

            guard case .failed(let text)? = result else {
                return XCTFail("erwartet .failed, bekommen \(String(describing: result))")
            }
            XCTAssertTrue(text.contains("503"), text)
            XCTAssertEqual(h.queue.stats().unsent, 1)
        }
    }

    func testAnUploadOfACancelledRunIsCancelled() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }
            h.sdk.cancelSync()

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("gone")])

            XCTAssertEqual(result, .cancelled)
        }
    }

    // MARK: Herkunft der Pakete

    func testALivePackageCarriesSyncTypeLiveAndNoSessionId() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }
            // Eine Nachholsitzung ist angelegt: das Live-Paket darf sie nie übernehmen (Pitfall 7).
            var plan = BackfillPlan.empty()
            plan.sessionId = "SESSION-7"
            try h.backfill.save(plan)

            _ = deliver(h.sink(sendDeletions: false), [weightSample(80)], lane: .live)

            let body = sentBodies()[0]
            XCTAssertEqual(body["syncType"] as? String, "live")
            XCTAssertNil(body["syncSessionId"])
        }
    }

    func testABackfillPackageCarriesHistoricalAndTheSessionIdFromTheBackfillFile() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }
            var plan = BackfillPlan.empty()
            plan.sessionId = "SESSION-7"
            try h.backfill.save(plan)

            _ = deliver(h.sink(sendDeletions: false), [weightSample(80)], lane: .backfill)

            let body = sentBodies()[0]
            XCTAssertEqual(body["syncType"] as? String, "historical")
            XCTAssertEqual(body["syncSessionId"] as? String, "SESSION-7")
        }
    }

    func testThePackageSendsTheUpToDateCredentialOfTheSdkNotTheOneFromTheCycleStart() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: false, credential: "veraltet"), [weightSample(80)])

            XCTAssertEqual(
                StubURLProtocol.requests(matching: "/sync").first?.value(forHTTPHeaderField: "Authorization"),
                "Bearer access-1"
            )
        }
    }

    func testTheSinkNeverTouchesTheUpstreamSyncStateFile() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            let sink = h.sink(sendDeletions: true)
            _ = deliver(sink, [weightSample(80)], deleted: [ref("gone")], lane: .live)
            _ = deliver(sink, [weightSample(81, offset: 10)], lane: .backfill)
            _ = sink.parkingRecord(for: weightSample(82, offset: 20))

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: h.sdk.syncStateFilePath().path),
                "Pattern 9: im Modus lanes entsteht state.json nie"
            )
        }
    }

    // MARK: Mirror-Dedupe

    func testTwoIdenticalWeightsFromTwoAppsGoOutAsOne() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [weightSample(108.955), weightSample(108.955)])

            XCTAssertEqual((dataSection(sentBodies()[0])["records"] as? [Any])?.count, 1)
            XCTAssertEqual(result, .accepted(sentDeleted: false, notSent: [weight: 1]), "die Kopie ging nicht hinaus (ME-06)")
        }
    }

    func testAConfirmedWeightIsNotSentAgainButAnUnconfirmedOneIs() throws {
        try withHarness { h in
            let sink = h.sink(sendDeletions: false)
            StubURLProtocol.install { _ in .status(503) }
            XCTAssertNotNil(deliver(sink, [weightSample(80)]))
            XCTAssertEqual(StubURLProtocol.requests.count, 1)

            // Nicht bestätigt: ein neuer Versuch sendet den Messwert wieder.
            StubURLProtocol.install { _ in .status(202) }
            XCTAssertEqual(deliver(sink, [weightSample(80)]), .accepted(sentDeleted: false))
            XCTAssertEqual(StubURLProtocol.requests.count, 1)

            // Bestätigt: die Spiegelkopie einer anderen App geht nicht noch einmal hinaus und zählt
            // nicht als gesendet (ME-06).
            StubURLProtocol.install { _ in .status(202) }
            XCTAssertEqual(deliver(sink, [weightSample(80)]), .accepted(sentDeleted: false, notSent: [weight: 1]))
            XCTAssertEqual(StubURLProtocol.requests.count, 0, "alles gespiegelt: kein Paket")
        }
    }

    func testOnlyMirroredSamplesWithoutDeletionsMeansNoRequest() throws {
        try withHarness { h in
            let sink = h.sink(sendDeletions: false)
            StubURLProtocol.install { _ in .status(202) }
            _ = deliver(sink, [weightSample(80)])
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(sink, [weightSample(80)])

            XCTAssertEqual(result, .accepted(sentDeleted: false, notSent: [weight: 1]), "nichts ging hinaus (ME-06)")
            XCTAssertEqual(StubURLProtocol.requests.count, 0)
        }
    }

    func testSamplesOfOtherTypesAreNotThinnedByTheLedger() throws {
        try withHarness { h in
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: false), [stepsSample(100), stepsSample(100)])

            XCTAssertEqual((dataSection(sentBodies()[0])["records"] as? [Any])?.count, 2)
        }
    }

    // MARK: Parken

    func testTheParkingRecordIsTheJsonPackageOfThatOneSample() throws {
        try withHarness { h in
            let sample = weightSample(80)
            let data = try XCTUnwrap(h.sink(sendDeletions: false).parkingRecord(for: sample))

            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let records = try XCTUnwrap(dataSection(json)["records"] as? [[String: Any]])
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0]["id"] as? String, sample.uuid.uuidString)
            XCTAssertNil(dataSection(json)["deleted"])
        }
    }

    // MARK: - Zweitziel (Plan 09-04, D-08)

    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let secondaryHost = "https://secondary.example.test"

    /// Konfiguriert das Zweitziel im Speicher-Keychain von `withIsolatedSDK`.
    private func configureSecondary() {
        OpenWearablesHealthSdkKeychain.saveSecondary(host: secondaryHost, apiKey: "secondary-key")
    }

    /// Konfiguriert und schaltet ein. Der Schalter liegt in der Suite von `withIsolatedDefaults`.
    private func enableSecondary(_ h: Harness, types: [String] = []) {
        configureSecondary()
        h.sdk.lanesSecondaryEnabled = true
        h.sdk.lanesSecondaryTypes = types
    }

    private func secondaryOutbox(_ h: Harness) -> SecondaryOutbox {
        SecondaryOutbox(baseDirectory: h.sdk.secondaryDirectory())
    }

    private func secondaryPackages(_ h: Harness) -> [[String: Any]] {
        secondaryOutbox(h).pending().compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private func secondaryFolderExists(_ h: Harness) -> Bool {
        FileManager.default.fileExists(atPath: h.sdk.secondaryDirectory().path)
    }

    private func queueEntry(_ h: Harness, _ id: String) -> DeletionQueue.Entry? {
        h.queue.entries().first { $0.id == id }
    }

    private func recordTypes(_ body: [String: Any]) -> [String] {
        ((dataSection(body)["records"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String }
    }

    /// Kanonische Form eines Bodys, als Text (eine Abweichung steht so lesbar in der Fehlermeldung;
    /// verglichen wird Zeichen für Zeichen, also Byte für Byte). Drei Dinge hängen nicht am Code und
    /// fallen deshalb heraus:
    /// - `syncTimestamp` ist die Uhrzeit des Bauens.
    /// - `JSONSerialization` legt die Schlüsselreihenfolge eines Wörterbuchs nicht fest (sie hängt an
    ///   der Instanz), darum `.sortedKeys`.
    /// - `source.operatingSystemVersion`: Samples, die ein Test ohne Health-Store erzeugt, tragen dort
    ///   uninitialisierte Zahlen. Sie wechseln schon zwischen zwei Lieferungen desselben Samples bei
    ///   gleicher Konfiguration (beobachtet am 06.10.2026).
    private func canonical(_ data: Data) throws -> String {
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["syncTimestamp"] = nil
        return try canonical(json as Any)
    }

    private func canonical(_ value: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: withoutOSVersion(value), options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func withoutOSVersion(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            dictionary["operatingSystemVersion"] = nil
            return dictionary.mapValues { withoutOSVersion($0) }
        }
        if let array = value as? [Any] {
            return array.map { withoutOSVersion($0) }
        }
        return value
    }

    /// Schalter aus ist der Standard. Auch mit konfiguriertem Ziel entsteht dann kein Ordner, keine
    /// Datei und keine Marke in der Löschwarteschlange, und kein Aufruf geht an einen zweiten Host.
    func testWithTheSwitchOffNothingIsWrittenAndNoSecondHostIsCalled() throws {
        try withHarness(orchestration: .lanes) { h in
            configureSecondary()
            XCTAssertFalse(h.sdk.lanesSecondaryEnabled, "Standard aus")
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [stepsSample(100)], deleted: [ref("neu")])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertFalse(secondaryFolderExists(h), "kein health_secondary/")
            XCTAssertEqual(StubURLProtocol.requests.count, 1)
            XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.url?.host == "sync.example.test" })
            XCTAssertTrue(h.queue.entries().isEmpty, "die Warteschlange füllt erst der Kern")
        }
    }

    /// T-09-12: Das Paket ans Primärziel ist mit und ohne Zweitziel dasselbe. Je Stellung von
    /// `lanes.sendDeletions` drei Läufe mit gleichem Ausgangszustand: ohne Konfiguration, konfiguriert
    /// und aus, konfiguriert und an (mit Typfilter). In der Warteschlange liegen Altlasten mit
    /// unterschiedlichen Kennzeichen je Ziel.
    func testThePrimaryBodyIsByteIdenticalWithAndWithoutASecondaryTarget() throws {
        let samples: [HKSample] = [stepsSample(100), heartRateSample(61, offset: 5), sleepSample(offset: 10)]

        for sendDeletions in [false, true] {
            var bodies: [String] = []
            var headers: [[String: String]] = []

            for variant in 0..<3 {
                let label = "sendDeletions=\(sendDeletions) Variante \(variant)"
                try withHarness(orchestration: .lanes) { h in
                    try h.queue.enqueue([ref("alt")], sentAt: nil)
                    try h.queue.enqueue([ref("primaer-gesendet")], sentAt: epoch)
                    try h.queue.enqueue([ref("zweit-gesendet")], sentAt: nil, sentSecondaryAt: epoch)
                    if variant >= 1 { configureSecondary() }
                    if variant == 2 {
                        h.sdk.lanesSecondaryEnabled = true
                        h.sdk.lanesSecondaryTypes = [heartRate]
                    }
                    StubURLProtocol.install { _ in .status(202) }

                    let result = deliver(h.sink(sendDeletions: sendDeletions), samples, deleted: [ref("neu")])

                    XCTAssertEqual(result, .accepted(sentDeleted: sendDeletions), label)
                    let primary = StubURLProtocol.recorded(matching: "/sync")
                    XCTAssertEqual(primary.count, 1, label)
                    guard let sent = primary.first else { return }
                    XCTAssertEqual(sent.request.url?.host, "sync.example.test", label)
                    bodies.append(try canonical(sent.body))
                    var fields = sent.request.allHTTPHeaderFields ?? [:]
                    // Je Anfrage neu. `Content-Length` folgt der Länge des Bodys, die die
                    // uninitialisierten Versionszahlen mitbestimmen (siehe `canonical`); es muss nur zu
                    // ihm passen.
                    fields["X-Request-Id"] = nil
                    XCTAssertEqual(fields.removeValue(forKey: "Content-Length"), String(sent.body.count), label)
                    headers.append(fields)
                    XCTAssertEqual(secondaryPackages(h).count, variant == 2 ? 1 : 0, label)
                }
            }

            XCTAssertEqual(bodies.count, 3)
            guard bodies.count == 3 else { continue }
            XCTAssertEqual(bodies[0], bodies[1], "sendDeletions=\(sendDeletions): konfiguriert, aber aus")
            XCTAssertEqual(bodies[0], bodies[2], "sendDeletions=\(sendDeletions): eingeschaltet")
            XCTAssertEqual(headers[0], headers[1])
            XCTAssertEqual(headers[0], headers[2])
        }
    }

    /// Nach dem 2xx des Primärziels liegt genau eine Datei in der Outbox: dieselben Samples, dazu alle
    /// Löschungen (eigene und die fürs Zweitziel ungesendeten), auch wenn `lanes.sendDeletions` aus ist.
    /// Eingereiht wird nur, gesendet erst vom Sender.
    func testAfterAPrimary2xxOneFileHoldsTheSamePackageWithItsDeletions() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h)
            try h.queue.enqueue([ref("alt-1")], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [weightSample(80), stepsSample(100)], deleted: [ref("neu")])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            let primary = sentBodies()
            XCTAssertEqual(primary.count, 1)
            XCTAssertNil(dataSection(primary[0])["deleted"], "das Primärziel bleibt ohne Löschungen")

            let packages = secondaryPackages(h)
            XCTAssertEqual(packages.count, 1)
            guard let package = packages.first else { return }
            XCTAssertEqual(deletedIds(package), ["neu", "alt-1"])
            XCTAssertEqual(
                try canonical(dataSection(package)["records"] ?? []),
                try canonical(dataSection(primary[0])["records"] ?? []),
                "dieselben Datensätze wie beim Primärziel"
            )
            XCTAssertEqual(package["syncType"] as? String, "live")
            XCTAssertEqual(package["provider"] as? String, "apple")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "kein Aufruf ans Zweitziel beim Einreihen")
        }
    }

    /// Nach dem Einreihen tragen die Löschungen des Pakets das Kennzeichen des Zweitziels. `sentAt`
    /// gehört dem Primärziel und bleibt, wie es war.
    func testQueuedDeletionsGetTheSecondaryMarkAndKeepTheirPrimaryMark() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h)
            try h.queue.enqueue([ref("alt-1")], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: false), [stepsSample(100)], deleted: [ref("neu")])

            let neu = try XCTUnwrap(queueEntry(h, "neu"))
            let alt = try XCTUnwrap(queueEntry(h, "alt-1"))
            XCTAssertNotNil(neu.sentSecondaryAt)
            XCTAssertNotNil(alt.sentSecondaryAt)
            XCTAssertNil(neu.sentAt, "das Primärziel hat sie nicht bekommen")
            XCTAssertNil(alt.sentAt)
            XCTAssertTrue(h.queue.unsentSecondary(limit: 10).isEmpty)
            XCTAssertEqual(h.queue.unsent(limit: 10).map(\.id), ["alt-1", "neu"])
        }
    }

    /// Ein Paket, das das Primärziel abweist (Halbieren, Parken) oder nicht annimmt, erreicht das
    /// Zweitziel nie, und keine Löschung bekommt das Kennzeichen des Zweitziels.
    func testAPackageThePrimaryRejectsOrFailsNeverReachesTheSecondary() throws {
        let replies: [(String, StubURLProtocol.Reply)] = [
            ("400", .status(400)), ("413", .status(413)), ("422", .status(422)),
            ("500", .status(500)), ("503", .status(503)),
            ("offline", .failure(URLError(.notConnectedToInternet)))
        ]
        for (label, reply) in replies {
            try withHarness(orchestration: .lanes) { h in
                enableSecondary(h)
                try h.queue.enqueue([ref("alt")], sentAt: nil)
                StubURLProtocol.install { _ in reply }

                let result = deliver(h.sink(sendDeletions: false), [stepsSample(100)], deleted: [ref("neu")])

                if case .accepted? = result { XCTFail("\(label): angenommen") }
                XCTAssertTrue(secondaryOutbox(h).pending().isEmpty, label)
                XCTAssertEqual(h.queue.unsentSecondary(limit: 10).map(\.id), ["alt"], label)
                XCTAssertNil(queueEntry(h, "neu"), "\(label): nichts eingetragen")
            }
        }
    }

    /// HI-02-Zweig: Nimmt das Primärziel das Paket erst ohne Löschungen an, bekommt das Zweitziel die
    /// Löschungen trotzdem. Im Primärziel bleiben sie ungesendet.
    func testWhenThePrimaryTakesThePackageOnlyWithoutDeletionsTheSecondaryStillGetsThem() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h)
            try h.queue.enqueue([ref("alt")], sentAt: nil)
            let lock = NSLock()
            var calls = 0
            StubURLProtocol.install { _ in
                lock.lock()
                calls += 1
                let first = calls == 1
                lock.unlock()
                return first ? .status(422) : .status(202)
            }

            let result = deliver(h.sink(sendDeletions: true), [weightSample(80)], deleted: [ref("neu")])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            let packages = secondaryPackages(h)
            XCTAssertEqual(packages.count, 1)
            guard let package = packages.first else { return }
            XCTAssertEqual(deletedIds(package), ["neu", "alt"])
            XCTAssertEqual((dataSection(package)["records"] as? [Any])?.count, 1)
            let alt = try XCTUnwrap(queueEntry(h, "alt"))
            XCTAssertNil(alt.sentAt, "im Primärziel ungesendet")
            XCTAssertNotNil(alt.sentSecondaryAt)
        }
    }

    /// K4: Die Typauswahl filtert die Datensätze des Zweitpakets nach HK-Identifier. Löschungen bleiben
    /// vollständig, das Primärpaket bleibt ungefiltert.
    func testTheTypeFilterKeepsOnlyTheListedTypesButAllDeletions() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h, types: [heartRate])
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(
                h.sink(sendDeletions: false),
                [heartRateSample(60), stepsSample(100, offset: 1), sleepSample(offset: 2)],
                deleted: [ref("weg", type: steps)]
            )

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            let primary = sentBodies()[0]
            XCTAssertEqual(Set(recordTypes(primary)), [heartRate, steps])
            XCTAssertEqual((dataSection(primary)["sleep"] as? [Any])?.count, 1)

            let packages = secondaryPackages(h)
            XCTAssertEqual(packages.count, 1)
            guard let package = packages.first else { return }
            XCTAssertEqual(recordTypes(package), [heartRate])
            XCTAssertEqual((dataSection(package)["sleep"] as? [Any])?.count, 0)
            XCTAssertEqual((dataSection(package)["workouts"] as? [Any])?.count, 0)
            XCTAssertEqual(deletedIds(package), ["weg"], "Löschungen werden nicht gefiltert")
        }
    }

    /// Der Filter greift auch bei Workouts und Schlaf nach ihrem Identifier. Leer heißt alle.
    func testTheTypeFilterAppliesToWorkoutsAndSleepByTheirIdentifier() {
        let workout = HKWorkout(activityType: .running, start: epoch, end: epoch.addingTimeInterval(600))
        let sleep = sleepSample()
        let pulse = heartRateSample(60)
        let all: [HKSample] = [workout, sleep, pulse]

        XCTAssertEqual(PayloadSink.secondarySamples(all, types: [heartRate]).map(\.uuid), [pulse.uuid])
        XCTAssertEqual(
            PayloadSink.secondarySamples(all, types: ["HKWorkoutTypeIdentifier", "HKCategoryTypeIdentifierSleepAnalysis"]).map(\.uuid),
            [workout.uuid, sleep.uuid]
        )
        XCTAssertEqual(PayloadSink.secondarySamples(all, types: []).map(\.uuid), all.map(\.uuid))
    }

    /// Bleibt nach dem Filter weder ein Datensatz noch eine Löschung, wird nichts eingereiht.
    func testAPackageFilteredToNothingWithoutDeletionsQueuesNothing() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h, types: [heartRate])
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [stepsSample(100)])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertTrue(secondaryOutbox(h).pending().isEmpty)
        }
    }

    /// Das Zweitpaket trägt nur, was für das Zweitziel ungesendet ist. Die Kennzeichen des anderen
    /// Ziels bleiben, wie sie sind.
    func testEachTargetGetsItsOwnUnsentBacklogAndKeepsTheOtherMark() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h)
            try h.queue.enqueue([ref("primaer-gesendet")], sentAt: epoch)
            try h.queue.enqueue([ref("zweit-gesendet")], sentAt: nil, sentSecondaryAt: epoch)
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: true), [stepsSample(100)], deleted: [ref("neu")])

            XCTAssertEqual(deletedIds(sentBodies()[0]), ["neu", "zweit-gesendet"])
            XCTAssertEqual(secondaryPackages(h).first.flatMap(deletedIds), ["neu", "primaer-gesendet"])

            let primaer = try XCTUnwrap(queueEntry(h, "primaer-gesendet"))
            XCTAssertEqual(primaer.sentAt, epoch, "das Kennzeichen des Primärziels bleibt")
            XCTAssertNotNil(primaer.sentSecondaryAt)
            let zweit = try XCTUnwrap(queueEntry(h, "zweit-gesendet"))
            XCTAssertEqual(zweit.sentSecondaryAt, epoch, "das Kennzeichen des Zweitziels bleibt")
            XCTAssertNotNil(zweit.sentAt)
        }
    }

    /// Höchstens 500 Löschungen je Zweitpaket; die eigenen gehen immer ganz mit, ältere füllen auf.
    func testAtMostFiveHundredDeletionsGoIntoASecondaryPackage() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h)
            try h.queue.enqueue((1...600).map { ref("alt-\($0)") }, sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            _ = deliver(h.sink(sendDeletions: false), [stepsSample(100)], deleted: [ref("n1"), ref("n2"), ref("n3")])

            let ids = secondaryPackages(h).first.flatMap(deletedIds) ?? []
            XCTAssertEqual(ids.count, 500)
            XCTAssertEqual(Array(ids.prefix(4)), ["n1", "n2", "n3", "alt-1"])
            XCTAssertEqual(h.queue.unsentSecondary(limit: 1000).count, 600 - 497)
            XCTAssertEqual(h.queue.stats().unsent, 603, "für das Primärziel ändert sich nichts")
        }
    }

    /// T-09-14: Lässt sich die Datei nicht schreiben (hier liegt eine Datei, wo der Ordner `outbox/`
    /// sein müsste), endet die Lieferung trotzdem als angenommen. Der Fehler ist gezählt und als
    /// Lücke vermerkt, keine Löschung gilt fürs Zweitziel als gesendet.
    func testWhenTheSecondaryFileCannotBeWrittenTheDeliveryStillSucceedsAndTheGapIsCounted() throws {
        try withHarness(orchestration: .lanes) { h in
            enableSecondary(h)
            let base = h.sdk.secondaryDirectory()
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try Data("kein Ordner".utf8).write(to: base.appendingPathComponent("outbox"))
            try h.queue.enqueue([ref("alt")], sentAt: nil)
            StubURLProtocol.install { _ in .status(202) }

            let sink = h.sink(sendDeletions: false)
            let result = deliver(sink, [stepsSample(100)], deleted: [ref("neu")])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertEqual(sink.secondaryCounts.enqueued, 0)
            XCTAssertEqual(sink.secondaryCounts.failed, 1)
            XCTAssertEqual(secondaryOutbox(h).gapCount, 1)
            XCTAssertNotNil(secondaryOutbox(h).state().lastGapAt)
            XCTAssertEqual(h.queue.unsentSecondary(limit: 10).map(\.id), ["alt"])
            XCTAssertNil(queueEntry(h, "neu"), "die eigene Löschung schreibt danach der Kern ein")
        }
    }

    /// Recherche, Dual-Sink Punkt 2: Im Modus `upstream` ruht das Zweitziel, auch mit Schalter an.
    func testInUpstreamModeNothingIsQueuedEvenWithTheSwitchOn() throws {
        try withHarness(orchestration: .upstream) { h in
            enableSecondary(h)
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [stepsSample(100)], deleted: [ref("neu")])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertFalse(secondaryFolderExists(h))
            XCTAssertTrue(h.queue.entries().isEmpty)
        }
    }

    /// Der Schalter allein genügt nicht: ohne Host und Schlüssel ruht das Zweitziel.
    func testTheSwitchWithoutAConfiguredTargetQueuesNothing() throws {
        try withHarness(orchestration: .lanes) { h in
            h.sdk.lanesSecondaryEnabled = true
            StubURLProtocol.install { _ in .status(202) }

            let result = deliver(h.sink(sendDeletions: false), [stepsSample(100)])

            XCTAssertEqual(result, .accepted(sentDeleted: false))
            XCTAssertFalse(secondaryFolderExists(h))
        }
    }
}
