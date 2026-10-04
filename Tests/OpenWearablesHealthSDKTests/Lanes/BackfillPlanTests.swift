import XCTest
@testable import OpenWearablesHealthSDK

/// Der Nachholplan (Plan 05-06, Task 1): reiner Zustand, ohne HealthKit prüfbar.
final class BackfillPlanTests: XCTestCase {

    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let bodyMass = "HKQuantityTypeIdentifierBodyMass"
    private let sleep = "HKCategoryTypeIdentifierSleepAnalysis"

    /// Ein fester, ganzzahliger Zeitpunkt (2026-10-04 08:00:00 UTC).
    private let t0 = Date(timeIntervalSince1970: 1_791_100_800)

    // MARK: start

    func testStartSetsWindowCoveredAndPendingState() {
        var plan = BackfillPlan.empty()

        let started = plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")

        XCTAssertTrue(started)
        let entry = plan.entries[heartRate]
        XCTAssertEqual(entry?.floor, t0.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(entry?.covered, t0.addingTimeInterval(BackfillPlan.openEnd), "nach oben offen (ME-07)")
        XCTAssertEqual(entry?.startedAt, t0)
        XCTAssertEqual(entry?.state, .pending)
        XCTAssertEqual(entry?.origin, "bootstrap")
        XCTAssertEqual(entry?.boundaryIds, [])
        XCTAssertTrue(plan.hasPending)
    }

    func testStartOnAnOpenTypeKeepsCoveredInsteadOfRestarting() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        plan.advance(typeId: heartRate, to: t0.addingTimeInterval(-3_600), boundaryIds: ["a"])
        let before = plan.entries[heartRate]

        let started = plan.start(typeId: heartRate, now: t0.addingTimeInterval(7_200), daysBack: 14, origin: "bootstrap")

        XCTAssertFalse(started, "ein offener Typ beginnt nicht neu")
        XCTAssertEqual(plan.entries[heartRate], before)
    }

    func testStartOnAFinishedTypeBeginsAnew() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        plan.markDone(typeId: heartRate)
        let later = t0.addingTimeInterval(86_400)

        let started = plan.start(typeId: heartRate, now: later, daysBack: 14, origin: "reload")

        XCTAssertTrue(started)
        XCTAssertEqual(plan.entries[heartRate]?.state, .pending)
        XCTAssertEqual(plan.entries[heartRate]?.covered, later.addingTimeInterval(BackfillPlan.openEnd))
        XCTAssertEqual(plan.entries[heartRate]?.origin, "reload")
    }

    /// Review ME-07: Das Fenster des Nachholens endet nicht bei "jetzt". Ein Sample, das vor dem
    /// Bootstrap eingetragen wurde und in der Zukunft endet (eine Mahlzeit, die YAZIO für den Abend
    /// vorträgt, eine vorgehende Uhr), läge sonst weder hinter dem Anchor noch im Fenster.
    func testStartLeavesTheUpperBoundOpenForSamplesThatEndInTheFuture() {
        var plan = BackfillPlan.empty()

        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")

        let covered = plan.entries[heartRate]?.covered ?? .distantPast
        XCTAssertGreaterThanOrEqual(covered, t0.addingTimeInterval(365 * 86_400))
        XCTAssertEqual(covered, LaneTime.ceil(t0.addingTimeInterval(BackfillPlan.openEnd)))
    }

    // MARK: advance

    func testAdvanceMovesCoveredBackwardAndRecordsTheBoundary() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        let older = t0.addingTimeInterval(-600)

        plan.advance(typeId: heartRate, to: older, boundaryIds: ["x", "y"])

        XCTAssertEqual(plan.entries[heartRate]?.covered, older)
        XCTAssertEqual(plan.entries[heartRate]?.boundaryIds, ["x", "y"])
    }

    func testAdvanceNeverMovesForward() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        plan.advance(typeId: heartRate, to: t0.addingTimeInterval(-600), boundaryIds: ["x"])
        let before = plan.entries[heartRate]

        plan.advance(typeId: heartRate, to: t0.addingTimeInterval(-60), boundaryIds: ["z"])

        XCTAssertEqual(plan.entries[heartRate], before, "ein Schritt nach vorn ändert nichts, auch nicht die Grenzkennungen")
    }

    func testAdvanceNeverGoesBelowTheFloor() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 1, origin: "bootstrap")
        let floor = t0.addingTimeInterval(-86_400)

        plan.advance(typeId: heartRate, to: floor.addingTimeInterval(-500), boundaryIds: [])

        XCTAssertEqual(plan.entries[heartRate]?.covered, floor)
    }

    func testAdvanceToTheSameInstantMergesBoundaryIds() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        let tie = t0.addingTimeInterval(-600)
        plan.advance(typeId: heartRate, to: tie, boundaryIds: ["a", "b"])

        plan.advance(typeId: heartRate, to: tie, boundaryIds: ["c"])

        XCTAssertEqual(Set(plan.entries[heartRate]?.boundaryIds ?? []), ["a", "b", "c"],
                       "bei gleichem Zeitpunkt gelten alle bisher gelieferten Kennungen weiter")
    }

    func testAdvanceOnAnUnknownTypeDoesNothing() {
        var plan = BackfillPlan.empty()
        plan.advance(typeId: heartRate, to: t0, boundaryIds: ["a"])
        XCTAssertTrue(plan.entries.isEmpty)
    }

    func testAdvanceRoundsUpToTheMillisecondSoNoTieMemberIsLost() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        // Sub-Millisekunden-Zeitstempel, wie HealthKit sie liefert.
        let oldest = t0.addingTimeInterval(-600.0004)

        plan.advance(typeId: heartRate, to: oldest, boundaryIds: ["a"])

        let covered = plan.entries[heartRate]?.covered
        XCTAssertNotNil(covered)
        XCTAssertGreaterThanOrEqual(covered ?? .distantPast, oldest,
                                    "covered liegt nie unter dem ältesten gelieferten Sample: der inklusive Rand würde ein gleichzeitiges Sample verlieren")
        XCTAssertLessThan((covered ?? .distantFuture).timeIntervalSince(oldest), 0.001)
    }

    // MARK: done / pending

    func testMarkDoneEndsPendingAndClearsTheBoundary() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        plan.advance(typeId: heartRate, to: t0.addingTimeInterval(-60), boundaryIds: ["a"])

        plan.markDone(typeId: heartRate)

        XCTAssertEqual(plan.entries[heartRate]?.state, .done)
        XCTAssertEqual(plan.entries[heartRate]?.boundaryIds, [])
        XCTAssertFalse(plan.hasPending)
    }

    func testPendingTypeIdsPutStageATypesFirst() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        plan.start(typeId: "HKQuantityTypeIdentifierStepCount", now: t0, daysBack: 14, origin: "bootstrap")
        plan.start(typeId: bodyMass, now: t0, daysBack: 14, origin: "bootstrap")
        plan.start(typeId: sleep, now: t0, daysBack: 14, origin: "bootstrap")
        plan.markDone(typeId: "HKQuantityTypeIdentifierStepCount")

        let ids = plan.pendingTypeIds(LaneOrdering())

        XCTAssertEqual(ids, [sleep, bodyMass, heartRate], "Schlaf vor Gewicht vor dem dichten Typ, der fertige fehlt")
    }

    // MARK: Übernahme eines offenen Exports

    func testAdoptOpenExportMakesEveryUnfinishedTypePending() {
        var plan = BackfillPlan.empty()
        let floor = t0.addingTimeInterval(-14 * 86_400)
        let cursor = t0.addingTimeInterval(-5 * 86_400)

        plan.adoptOpenExport(
            completedTypes: [bodyMass],
            olderThanCursors: [heartRate: cursor, bodyMass: t0.addingTimeInterval(-1_000)],
            floor: floor,
            now: t0,
            typeIds: [heartRate, bodyMass, sleep]
        )

        XCTAssertEqual(plan.entries[heartRate]?.covered, BackfillPlan.openUpperBound(t0), "der Cursor zählt nicht mehr (ME-08)")
        XCTAssertGreaterThan(cursor, floor)
        XCTAssertEqual(plan.entries[heartRate]?.floor, floor)
        XCTAssertEqual(plan.entries[heartRate]?.origin, "adoptedExport")
        XCTAssertEqual(plan.entries[heartRate]?.state, .pending)
        XCTAssertEqual(plan.entries[sleep]?.covered, BackfillPlan.openUpperBound(t0), "ohne Cursor ebenso")
        XCTAssertNil(plan.entries[bodyMass], "ein fertiger Typ bekommt keinen Eintrag, auch wenn ein Cursor übrig ist")
    }

    func testAdoptOpenExportAlsoCoversTypesThatOnlyHaveACursor() {
        var plan = BackfillPlan.empty()
        let cursor = t0.addingTimeInterval(-3_600)

        plan.adoptOpenExport(completedTypes: [], olderThanCursors: [heartRate: cursor], floor: t0.addingTimeInterval(-86_400), now: t0)

        XCTAssertNotNil(plan.entries[heartRate])
        XCTAssertEqual(plan.entries[heartRate]?.covered, BackfillPlan.openUpperBound(t0))
    }

    /// Review ME-08: Der Export des Originals liest neueste zuerst ab seiner ersten Abfrage. Was
    /// danach mit einem Ende nach dem Cursor eingetragen wurde, holte er nie. Die Übernahme ignoriert
    /// den Cursor deshalb: der Bereich (Cursor, Exportbeginn] geht idempotent doppelt raus, dafür
    /// fehlt nichts zwischen Exportbeginn und Übernahme.
    func testAdoptOpenExportIgnoresTheCursorSoNothingNewerThanItIsLost() {
        var plan = BackfillPlan.empty()
        let cursor = t0.addingTimeInterval(-5 * 86_400)

        plan.adoptOpenExport(
            completedTypes: [], olderThanCursors: [heartRate: cursor],
            floor: t0.addingTimeInterval(-14 * 86_400), now: t0, typeIds: [heartRate]
        )

        let covered = plan.entries[heartRate]?.covered ?? .distantPast
        XCTAssertGreaterThanOrEqual(covered, t0, "alles bis jetzt und darüber hinaus ist offen")
    }

    /// Review ME-08: Ein Typ, der im offenen Export schon fertig war und seinen Anchor hat, verpasst
    /// alles, was zwischen Exportbeginn und seiner Anchor-Erfassung eingetragen wurde. Er bekommt ein
    /// eigenes Fenster ab einer Stunde vor dem Exportbeginn (`adoptedGap`).
    func testAdoptOpenExportCoversTheGapOfFinishedTypesSinceTheExportBegan() {
        var plan = BackfillPlan.empty()
        let exportStart = t0.addingTimeInterval(-2 * 86_400)
        let floor = t0.addingTimeInterval(-14 * 86_400)

        plan.adoptOpenExport(
            completedTypes: [bodyMass, sleep], olderThanCursors: [:], floor: floor, now: t0,
            typeIds: [bodyMass, sleep], exportStartedAt: exportStart, gapTypes: [bodyMass]
        )

        let gap = plan.entries[bodyMass]
        XCTAssertEqual(gap?.origin, "adoptedGap")
        XCTAssertEqual(gap?.state, .pending)
        XCTAssertEqual(gap?.floor, exportStart.addingTimeInterval(-3_600))
        XCTAssertEqual(gap?.covered, BackfillPlan.openUpperBound(t0))
        XCTAssertNil(plan.entries[sleep], "ohne Anchor bootstrappt der Kern ihn ohnehin")
    }

    func testAdoptOpenExportLeavesExistingEntriesUntouchedAndIsIdempotent() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        plan.advance(typeId: heartRate, to: t0.addingTimeInterval(-900), boundaryIds: ["a"])
        let before = plan.entries[heartRate]

        plan.adoptOpenExport(
            completedTypes: [], olderThanCursors: [heartRate: t0.addingTimeInterval(-86_400)],
            floor: t0.addingTimeInterval(-14 * 86_400), now: t0
        )
        let once = plan
        plan.adoptOpenExport(
            completedTypes: [], olderThanCursors: [heartRate: t0.addingTimeInterval(-86_400)],
            floor: t0.addingTimeInterval(-14 * 86_400), now: t0
        )

        XCTAssertEqual(plan.entries[heartRate], before, "Fortschritt wird nie überschrieben")
        XCTAssertEqual(plan, once)
    }

    // MARK: Wiederherstellung nach Abbruch im Bootstrap

    func testReanchorExtendsAnOpenEntryToTheNewNow() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        let later = t0.addingTimeInterval(120)

        plan.reanchor(typeId: heartRate, now: later)

        XCTAssertEqual(plan.entries[heartRate]?.covered, later.addingTimeInterval(BackfillPlan.openEnd))
        XCTAssertEqual(plan.entries[heartRate]?.floor, t0.addingTimeInterval(-14 * 86_400), "das frühere Fenster bleibt")
        XCTAssertEqual(plan.entries[heartRate]?.boundaryIds, [])
    }

    func testReanchorIgnoresFinishedAndUnknownTypes() {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")
        plan.markDone(typeId: heartRate)
        let before = plan

        plan.reanchor(typeId: heartRate, now: t0.addingTimeInterval(60))
        plan.reanchor(typeId: bodyMass, now: t0.addingTimeInterval(60))

        XCTAssertEqual(plan, before)
    }

    // MARK: Ablehnungszustand

    func testRejectionStateIsKeptPerLaneAndCanBeCleared() {
        var plan = BackfillPlan.empty()
        let live = BackfillPlan.rejectionKey(typeId: heartRate, lane: .live)
        let backfill = BackfillPlan.rejectionKey(typeId: heartRate, lane: .backfill)
        XCTAssertNotEqual(live, backfill, "ein Giftsample in der einen Spur zählt nicht für die andere")

        plan.rejections[live] = RejectionState(consecutive: 2, limit: 1, lastStatus: 422)
        plan.rejections[backfill] = RejectionState(consecutive: 1, limit: 1, lastStatus: 400)
        plan.clearRejection(typeId: heartRate, lane: .live)

        XCTAssertNil(plan.rejections[live])
        XCTAssertNotNil(plan.rejections[backfill])
    }

    // MARK: Datei

    func testEmptyPlansGetDistinctSessionIds() {
        let a = BackfillPlan.empty()
        let b = BackfillPlan.empty()

        XCTAssertFalse(a.sessionId.isEmpty)
        XCTAssertNotEqual(a.sessionId, b.sessionId)
        XCTAssertEqual(a.version, BackfillPlan.currentVersion)
        XCTAssertTrue(a.entries.isEmpty)
        XCTAssertFalse(a.hasPending)
    }

    func testPlanSurvivesJSONRoundTripUnchanged() throws {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0.addingTimeInterval(0.1234567), daysBack: 14, origin: "bootstrap")
        plan.advance(typeId: heartRate, to: t0.addingTimeInterval(-600.0004), boundaryIds: ["a", "b"])
        plan.start(typeId: bodyMass, now: t0, daysBack: 14, origin: "adoptedExport")
        plan.markDone(typeId: bodyMass)
        plan.rejections[heartRate] = RejectionState(consecutive: 2, limit: 1, lastStatus: 422)

        let data = try plan.encoded()
        let decoded = try BackfillPlan.decode(data)

        XCTAssertEqual(decoded, plan, "auch Zeitstempel unter einer Millisekunde bleiben nach dem Laden gleich")
    }

    func testDatesAreWrittenAsISO8601WithMilliseconds() throws {
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: t0, daysBack: 14, origin: "bootstrap")

        let text = String(decoding: try plan.encoded(), as: UTF8.self)

        XCTAssertTrue(text.contains("\"startedAt\" : \"2026-10-04T08:00:00.000Z\""), text)
        XCTAssertTrue(text.contains("\"covered\" : \"2027-11-08T08:00:00.000Z\""), "nach oben offen (ME-07): \(text)")
        XCTAssertTrue(text.contains("\"floor\" : \"2026-09-20T08:00:00.000Z\""), text)
    }

    func testUnknownFieldsInTheFileDoNotBreakLoading() throws {
        let json = """
        {
          "version": 1,
          "sessionId": "abc",
          "futureTopLevel": {"x": 1},
          "entries": {
            "HKQuantityTypeIdentifierHeartRate": {
              "floor": "2026-09-20T08:00:00.000Z",
              "covered": "2026-10-04T08:00:00.000Z",
              "startedAt": "2026-10-04T08:00:00.000Z",
              "boundaryIds": [],
              "state": "pending",
              "origin": "bootstrap",
              "futureField": true
            }
          },
          "rejections": {}
        }
        """

        let plan = try BackfillPlan.decode(Data(json.utf8))

        XCTAssertEqual(plan.sessionId, "abc")
        XCTAssertEqual(plan.entries[heartRate]?.state, .pending)
        XCTAssertEqual(plan.entries[heartRate]?.covered, t0)
    }

    func testDatesWithoutFractionAreAccepted() throws {
        let json = """
        {"version":1,"sessionId":"s","entries":{"t":{"floor":"2026-09-20T08:00:00Z","covered":"2026-10-04T08:00:00Z","startedAt":"2026-10-04T08:00:00Z","boundaryIds":[],"state":"pending","origin":"x"}},"rejections":{}}
        """

        let plan = try BackfillPlan.decode(Data(json.utf8))

        XCTAssertEqual(plan.entries["t"]?.covered, t0)
    }

    func testACorruptDateFailsLoudlyInsteadOfInventingOne() {
        let json = """
        {"version":1,"sessionId":"s","entries":{"t":{"floor":"gestern","covered":"2026-10-04T08:00:00Z","startedAt":"2026-10-04T08:00:00Z","boundaryIds":[],"state":"pending","origin":"x"}},"rejections":{}}
        """

        XCTAssertThrowsError(try BackfillPlan.decode(Data(json.utf8)))
    }
}
