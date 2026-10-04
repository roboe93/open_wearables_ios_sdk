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
    private func withHarness(_ body: (Harness) throws -> Void) throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK { sdk, directory in
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

            _ = deliver(h.sink(sendDeletions: false), [weightSample(108.955), weightSample(108.955)])

            XCTAssertEqual((dataSection(sentBodies()[0])["records"] as? [Any])?.count, 1)
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

            // Bestätigt: die Spiegelkopie einer anderen App geht nicht noch einmal hinaus.
            StubURLProtocol.install { _ in .status(202) }
            XCTAssertEqual(deliver(sink, [weightSample(80)]), .accepted(sentDeleted: false))
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

            XCTAssertEqual(result, .accepted(sentDeleted: false))
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
}
