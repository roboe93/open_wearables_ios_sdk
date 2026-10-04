import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Übernahme offener Upstream-Zustände beim Wechsel nach lanes (Plan 05-08, T-05-30).
///
/// Ein offener Export oder eine offene inkrementelle Sitzung des Original-Ablaufs wird nie
/// gelöscht und nie abgebrochen: der bestätigte Fortschritt geht in den Nachholplan und in die
/// Anchors, die Datei `state.json` wird umbenannt. Kein Anchor-Schlüssel verschwindet.
final class OpenStateAdoptionTests: XCTestCase {

    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let steps = "HKQuantityTypeIdentifierStepCount"
    private let bodyMass = "HKQuantityTypeIdentifierBodyMass"

    /// Ganze Sekunden: der Plan hält Millisekunden, so bleibt der Vergleich exakt.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var olderThanHeartRate: Date { now.addingTimeInterval(-3 * 86_400) }
    private var olderThanSteps: Date { now.addingTimeInterval(-5 * 86_400) }

    // MARK: - Aufbau

    private func state(
        _ sdk: OpenWearablesHealthSDK, fullExport: Bool, userKey: String? = nil,
        progress: [TypeSyncProgress] = [], completed: Set<String> = []
    ) -> SyncState {
        var byType: [String: TypeSyncProgress] = [:]
        for item in progress { byType[item.typeIdentifier] = item }
        return SyncState(
            userKey: userKey ?? sdk.userKey(), fullExport: fullExport, createdAt: now,
            typeProgress: byType, totalSentCount: 10, completedTypes: completed,
            currentTypeIndex: 0, sessionId: "session-1"
        )
    }

    private func open(_ typeId: String, olderThan: Date? = nil, anchor: Data? = nil) -> TypeSyncProgress {
        TypeSyncProgress(
            typeIdentifier: typeId, sentCount: 5, isComplete: false,
            pendingAnchorData: anchor, pendingOlderThan: olderThan
        )
    }

    private func archived(_ value: Int) -> Data {
        // swiftlint:disable:next force_try
        try! NSKeyedArchiver.archivedData(withRootObject: HKQueryAnchor(fromValue: value), requiringSecureCoding: true)
    }

    private struct Harness {
        let sdk: OpenWearablesHealthSDK
        let reader: FakeReader
        let cursors: DefaultsCursorStore
        let backfill: InMemoryBackfillStore
    }

    private func withHarness(_ body: (Harness) throws -> Void) rethrows {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                try body(Harness(
                    sdk: sdk, reader: FakeReader(), cursors: sdk.makeCursorStore(), backfill: InMemoryBackfillStore()
                ))
            }
        }
    }

    private func adopt(
        _ h: Harness, typeIds: [String]? = nil, now: Date? = nil
    ) -> UpstreamAdoption {
        var result: UpstreamAdoption?
        h.sdk.adoptOpenUpstreamStateIfNeeded(
            reader: h.reader, cursors: h.cursors, backfill: h.backfill,
            typeIds: typeIds ?? [heartRate, steps, bodyMass], now: now ?? self.now
        ) { result = $0 }
        XCTAssertNotNil(result, "die Übernahme meldet sich zurück")
        return result ?? UpstreamAdoption()
    }

    private func adoptedFiles(_ sdk: OpenWearablesHealthSDK) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sdk.syncStateDir().path)) ?? []
        return names.filter { $0.hasPrefix("state.json.adopted-") }.sorted()
    }

    private func anchorKeys(_ defaults: UserDefaults) -> [String: Data] {
        var found: [String: Data] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("anchor.") {
            if let data = value as? Data { found[key] = data }
        }
        return found
    }

    // MARK: - Offener Export

    func testAnOpenExportBecomesOneBackfillEntryPerUnfinishedType() {
        withHarness { h in
            let sdk = h.sdk
            // Zustand wie nach einem unterbrochenen Neu-Export: Gewicht fertig (mit Anchor), die
            // beiden dichten Typen unterwegs, ohne Anchor.
            let weightAnchor = FakeReader.token(900)
            h.cursors.commit(weightAnchor, for: bodyMass)
            let before = anchorKeys(sdk.defaults)
            sdk.saveSyncState(state(
                sdk, fullExport: true,
                progress: [open(heartRate, olderThan: olderThanHeartRate), open(steps, olderThan: olderThanSteps)],
                completed: [bodyMass]
            ))
            h.reader.insert(heartRate, id: "h1", endDate: now.addingTimeInterval(-60))
            h.reader.insert(steps, id: "s1", endDate: now.addingTimeInterval(-60))

            let result = adopt(h)

            XCTAssertTrue(result.adopted)
            XCTAssertTrue(result.fullExport)
            XCTAssertEqual(Set(result.plannedTypes), [heartRate, steps])
            let entries = h.backfill.plan.entries
            XCTAssertEqual(Set(entries.keys), [heartRate, steps], "das fertige Gewicht bekommt keinen Eintrag")
            XCTAssertEqual(entries[heartRate]?.covered, LaneTime.ceil(olderThanHeartRate))
            XCTAssertEqual(entries[steps]?.covered, LaneTime.ceil(olderThanSteps))
            XCTAssertEqual(entries[heartRate]?.state, .pending)
            XCTAssertEqual(entries[heartRate]?.origin, "adoptedExport")

            // state.json ist weg, aber nicht gelöscht: es liegt umbenannt daneben.
            XCTAssertFalse(FileManager.default.fileExists(atPath: sdk.syncStateFilePath().path))
            XCTAssertEqual(adoptedFiles(sdk).count, 1)
            XCTAssertNotNil(result.renamedTo)

            // Kein Anchor ist entfernt oder verändert, die beiden fehlenden stehen jetzt.
            let after = anchorKeys(sdk.defaults)
            for (key, data) in before { XCTAssertEqual(after[key], data, "\(key) bleibt unverändert") }
            XCTAssertEqual(h.cursors.anchor(for: bodyMass), weightAnchor)
            XCTAssertEqual(h.cursors.anchor(for: heartRate), FakeReader.token(h.reader.anchorValue(for: heartRate)))
            XCTAssertEqual(h.cursors.anchor(for: steps), FakeReader.token(h.reader.anchorValue(for: steps)))
            XCTAssertEqual(Set(result.anchorsForNow), [heartRate, steps])
        }
    }

    /// Ein Typ, den der alte Export noch gar nicht begonnen hatte, geht auch ins Nachholen:
    /// ohne ihn wäre sein Fenster nie geholt worden.
    func testATypeTheExportNeverStartedIsAdoptedWithTheWholeWindow() {
        withHarness { h in
            h.sdk.saveSyncState(state(h.sdk, fullExport: true, progress: [open(heartRate, olderThan: olderThanHeartRate)]))

            _ = adopt(h)

            let entry = h.backfill.plan.entries[bodyMass]
            XCTAssertNotNil(entry)
            XCTAssertEqual(entry?.covered, LaneTime.ceil(now), "ohne Cursor beginnt das Nachholen bei jetzt")
            XCTAssertEqual(entry?.origin, "adoptedExport")
        }
    }

    /// Ein vorhandener Anchor eines unfertigen Typs bleibt: er ist der Stand der Live-Spur.
    func testAnExistingAnchorOfAnUnfinishedTypeIsKept() {
        withHarness { h in
            let existing = FakeReader.token(123)
            h.cursors.commit(existing, for: heartRate)
            h.reader.insert(heartRate, id: "h1", endDate: now)
            h.sdk.saveSyncState(state(h.sdk, fullExport: true, progress: [open(heartRate, olderThan: olderThanHeartRate)]))

            let result = adopt(h, typeIds: [heartRate])

            XCTAssertEqual(h.cursors.anchor(for: heartRate), existing)
            XCTAssertFalse(result.anchorsForNow.contains(heartRate))
            XCTAssertEqual(h.backfill.plan.entries[heartRate]?.covered, LaneTime.ceil(olderThanHeartRate))
        }
    }

    /// Eine zweite Übernahme (etwa nach einem Abbruch) überschreibt keinen Fortschritt.
    func testAdoptionNeverOverwritesAnEntryThatAlreadyMadeProgress() {
        withHarness { h in
            var plan = BackfillPlan.empty()
            plan.start(typeId: heartRate, now: now, daysBack: 14, origin: "bootstrap")
            plan.advance(typeId: heartRate, to: now.addingTimeInterval(-9 * 86_400), boundaryIds: ["x"])
            h.backfill.plan = plan
            let progressed = plan.entries[heartRate]
            h.sdk.saveSyncState(state(h.sdk, fullExport: true, progress: [open(heartRate, olderThan: olderThanHeartRate)]))

            _ = adopt(h, typeIds: [heartRate])

            XCTAssertEqual(h.backfill.plan.entries[heartRate], progressed)
        }
    }

    // MARK: - Offene inkrementelle Sitzung

    func testAnOpenIncrementalSessionWritesItsConfirmedAnchorAndRenamesTheFile() {
        withHarness { h in
            let sdk = h.sdk
            let confirmed = archived(4711)
            h.cursors.commit(archived(100), for: heartRate)
            sdk.saveSyncState(state(sdk, fullExport: false, progress: [open(heartRate, anchor: confirmed)]))

            let result = adopt(h)

            XCTAssertTrue(result.adopted)
            XCTAssertFalse(result.fullExport)
            XCTAssertEqual(result.anchorsFromSession, [heartRate])
            XCTAssertEqual(h.cursors.anchor(for: heartRate), confirmed, "der bestätigte Fortschritt gilt")
            XCTAssertTrue(h.backfill.plan.entries.isEmpty, "eine inkrementelle Sitzung braucht kein Nachholen")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sdk.syncStateFilePath().path))
            XCTAssertEqual(adoptedFiles(sdk).count, 1)
        }
    }

    /// Wie im Original: ein Anchor, der sich nicht entpacken lässt, wird nicht übernommen.
    func testAnAnchorThatCannotBeUnarchivedIsNotWritten() {
        withHarness { h in
            let kept = archived(100)
            h.cursors.commit(kept, for: heartRate)
            h.sdk.saveSyncState(state(h.sdk, fullExport: false, progress: [open(heartRate, anchor: Data("müll".utf8))]))

            let result = adopt(h)

            XCTAssertEqual(h.cursors.anchor(for: heartRate), kept)
            XCTAssertTrue(result.anchorsFromSession.isEmpty)
            XCTAssertEqual(adoptedFiles(h.sdk).count, 1, "die Datei wird trotzdem beiseitegelegt")
        }
    }

    // MARK: - Nichts zu übernehmen

    func testWithoutAStateFileNothingHappens() {
        withHarness { h in
            let result = adopt(h)

            XCTAssertFalse(result.adopted)
            XCTAssertTrue(adoptedFiles(h.sdk).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.sdk.syncStateDir().path), "kein Verzeichnis angelegt")
            XCTAssertTrue(h.sdk.journalEntries().filter { $0.kind == "adoption" }.isEmpty)
            XCTAssertEqual(h.reader.totalCalls, 0, "keine Abfrage")
        }
    }

    /// Die Sitzung eines anderen Nutzers gehört nicht diesem Lauf: nicht anfassen, nicht umbenennen.
    func testAnotherUsersSessionIsLeftUntouched() {
        withHarness { h in
            h.sdk.saveSyncState(state(h.sdk, fullExport: true, userKey: "user.somebody-else",
                                      progress: [open(heartRate, olderThan: olderThanHeartRate)]))
            let bytes = try? Data(contentsOf: h.sdk.syncStateFilePath())

            let result = adopt(h)

            XCTAssertFalse(result.adopted)
            XCTAssertEqual(try? Data(contentsOf: h.sdk.syncStateFilePath()), bytes)
            XCTAssertTrue(adoptedFiles(h.sdk).isEmpty)
            XCTAssertTrue(h.backfill.plan.entries.isEmpty)
        }
    }

    /// Eine Datei, die sich nicht lesen lässt, ist keine, die wir übernehmen: sie bleibt liegen.
    func testAnUnreadableStateFileIsLeftWhereItIs() throws {
        try withHarness { h in
            try FileManager.default.createDirectory(at: h.sdk.syncStateDir(), withIntermediateDirectories: true)
            try Data("kein json".utf8).write(to: h.sdk.syncStateFilePath())

            let result = adopt(h)

            XCTAssertFalse(result.adopted)
            XCTAssertTrue(FileManager.default.fileExists(atPath: h.sdk.syncStateFilePath().path))
            XCTAssertTrue(adoptedFiles(h.sdk).isEmpty)
        }
    }

    // MARK: - Fehlschläge

    /// Gesperrt: der Anchor für jetzt ist nicht zu bekommen. Dann bleibt `state.json` liegen, der
    /// Plan steht trotzdem, und die nächste Übernahme macht fertig, ohne etwas zu doppeln.
    func testAdoptionWaitsForTheUnlockWhenTheAnchorForNowCannotBeTaken() {
        withHarness { h in
            h.reader.lockedTypes = [heartRate]
            h.reader.insert(steps, id: "s1", endDate: now)
            h.sdk.saveSyncState(state(
                h.sdk, fullExport: true,
                progress: [open(heartRate, olderThan: olderThanHeartRate), open(steps, olderThan: olderThanSteps)]
            ))

            let first = adopt(h, typeIds: [heartRate, steps])

            XCTAssertTrue(first.adopted)
            XCTAssertEqual(first.anchorFailed, [heartRate])
            XCTAssertNil(first.renamedTo, "noch nicht fertig: die Datei bleibt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: h.sdk.syncStateFilePath().path))
            XCTAssertEqual(Set(h.backfill.plan.entries.keys), [heartRate, steps], "der Plan steht schon")
            XCTAssertNotNil(h.cursors.anchor(for: steps), "was ging, ist festgeschrieben")
            XCTAssertNil(h.cursors.anchor(for: heartRate))
            let planBefore = h.backfill.plan

            h.reader.lockedTypes = []
            let second = adopt(h, typeIds: [heartRate, steps])

            XCTAssertNotNil(second.renamedTo)
            XCTAssertNotNil(h.cursors.anchor(for: heartRate))
            XCTAssertEqual(h.backfill.plan, planBefore, "die zweite Übernahme ändert den Plan nicht")
            XCTAssertEqual(adoptedFiles(h.sdk).count, 1)
        }
    }

    /// Scheitert das Speichern des Plans, bleibt alles, wie es war: kein Anchor, keine Umbenennung.
    func testAFailingPlanSaveKeepsTheSessionAndWritesNoAnchor() {
        withHarness { h in
            h.backfill.failSaves = true
            h.reader.insert(heartRate, id: "h1", endDate: now)
            h.sdk.saveSyncState(state(h.sdk, fullExport: true, progress: [open(heartRate, olderThan: olderThanHeartRate)]))

            let result = adopt(h, typeIds: [heartRate])

            XCTAssertNil(result.renamedTo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: h.sdk.syncStateFilePath().path))
            XCTAssertNil(h.cursors.anchor(for: heartRate), "ein Anchor ohne Plan ließe die Historie ungeholt")
            XCTAssertEqual(h.reader.anchorCalls.count, 0)
        }
    }

    // MARK: - Umbenennen statt löschen

    func testAnEarlierAdoptedFileIsNeverOverwritten() throws {
        try withHarness { h in
            let name = OpenWearablesHealthSDK.adoptedStateFileName(now: now)
            try FileManager.default.createDirectory(at: h.sdk.syncStateDir(), withIntermediateDirectories: true)
            let earlier = h.sdk.syncStateDir().appendingPathComponent(name)
            try Data("älterer Stand".utf8).write(to: earlier)
            h.sdk.saveSyncState(state(h.sdk, fullExport: false, progress: [open(heartRate, anchor: archived(1))]))

            let result = adopt(h)

            XCTAssertNotNil(result.renamedTo)
            XCTAssertEqual(try Data(contentsOf: earlier), Data("älterer Stand".utf8), "der ältere Stand bleibt")
            XCTAssertEqual(adoptedFiles(h.sdk).count, 2)
        }
    }

    func testTheAdoptedFileKeepsTheContentOfTheSession() throws {
        try withHarness { h in
            h.sdk.saveSyncState(state(h.sdk, fullExport: true, progress: [open(heartRate, olderThan: olderThanHeartRate)]))
            let original = try Data(contentsOf: h.sdk.syncStateFilePath())

            _ = adopt(h)

            let kept = try Data(contentsOf: h.sdk.syncStateDir().appendingPathComponent(adoptedFiles(h.sdk)[0]))
            XCTAssertEqual(kept, original, "Byte für Byte erhalten")
        }
    }

    func testTheNameOfTheAdoptedFileIsTheDocumentedOne() {
        // 2026-09-14 08:15:30 UTC
        let date = Date(timeIntervalSince1970: 1_789_373_730)
        XCTAssertEqual(OpenWearablesHealthSDK.adoptedStateFileName(now: date), "state.json.adopted-20260914-081530")
    }

    // MARK: - Journal

    func testAdoptionWritesOneJournalEntryWithoutValues() {
        withHarness { h in
            h.reader.insert(heartRate, id: "h1", endDate: now)
            h.sdk.saveSyncState(state(h.sdk, fullExport: true, progress: [open(heartRate, olderThan: olderThanHeartRate)]))

            _ = adopt(h, typeIds: [heartRate])

            let entries = h.sdk.journalEntries().filter { $0.kind == "adoption" }
            XCTAssertEqual(entries.count, 1)
            let note = entries.first?.note ?? ""
            XCTAssertTrue(note.contains("upstream"), note)
            XCTAssertTrue(note.contains("fullExport=true"), note)
            XCTAssertFalse(note.contains(h.sdk.userKey()), "keine User-ID im Journal")
            XCTAssertFalse(note.contains("session-1"), "keine Sitzungskennung im Journal")
        }
    }
}
