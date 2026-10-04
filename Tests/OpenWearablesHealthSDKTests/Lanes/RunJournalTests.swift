import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Lauf- und Wake-Journal (Plan 05-03, Befund 10 vom 04.10.2026).
///
/// Am iPhone 18 Pro stand seit dem 03.10. 19:32 kein einziger Lauf im Protokoll, und die vom
/// SDK selbst gestarteten Läufe (Observer, SDK-BGTasks) erscheinen im App-Protokoll gar
/// nicht. Das Journal macht sichtbar, ob iOS die App weckt. Es enthält nur Typnamen,
/// Zählungen, Zeitpunkte und Status, nie Gesundheitswerte, User-ID oder Token.
final class RunJournalTests: XCTestCase {

    // MARK: - Hilfen

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-journal-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Sekundengenau, weil ISO 8601 ohne Bruchteile geschrieben wird.
    private func entry(
        _ index: Int, kind: String = "run", note: String? = nil
    ) -> SyncJournalEntry {
        SyncJournalEntry(
            at: Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(index)),
            kind: kind, trigger: "app:test", status: "upToDate", records: index, note: note
        )
    }

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

    /// Setzt die Zustands-Caches nur für `body`. Tests rufen UIApplication nie an.
    private func withDeviceState(
        protected: Bool?, backgroundRefresh: String? = nil,
        on sdk: OpenWearablesHealthSDK, _ body: () -> Void
    ) {
        let previousProtected = sdk.protectedDataAvailableCache
        let previousRefresh = sdk.backgroundRefreshStatusCache
        sdk.protectedDataAvailableCache = protected
        sdk.backgroundRefreshStatusCache = backgroundRefresh
        defer {
            sdk.protectedDataAvailableCache = previousProtected
            sdk.backgroundRefreshStatusCache = previousRefresh
        }
        body()
    }

    // MARK: - Ring und Persistenz

    func testKeepsOnlyTheNewest200EntriesOldestFirst() {
        let journal = RunJournal(directory: makeDirectory())
        for index in 0..<205 { journal.record(entry(index)) }

        let entries = journal.entries()
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.first?.records, 5, "die ältesten fünf sind herausgefallen")
        XCTAssertEqual(entries.last?.records, 204)
        XCTAssertEqual(entries.map(\.at), entries.map(\.at).sorted(), "ältester zuerst")
    }

    func testCapacityIsConfigurable() {
        let journal = RunJournal(directory: makeDirectory(), capacity: 3)
        for index in 0..<5 { journal.record(entry(index)) }
        XCTAssertEqual(journal.entries().map(\.records), [2, 3, 4])
    }

    func testWritingAndReloadingWithANewInstanceReturnsTheSameEntries() {
        let directory = makeDirectory()
        let written = (0..<7).map { entry($0, note: "n\($0)") }
        let first = RunJournal(directory: directory)
        written.forEach { first.record($0) }

        let second = RunJournal(directory: directory)
        XCTAssertEqual(second.entries(), written)
    }

    func testMissingFileReadsAsEmpty() {
        XCTAssertEqual(RunJournal(directory: makeDirectory()).entries(), [])
    }

    func testAnUnknownKindDoesNotBreakLoading() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = """
        [{"at":"2026-10-04T12:00:00Z","kind":"run","status":"upToDate"},
         {"at":"2026-10-04T12:01:00Z","kind":"something-from-the-future","note":"x"},
         {"at":"2026-10-04T12:02:00Z","kind":"wake","trigger":"unlock"}]
        """
        try Data(raw.utf8).write(to: directory.appendingPathComponent("journal.json"))

        let entries = RunJournal(directory: directory).entries()
        XCTAssertEqual(entries.map(\.kind), ["run", "something-from-the-future", "wake"])
    }

    /// Ein einzelner kaputter Eintrag darf das Journal nicht leeren: der Rest bleibt lesbar.
    func testOneBrokenEntryDoesNotEmptyTheJournal() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = """
        [{"at":"2026-10-04T12:00:00Z","kind":"run"},
         {"at":"not a date","kind":"run"},
         {"kind":"run"},
         {"at":"2026-10-04T12:02:00Z","kind":"wake"}]
        """
        try Data(raw.utf8).write(to: directory.appendingPathComponent("journal.json"))

        XCTAssertEqual(RunJournal(directory: directory).entries().map(\.kind), ["run", "wake"])
    }

    func testFileUsesTheContractKeysAndISO8601WithZ() throws {
        let directory = makeDirectory()
        let journal = RunJournal(directory: directory)
        journal.record(SyncJournalEntry(
            at: Date(timeIntervalSince1970: 1_790_000_000), kind: "run",
            trigger: "observer:HKQuantityTypeIdentifierHeartRate", orchestration: "upstream",
            status: "partial:budget", records: 4, live: 3, backfill: 1, deletions: 0,
            protectedStart: true, protectedEnd: false, lowPower: false, backfillPending: true,
            leaseTakenOver: false, bgRefresh: "available", durationMs: 1234, note: "n"
        ))

        let data = try Data(contentsOf: journal.fileURL)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let object = try XCTUnwrap(array.first)

        XCTAssertEqual(Set(object.keys), [
            "at", "kind", "trigger", "orchestration", "status", "records", "live", "backfill",
            "deletions", "protectedStart", "protectedEnd", "lowPower", "backfillPending",
            "leaseTakenOver", "bgRefresh", "durationMs", "note"
        ])
        let at = try XCTUnwrap(object["at"] as? String)
        XCTAssertNotNil(
            at.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression),
            "ISO 8601 ohne Bruchteile, UTC, Z: \(at)"
        )
        XCTAssertEqual(object["records"] as? Int, 4)
        XCTAssertEqual(object["protectedEnd"] as? Bool, false)
        XCTAssertEqual(object["durationMs"] as? Int, 1234)
    }

    func testOptionalFieldsAreOmittedNotWrittenAsNull() throws {
        let journal = RunJournal(directory: makeDirectory())
        journal.record(SyncJournalEntry(at: Date(timeIntervalSince1970: 1_790_000_000), kind: "wake"))

        let data = try Data(contentsOf: journal.fileURL)
        let object = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        XCTAssertEqual(Set(object.keys), ["at", "kind"])
    }

    /// Eine Datei, die sich lesen lässt, aber kein Journal ist, wird nicht überschrieben:
    /// sie wird beiseitegelegt (Arbeitsregel "Bestehende Daten respektieren").
    func testAnUnreadableJournalIsMovedAsideNotOverwritten() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        try Data("this is not json".utf8).write(to: file)

        let journal = RunJournal(directory: directory)
        journal.record(entry(1))

        XCTAssertEqual(journal.entries().count, 1)
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("journal.unreadable") }
        XCTAssertEqual(aside.count, 1, "der alte Inhalt liegt noch da")
        guard let asideName = aside.first else { return }
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(asideName)), "this is not json"
        )
    }

    // MARK: - Anbindung im SDK

    func testJournalLivesUnderTheStateDirectoryAndFollowsIt() {
        withIsolatedSDK { sdk, stateDirectory in
            sdk.runJournal.record(entry(1))
            XCTAssertEqual(sdk.journalFileURL.path, stateDirectory
                .appendingPathComponent("health_journal/journal.json").path)
            XCTAssertEqual(sdk.journalEntries().count, 1)

            let other = makeDirectory()
            let previous = sdk.stateDirectoryOverride
            sdk.stateDirectoryOverride = other
            defer { sdk.stateDirectoryOverride = previous }

            XCTAssertEqual(sdk.journalEntries().count, 0, "der Cache hängt am aktuellen Verzeichnis")
            XCTAssertTrue(sdk.journalFileURL.path.hasPrefix(other.path))
        }
    }

    func testJournalEntriesLimitReturnsTheNewestOldestFirst() {
        withIsolatedSDK { sdk, _ in
            for index in 0..<10 { sdk.runJournal.record(entry(index)) }
            XCTAssertEqual(sdk.journalEntries(limit: 3).map(\.records), [7, 8, 9])
            XCTAssertEqual(sdk.journalEntries().count, 10)
            XCTAssertEqual(sdk.journalEntries(limit: 0), [])
        }
    }

    // MARK: - run-Einträge

    func testASyncRunWritesExactlyOneRunEntryWithTheContractFields() {
        withIsolatedSDK { sdk, _ in
            withDeviceState(protected: true, backgroundRefresh: "available", on: sdk) {
                withTrackedTypes([], on: sdk) {
                    var result: SyncOutcome?
                    sdk.sync(trigger: .app("journal-test")) { result = $0 }
                    XCTAssertTrue(waitUntil { result != nil })
                    spin(0.1)

                    let runs = sdk.journalEntries().filter { $0.kind == "run" }
                    XCTAssertEqual(runs.count, 1)
                    let run = runs.first
                    XCTAssertEqual(run?.trigger, "app:journal-test")
                    XCTAssertEqual(run?.orchestration, "upstream")
                    XCTAssertEqual(run?.status, "upToDate")
                    XCTAssertEqual(run?.records, 0)
                    XCTAssertEqual(run?.live, 0)
                    XCTAssertEqual(run?.backfill, 0)
                    XCTAssertEqual(run?.protectedStart, true)
                    XCTAssertEqual(run?.protectedEnd, true)
                    XCTAssertEqual(run?.bgRefresh, "available")
                    XCTAssertEqual(run?.backfillPending, false)
                    XCTAssertEqual(run?.leaseTakenOver, false)
                    XCTAssertNotNil(run?.durationMs)
                    XCTAssertNotNil(run?.lowPower)
                }
            }
        }
    }

    func testASkippedRunIsJournaledToo() {
        withIsolatedSDK { sdk, _ in
            guard let holder = sdk.beginSyncRun() else { return XCTFail("slot") }
            defer { sdk.finishSync(generation: holder) }

            withDeviceState(protected: false, on: sdk) {
                var result: SyncOutcome?
                sdk.collectAllData(
                    fullExport: false, isBackground: false,
                    trigger: .observer("HKQuantityTypeIdentifierBodyMass"), deadline: nil
                ) { result = $0 }
                XCTAssertTrue(waitUntil { result != nil })

                let runs = sdk.journalEntries().filter { $0.kind == "run" }
                XCTAssertEqual(runs.count, 1)
                XCTAssertEqual(runs.first?.status, "skippedBusy")
                XCTAssertEqual(runs.first?.trigger, "observer:HKQuantityTypeIdentifierBodyMass")
                XCTAssertEqual(runs.first?.protectedStart, false)
                XCTAssertEqual(runs.first?.protectedEnd, false)
            }
        }
    }

    /// Die Sperre kann zwischen Beginn und Ende eines Laufs fallen: der Eintrag hält beide
    /// Werte getrennt fest, nicht nur den letzten. Gemessen werden soll ja gerade, ob ein
    /// Lauf, der entsperrt begann, gesperrt endete.
    func testRunEntryKeepsTheLockedStateAtStartAndAtEndSeparately() {
        withIsolatedSDK { sdk, _ in
            withDeviceState(protected: false, on: sdk) {
                let now = Date()
                let outcome = SyncOutcome(
                    status: .deferredLocked, orchestration: .upstream,
                    trigger: .unlock, started: now, finished: now
                )
                var delivered = false
                // Beim Start war das iPhone entsperrt (true), am Ende ist es gesperrt (Cache false).
                sdk.deliverRun(outcome, protectedStart: true) { _ in delivered = true }
                XCTAssertTrue(waitUntil { delivered })

                let run = sdk.journalEntries().first { $0.kind == "run" }
                XCTAssertEqual(run?.status, "deferredLocked")
                XCTAssertEqual(run?.protectedStart, true)
                XCTAssertEqual(run?.protectedEnd, false)
            }
        }
    }

    // MARK: - wake-Einträge

    func testWakeEntryCarriesTheDeviceContext() {
        withIsolatedSDK { sdk, _ in
            withDeviceState(protected: false, backgroundRefresh: "denied", on: sdk) {
                sdk.journalWake(trigger: SyncTrigger.sdkRefresh.journalValue, note: "x")

                let wakes = sdk.journalEntries().filter { $0.kind == "wake" }
                XCTAssertEqual(wakes.count, 1)
                XCTAssertEqual(wakes.first?.trigger, "sdkRefresh")
                XCTAssertEqual(wakes.first?.protectedStart, false)
                XCTAssertEqual(wakes.first?.bgRefresh, "denied")
                XCTAssertEqual(wakes.first?.note, "x")
                XCTAssertNotNil(wakes.first?.lowPower)
            }
        }
    }

    /// Der Observer-Weckruf, den der Erst-Export verwirft, ist genau die Spur, die Befund 10
    /// braucht: ohne Eintrag sähe man weder den Weckruf noch den Grund für das Verwerfen.
    func testObserverDroppedDuringInitialSyncWritesAWakeEntry() {
        withIsolatedSDK { sdk, _ in
            sdk.isInitialSyncInProgress = true
            defer { sdk.isInitialSyncInProgress = false }

            sdk.triggerCombinedSync(typeIdentifier: "HKQuantityTypeIdentifierHeartRate")

            let wakes = sdk.journalEntries().filter { $0.kind == "wake" }
            XCTAssertEqual(wakes.count, 1)
            XCTAssertEqual(wakes.first?.trigger, "observer:HKQuantityTypeIdentifierHeartRate")
            XCTAssertEqual(wakes.first?.note, "skipped: initial sync in progress")
        }
    }

    // MARK: - adoption-Eintrag

    func testAdoptionWritesAnEntryWithTheAnchorCount() {
        withIsolatedDefaults { defaults in
            withIsolatedSDK(userId: LegacyDeviceState.userId) { sdk, _ in
                LegacyDeviceState.install(into: defaults)

                XCTAssertTrue(sdk.adoptLegacyStateIfNeeded())

                let adoptions = sdk.journalEntries().filter { $0.kind == "adoption" }
                XCTAssertEqual(adoptions.count, 1)
                XCTAssertEqual(adoptions.first?.note, "anchors=\(LegacyDeviceState.anchors.count)")

                XCTAssertFalse(sdk.adoptLegacyStateIfNeeded(), "der zweite Aufruf adoptiert nichts")
                XCTAssertEqual(
                    sdk.journalEntries().filter { $0.kind == "adoption" }.count, 1,
                    "und schreibt auch keinen zweiten Eintrag"
                )
            }
        }
    }

    // MARK: - delivery-Eintrag

    func testDeliveryTallySummarisesOkAndFailedInOneLine() {
        let tally = DeliveryTally()
        tally.record(shortName: "HeartRate", success: true)
        tally.record(shortName: "StepCount", success: false)
        tally.record(shortName: "BodyMass", success: true)
        tally.record(shortName: "Workout", success: false)

        XCTAssertEqual(tally.note, "ok=2 failed=StepCount,Workout")
    }

    func testDeliveryTallyWithoutFailuresSaysNone() {
        let tally = DeliveryTally()
        tally.record(shortName: "HeartRate", success: true)
        XCTAssertEqual(tally.note, "ok=1 failed=none")
    }

    func testDeliveryTallyCapsALongFailureList() {
        let tally = DeliveryTally()
        for index in 0..<20 { tally.record(shortName: String(format: "T%02d", index), success: false) }

        XCTAssertEqual(
            tally.note,
            "ok=0 failed=T00,T01,T02,T03,T04,T05,T06,T07,T08,T09,T10,T11,+8"
        )
    }

    // MARK: - Datenschutz

    /// Kein Eintrag, den das SDK selbst schreibt, enthält Zugangsdaten oder die User-ID.
    func testNoEntryContainsTheUserIdOrAToken() throws {
        try withIsolatedSDKReturning(userId: "secret-user-id", accessToken: "secret-access-token") { sdk in
            withTrackedTypes([], on: sdk) {
                var result: SyncOutcome?
                sdk.sync(trigger: .app("privacy")) { result = $0 }
                XCTAssertTrue(waitUntil { result != nil })
                sdk.journalWake(trigger: "unlock", note: "pendingSync=false")
                sdk.runJournal.record(SyncJournalEntry(
                    at: Date(), kind: "adoption", note: "anchors=40"
                ))
            }
            let raw = (try? String(contentsOf: sdk.journalFileURL)) ?? ""
            XCTAssertFalse(raw.isEmpty)
            XCTAssertFalse(raw.contains("secret-user-id"))
            XCTAssertFalse(raw.contains("secret-access-token"))
        }
    }

    private func withIsolatedSDKReturning(
        userId: String, accessToken: String, _ body: (OpenWearablesHealthSDK) throws -> Void
    ) throws {
        var thrown: Error?
        withIsolatedSDK(userId: userId, accessToken: accessToken) { sdk, _ in
            do { try body(sdk) } catch { thrown = error }
        }
        if let thrown = thrown { throw thrown }
    }
}
