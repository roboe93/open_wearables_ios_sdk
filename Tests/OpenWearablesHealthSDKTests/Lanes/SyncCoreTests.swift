import XCTest
@testable import OpenWearablesHealthSDK

/// Der Steuerungskern mit Fakes (Plan 05-06, Task 2): Reihenfolge, Priorität, Anchor-Bootstrap,
/// gesperrt, abgewiesen, Frist und Ergebnis. Kein HealthKit, kein Netz.
final class SyncCoreTests: XCTestCase {

    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let weight = "HKQuantityTypeIdentifierBodyMass"
    private let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
    private let bodyFat = "HKQuantityTypeIdentifierBodyFatPercentage"

    private func ago(_ h: LaneHarness, _ seconds: TimeInterval) -> Date {
        h.clock.now().addingTimeInterval(-seconds)
    }

    // MARK: Reihenfolge und Priorität

    func testWeightOvertakesADenseBacklogInTheLiveLane() {
        let h = LaneHarness()
        h.presetAnchors([heartRate, weight])
        for i in 0..<3_000 { h.reader.insert(heartRate, id: "hr-\(i)", endDate: ago(h, Double(i))) }
        h.reader.insert(weight, id: "w1", endDate: ago(h, 60))

        let result = h.run(h.context([heartRate, weight], chunkLimit: 100))

        let first = h.sink.deliveries.first
        XCTAssertEqual(first?.lane, .live)
        XCTAssertEqual(first?.typeIds, [weight], "die erste Lieferung enthält das Gewicht und keine Herzfrequenz")
        XCTAssertEqual(h.sink.deliveries.count, 31, "ein Paket mit Gewicht, danach 30 Chunks Herzfrequenz")
        XCTAssertEqual(result.status, .transferred)
        XCTAssertEqual(result.liveRecords, 3_001)
        XCTAssertEqual(result.perType[heartRate], 3_000)
        XCTAssertEqual(result.perType[weight], 1)
    }

    func testWeightAlsoGoesFirstInTheBackfill() {
        let h = LaneHarness()
        for i in 1...300 { h.reader.insert(heartRate, id: "hr-\(i)", endDate: ago(h, Double(i) * 60)) }
        h.reader.insert(weight, id: "w1", endDate: ago(h, 3_600))

        let result = h.run(h.context([heartRate, weight], chunkLimit: 100))

        let first = h.sink.deliveries.first
        XCTAssertEqual(first?.lane, .backfill)
        XCTAssertEqual(first?.typeIds, [weight])
        XCTAssertEqual(result.backfillRecords, 301)
        XCTAssertFalse(result.backfillPending)
    }

    func testStageAPackagesStayWithinTheChunkLimit() {
        let h = LaneHarness()
        h.presetAnchors([sleep, weight, bodyFat])
        for type in [sleep, weight, bodyFat] {
            h.reader.insert(type, id: "\(type)-1", endDate: ago(h, 100))
            h.reader.insert(type, id: "\(type)-2", endDate: ago(h, 50))
        }

        let result = h.run(h.context([bodyFat, weight, sleep], chunkLimit: 4))

        XCTAssertEqual(h.sink.deliveries.map { $0.typeIds }, [[sleep, weight], [bodyFat]])
        XCTAssertTrue(h.sink.deliveries.allSatisfy { $0.count <= 4 })
        XCTAssertEqual(result.liveRecords, 6)
    }

    // MARK: Nachholen gibt ab

    func testBackfillYieldsToTheLiveLaneAtTheChunkBoundaryAndThenContinues() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        for i in 1...10 { h.reader.insert(heartRate, id: "hr-\(i)", endDate: ago(h, Double(i) * 600)) }

        var waiterCalls = 0
        var waiterResult: CycleResult?
        var backfillDeliveries = 0
        h.sink.onDeliver = { [unowned h] delivery in
            guard delivery.lane == .backfill else { return }
            backfillDeliveries += 1
            if backfillDeliveries == 2 {
                h.reader.insert(self.weight, id: "w-new", endDate: h.clock.now())
                let accepted = h.core.requestLiveRound { result in
                    waiterCalls += 1
                    waiterResult = result
                    h.log.add("waiter")
                }
                XCTAssertTrue(accepted)
            }
        }

        let result = h.run(h.context([heartRate, weight], chunkLimit: 2))

        XCTAssertEqual(
            h.sink.deliveries.map { $0.lane },
            [.backfill, .backfill, .live, .backfill, .backfill, .backfill],
            "nach der zweiten Nachhol-Lieferung kommt das Gewicht über die Live-Spur, danach geht das Nachholen weiter"
        )
        XCTAssertEqual(h.sink.deliveries[2].ids, ["w-new"])
        XCTAssertEqual(waiterCalls, 1, "der Waiter wird genau einmal gerufen")
        XCTAssertEqual(waiterResult?.liveRecords, 1)
        XCTAssertEqual(waiterResult?.status, .transferred)

        let liveDelivery = h.log.index(ofPrefix: "deliver:live")
        let waiterEntry = h.log.index(ofPrefix: "waiter")
        let nextBackfill = liveDelivery.flatMap { h.log.index(ofPrefix: "deliver:backfill", after: $0) }
        XCTAssertNotNil(liveDelivery)
        XCTAssertNotNil(waiterEntry)
        XCTAssertNotNil(nextBackfill)
        XCTAssertLessThan(liveDelivery ?? 0, waiterEntry ?? 0)
        XCTAssertLessThan(waiterEntry ?? 0, nextBackfill ?? 0, "der Waiter wird nach der Live-Runde bedient, vor dem nächsten Nachhol-Chunk")

        XCTAssertEqual(result.liveRecords, 1)
        XCTAssertEqual(result.backfillRecords, 10)
        XCTAssertFalse(result.backfillPending)
    }

    func testAWaiterRequestedDuringBootstrapIsServedByTheFirstLiveRound() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 20))

        var calls = 0
        var served: CycleResult?
        h.reader.onCurrentAnchor = { [unowned h] _ in
            _ = h.core.requestLiveRound { result in
                calls += 1
                served = result
            }
        }

        _ = h.run(h.context([heartRate, weight]))

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(served?.liveRecords, 1)
        XCTAssertEqual(served?.perType[weight], 1)
    }

    func testAWaiterIsServedExactlyOnceEvenWhenTheCycleEndsBeforeItsRound() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))

        var calls = 0
        var served: CycleResult?
        h.sink.responder = { _ in .failed("network(-1009)") }
        h.sink.onDeliver = { [unowned h] _ in
            _ = h.core.requestLiveRound { result in
                calls += 1
                served = result
            }
        }

        let result = h.run(h.context([weight]))

        XCTAssertEqual(result.status, .failed("network(-1009)"))
        XCTAssertEqual(calls, 1, "ein Waiter bleibt nie hängen, auch wenn der Zyklus vorher endet")
        XCTAssertEqual(served?.status, .failed("network(-1009)"))
        XCTAssertFalse(h.core.isRunning)
    }

    func testRequestLiveRoundWithoutARunningCycleIsNotAccepted() {
        let h = LaneHarness()
        var called = false

        let accepted = h.core.requestLiveRound { _ in called = true }

        XCTAssertFalse(accepted)
        XCTAssertFalse(called, "ohne laufenden Zyklus ruft der Kern den Waiter nicht, der Aufrufer startet einen Zyklus")
        XCTAssertFalse(h.core.isRunning)
    }

    func testASecondCycleWhileOneIsRunningIsSkippedAsBusy() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))

        var busy: CycleResult?
        var runningInside = false
        let weightId = weight
        h.sink.onDeliver = { [unowned h] _ in
            runningInside = h.core.isRunning
            h.core.runCycle(h.context([weightId])) { busy = $0 }
        }

        _ = h.run(h.context([weight]))

        XCTAssertTrue(runningInside)
        XCTAssertEqual(busy?.status, .skippedBusy)
        XCTAssertEqual(h.sink.deliveries.count, 1, "der zweite Zyklus hat nichts angefasst")
        XCTAssertFalse(h.core.isRunning)
    }

    // MARK: Bootstrap (Anchor jetzt, dann Nachholen)

    func testBootstrapCommitsTheAnchorBeforeTheFirstBackfillDeliveryAndNothingIsDeliveredTwice() {
        let h = LaneHarness()
        for i in 1...5 { h.reader.insert(heartRate, id: "hr-\(i)", endDate: ago(h, Double(i) * 3_600)) }

        var backfillDeliveries = 0
        h.sink.onDeliver = { [unowned h] delivery in
            guard delivery.lane == .backfill else { return }
            backfillDeliveries += 1
            if backfillDeliveries == 1 {
                // Ein neues Sample entsteht nach dem Bootstrap, mit Datum nach `covered`.
                h.clock.advance(60)
                h.reader.insert(self.heartRate, id: "hr-new", endDate: h.clock.now())
                _ = h.core.requestLiveRound { _ in }
            }
        }

        let result = h.run(h.context([heartRate], chunkLimit: 2))

        let commit = h.log.index(ofPrefix: "commit:\(heartRate)")
        let firstBackfill = h.log.index(ofPrefix: "deliver:backfill")
        XCTAssertNotNil(commit)
        XCTAssertNotNil(firstBackfill)
        XCTAssertLessThan(commit ?? 0, firstBackfill ?? 0, "der Anchor für jetzt steht fest, bevor das Nachholen etwas liefert")
        XCTAssertTrue(result.events.contains("bootstrap:\(heartRate)"))

        let live = h.sink.deliveries.filter { $0.lane == .live }
        let backfill = h.sink.deliveries.filter { $0.lane == .backfill }
        XCTAssertEqual(live.flatMap { $0.ids }, ["hr-new"], "das spätere Sample kommt über die Live-Spur")
        XCTAssertEqual(Set(backfill.flatMap { $0.ids }), ["hr-1", "hr-2", "hr-3", "hr-4", "hr-5"])

        let all = h.sink.deliveries.flatMap { $0.ids }
        XCTAssertEqual(all.count, Set(all).count, "kein Sample kommt zweimal an")
        XCTAssertEqual(all.count, 6)
    }

    func testBootstrapSavesThePlanBeforeItCommitsTheAnchor() {
        let h = LaneHarness()
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 600))

        _ = h.run(h.context([heartRate]))

        let saved = h.log.index(ofPrefix: "plan.save")
        let committed = h.log.index(ofPrefix: "commit:\(heartRate)")
        XCTAssertNotNil(saved)
        XCTAssertNotNil(committed)
        XCTAssertLessThan(saved ?? 0, committed ?? 0, "scheitert das Speichern, darf kein Anchor ohne Nachholplan entstehen")
        XCTAssertEqual(h.store.plan.entries[heartRate]?.origin, "bootstrap")
        XCTAssertEqual(h.store.plan.entries[heartRate]?.state, .done)
    }

    func testATypeWhoseBootstrapFailsIsNeverReadLiveWithoutAnAnchor() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 20))
        h.reader.failingAnchorTypes = [heartRate]

        let result = h.run(h.context([heartRate, weight]))

        XCTAssertFalse(h.reader.liveCalls.contains { $0.typeId == heartRate }, "kein fetchLive ohne Anchor")
        XCTAssertFalse(h.reader.windowCalls.contains { $0.typeId == heartRate })
        XCTAssertNil(h.cursors.anchor(for: heartRate))
        XCTAssertNil(h.store.plan.entries[heartRate], "ohne Anchor auch kein Nachholplan")
        XCTAssertTrue(result.events.contains("bootstrapFailed:\(heartRate)"))
        XCTAssertEqual(result.status, .failed("bootstrap"), "der Typ fehlt, das bleibt sichtbar")
        XCTAssertEqual(result.perType[weight], 1, "die anderen Typen laufen weiter")
    }

    func testABootstrapThatCannotSaveItsPlanCommitsNoAnchor() {
        let h = LaneHarness()
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 600))
        h.store.failSaves = true

        let result = h.run(h.context([heartRate]))

        XCTAssertNil(h.cursors.anchor(for: heartRate), "ohne gespeicherten Plan bliebe die Historie des Typs für immer ungeholt")
        XCTAssertTrue(result.events.contains("bootstrapFailed:\(heartRate)"))
        XCTAssertEqual(result.status, .failed("bootstrap"))
        XCTAssertTrue(h.sink.deliveries.isEmpty)
    }

    func testAnOpenBootstrapEntryWithoutAnAnchorIsReanchoredToNow() {
        let h = LaneHarness()
        // Zustand nach einem Abbruch zwischen "Plan gespeichert" und "Anchor festgeschrieben".
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: h.clock.now(), daysBack: 14, origin: "bootstrap")
        h.store.plan = plan
        h.clock.advance(120)
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 30))

        let result = h.run(h.context([heartRate]))

        XCTAssertNotNil(h.cursors.anchor(for: heartRate))
        XCTAssertTrue(result.events.contains("bootstrap:\(heartRate)"))
        XCTAssertEqual(h.sink.deliveries.flatMap { $0.ids }, ["hr-1"], "das Sample zwischen beiden Zeitpunkten geht nicht verloren")
    }

    func testAnAdoptedEntryWithoutAnAnchorIsReportedAndNotGuessed() {
        let h = LaneHarness()
        var plan = BackfillPlan.empty()
        plan.adoptOpenExport(
            completedTypes: [], olderThanCursors: [heartRate: ago(h, 3_600)],
            floor: ago(h, 14 * 86_400), now: h.clock.now()
        )
        h.store.plan = plan
        h.reader.insert(heartRate, id: "hr-old", endDate: ago(h, 7_200))

        let result = h.run(h.context([heartRate]))

        XCTAssertTrue(result.events.contains("noAnchor:\(heartRate)"))
        XCTAssertNil(h.cursors.anchor(for: heartRate), "den Anchor legt die Übernahme an, der Kern rät ihn nicht")
        XCTAssertFalse(h.reader.liveCalls.contains { $0.typeId == heartRate })
        XCTAssertEqual(h.sink.deliveries.flatMap { $0.ids }, ["hr-old"], "das Nachholen des übernommenen Exports läuft trotzdem")
    }

    // MARK: Gesperrt

    func testLockedBeforeTheStartTouchesNothing() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.protectedDataAvailable = false

        let result = h.run(h.context([weight, heartRate]))

        XCTAssertEqual(result.status, .deferredLocked)
        XCTAssertTrue(result.needsCatchUp)
        XCTAssertEqual(h.reader.totalCalls, 0, "keine Reader-Aufrufe")
        XCTAssertTrue(h.sink.deliveries.isEmpty, "keine Sink-Aufrufe")
        XCTAssertTrue(h.log.events.isEmpty, "kein Cursor bewegt sich")
        XCTAssertEqual(h.store.saveCount, 0)
        XCTAssertEqual(result.records, 0)
    }

    func testLockedInTheMiddleKeepsTheAcceptedTypeCommitted() {
        let h = LaneHarness()
        h.presetAnchors([weight, heartRate])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 20))
        h.reader.lockedTypes = [heartRate]

        let result = h.run(h.context([weight, heartRate]))

        XCTAssertEqual(result.status, .deferredLocked)
        XCTAssertTrue(result.needsCatchUp)
        XCTAssertEqual(h.sink.deliveries.map { $0.typeIds }, [[weight]])
        XCTAssertNotNil(h.log.index(ofPrefix: "commit:\(weight)"), "der angenommene erste Typ bleibt festgeschrieben")
        XCTAssertNil(h.log.index(ofPrefix: "commit:\(heartRate)"))
        XCTAssertEqual(h.cursors.anchor(for: heartRate), FakeReader.token(0), "der gesperrte Typ bleibt, wo er war")
        XCTAssertEqual(result.liveRecords, 1)
    }

    func testLockedWhileReadingStageADeliversWhatWasAlreadyRead() {
        let h = LaneHarness()
        h.presetAnchors([sleep, weight])
        h.reader.insert(sleep, id: "s1", endDate: ago(h, 10))
        h.reader.insert(weight, id: "w1", endDate: ago(h, 20))
        h.reader.lockedTypes = [weight]

        let result = h.run(h.context([sleep, weight]))

        XCTAssertEqual(result.status, .deferredLocked)
        XCTAssertEqual(h.sink.deliveries.map { $0.typeIds }, [[sleep]])
        XCTAssertNotNil(h.log.index(ofPrefix: "commit:\(sleep)"))
        XCTAssertNil(h.log.index(ofPrefix: "commit:\(weight)"))
        XCTAssertTrue(result.needsCatchUp)
    }

    func testALockedBackfillReadEndsAsDeferredLockedWithoutMovingTheCursor() {
        let h = LaneHarness()
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 600))
        h.reader.onFetchWindow = { [unowned h] type in h.reader.lockedTypes.insert(type) }

        let result = h.run(h.context([heartRate]))

        XCTAssertEqual(result.status, .deferredLocked)
        XCTAssertTrue(result.needsCatchUp)
        XCTAssertTrue(h.sink.deliveries.isEmpty)
        XCTAssertEqual(h.store.plan.entries[heartRate]?.state, .pending)
        XCTAssertTrue(result.backfillPending)
    }

    // MARK: Fehler, Abbruch

    func testAFailedDeliveryCommitsNothingAndFails() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.sink.responder = { _ in .failed("network(-1009)") }

        let result = h.run(h.context([weight]))

        XCTAssertEqual(result.status, .failed("network(-1009)"))
        XCTAssertNil(h.log.index(ofPrefix: "commit:"), "ohne Annahme kein Commit")
        XCTAssertEqual(h.cursors.anchor(for: weight), FakeReader.token(0))
        XCTAssertEqual(result.records, 0)
        XCTAssertFalse(h.core.isRunning)
    }

    func testCancellationBetweenAcceptanceAndCommitCommitsNothing() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.sink.onDeliver = { [unowned h] _ in h.cancelled = true }

        let result = h.run(h.context([weight]))

        XCTAssertNil(h.log.index(ofPrefix: "commit:"), "ein verlorener Lauf schreibt nichts mehr fest")
        XCTAssertEqual(h.cursors.anchor(for: weight), FakeReader.token(0))
        XCTAssertEqual(result.status, .partial(.cancelled))
    }

    func testACancelledUploadWithoutLostGenerationIsBackgroundTime() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.sink.responder = { _ in .cancelled }

        let result = h.run(h.context([weight]))

        XCTAssertEqual(result.status, .partial(.backgroundTime))
        XCTAssertNil(h.log.index(ofPrefix: "commit:"))
    }

    // MARK: Abgewiesen

    func testACombinedPackageRejectionIsRetriedPerTypeAndOnlyTheOffenderStays() {
        let h = LaneHarness()
        h.presetAnchors([sleep, weight, bodyFat])
        for type in [sleep, weight, bodyFat] { h.reader.insert(type, id: "\(type)-1", endDate: ago(h, 100)) }
        let offender = weight
        h.sink.rejectWhen(status: 422) { $0.typeIds.contains(offender) }

        let result = h.run(h.context([sleep, weight, bodyFat]))

        XCTAssertEqual(
            h.sink.deliveries.map { $0.typeIds },
            [[sleep, weight, bodyFat], [sleep], [weight], [bodyFat]],
            "erst das Sammelpaket, dann je Typ getrennt"
        )
        XCTAssertNotNil(h.log.index(ofPrefix: "commit:\(sleep)"))
        XCTAssertNotNil(h.log.index(ofPrefix: "commit:\(bodyFat)"), "ein abgewiesener Typ blockiert keinen anderen")
        XCTAssertNil(h.log.index(ofPrefix: "commit:\(weight)"))
        XCTAssertEqual(result.status, .rejected(httpStatus: 422), "und er bleibt sichtbar")
        XCTAssertEqual(result.liveRecords, 2)
    }

    func testASingleTypeRejectionHalvesTheLimitWithinTheCycleAndParksOnTheThirdCycle() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        for i in 1...4 { h.reader.insert(weight, id: "w\(i)", endDate: ago(h, Double(10 - i))) }
        h.sink.rejectWhen(status: 422) { $0.ids.contains("w3") }
        let context = h.context([weight], chunkLimit: 4)

        // Zyklus 1: 4 abgewiesen, halbiert auf 2, [w1,w2] angenommen, [w3,w4] abgewiesen, halbiert auf 1, [w3] abgewiesen.
        let first = h.run(context)
        XCTAssertEqual(h.sink.deliveries.map { $0.count }, [4, 2, 2, 1])
        XCTAssertEqual(h.cursors.anchor(for: weight), FakeReader.token(2), "festgeschrieben bis hinter w2")
        XCTAssertEqual(first.status, .rejected(httpStatus: 422))
        XCTAssertTrue(first.events.contains("halve:\(weight):2"))
        XCTAssertTrue(first.events.contains("halve:\(weight):1"))
        XCTAssertTrue(first.events.contains("hold:\(weight):422"))
        XCTAssertTrue(h.parking.parked.isEmpty)

        // Zyklus 2: nur das Einzelsample, zweite Ablehnung.
        let before2 = h.sink.deliveries.count
        let second = h.run(context)
        XCTAssertEqual(h.sink.deliveries.dropFirst(before2).map { $0.ids }, [["w3"]], "der nächste Zyklus beginnt beim Einzelsample")
        XCTAssertEqual(second.status, .rejected(httpStatus: 422))
        XCTAssertTrue(h.parking.parked.isEmpty)
        XCTAssertEqual(h.cursors.anchor(for: weight), FakeReader.token(2))

        // Zyklus 3: dritte Ablehnung in getrennten Zyklen, w3 wird geparkt, der Cursor rückt darüber hinaus.
        let before3 = h.sink.deliveries.count
        let third = h.run(context)
        XCTAssertEqual(h.parking.parked, [InMemoryParking.Parked(typeId: weight, itemId: "w3", httpStatus: 422, record: Data("w3".utf8))])
        XCTAssertTrue(third.events.contains("parked:\(weight)"))
        XCTAssertEqual(h.sink.deliveries.dropFirst(before3).map { $0.ids }, [["w3"], ["w4"]], "danach läuft w4 durch")
        XCTAssertEqual(h.cursors.anchor(for: weight), FakeReader.token(4))
        XCTAssertEqual(third.status, .rejected(httpStatus: 422), "das Parken bleibt in diesem Lauf sichtbar")
        XCTAssertEqual(third.perType[weight], 1)

        // Danach ist der Zustand zurückgesetzt.
        XCTAssertTrue(h.store.plan.rejections.isEmpty)
        let fourth = h.run(context)
        XCTAssertEqual(fourth.status, .upToDate)
    }

    func testAParkingFailureNeverMovesTheCursor() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.sink.rejectWhen(status: 422) { _ in true }
        h.parking.failPark = true
        let context = h.context([weight])

        _ = h.run(context)
        _ = h.run(context)
        let third = h.run(context)

        XCTAssertTrue(h.parking.parked.isEmpty)
        XCTAssertNil(h.log.index(ofPrefix: "commit:"), "ein Datensatz, der sich nicht ablegen lässt, wird nie übersprungen")
        XCTAssertEqual(third.status, .rejected(httpStatus: 422))
    }

    func testAPoisonSampleInTheBackfillIsParkedAfterThreeCycles() {
        let h = LaneHarness()
        h.reader.insert(heartRate, id: "s1", endDate: ago(h, 3 * 3_600))
        h.reader.insert(heartRate, id: "s2", endDate: ago(h, 2 * 3_600))
        h.reader.insert(heartRate, id: "s3", endDate: ago(h, 3_600))
        h.sink.rejectWhen(status: 400) { $0.ids.contains("s2") }
        let context = h.context([heartRate], chunkLimit: 1)

        let first = h.run(context)
        XCTAssertEqual(h.sink.deliveries.map { $0.ids }, [["s3"], ["s2"]])
        XCTAssertEqual(first.status, .rejected(httpStatus: 400))
        XCTAssertTrue(first.backfillPending)

        let second = h.run(context)
        XCTAssertEqual(second.status, .rejected(httpStatus: 400))
        XCTAssertTrue(h.parking.parked.isEmpty)

        let third = h.run(context)
        XCTAssertEqual(h.parking.parked.map { $0.itemId }, ["s2"])
        XCTAssertEqual(h.sink.deliveries.suffix(2).map { $0.ids }, [["s2"], ["s1"]], "nach dem Parken läuft das Nachholen weiter")
        XCTAssertEqual(h.store.plan.entries[heartRate]?.state, .done)
        XCTAssertFalse(third.backfillPending)
        XCTAssertEqual(h.sink.deliveries.flatMap { $0.ids }.filter { $0 == "s3" }.count, 1, "s3 kam nur einmal an")
    }

    func testARejectedBackfillTypeDoesNotBlockTheOtherTypes() {
        let h = LaneHarness()
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 3_600))
        h.reader.insert("HKQuantityTypeIdentifierStepCount", id: "st-1", endDate: ago(h, 3_600))
        h.sink.rejectWhen(status: 422) { $0.typeIds.contains(self.heartRate) }

        let result = h.run(h.context([heartRate, "HKQuantityTypeIdentifierStepCount"]))

        XCTAssertEqual(result.status, .rejected(httpStatus: 422))
        XCTAssertEqual(result.perType["HKQuantityTypeIdentifierStepCount"], 1)
        XCTAssertEqual(h.store.plan.entries["HKQuantityTypeIdentifierStepCount"]?.state, .done)
        XCTAssertEqual(h.store.plan.entries[heartRate]?.state, .pending)
    }

    // MARK: Frist

    func testADeadlineInTheBackfillWithACleanLiveLaneIsNotPartial() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        for i in 1...10 { h.reader.insert(heartRate, id: "hr-\(i)", endDate: ago(h, Double(i) * 600)) }
        let deadline = h.clock.now().addingTimeInterval(10)
        // Die Live-Spur endet mit der Abfrage der Herzfrequenz; danach ist die Frist um.
        h.reader.onFetchLive = { [unowned h] type in
            if type == self.heartRate { h.clock.advance(20) }
        }

        let result = h.run(h.context([heartRate, weight], chunkLimit: 2, deadline: deadline))

        XCTAssertEqual(result.status, .transferred, "die Live-Spur lieferte sauber, nur das Nachholen ist offen")
        XCTAssertTrue(result.backfillPending)
        XCTAssertEqual(result.backfillRecords, 0)
        XCTAssertEqual(result.liveRecords, 1)
        XCTAssertFalse(h.sink.deliveries.contains { $0.lane == .backfill })
    }

    func testADeadlineInTheBackfillWithNothingNewIsUpToDateWithPendingBackfill() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        for i in 1...10 { h.reader.insert(heartRate, id: "hr-\(i)", endDate: ago(h, Double(i) * 600)) }
        let deadline = h.clock.now().addingTimeInterval(10)
        h.reader.onFetchLive = { [unowned h] type in
            if type == self.heartRate { h.clock.advance(20) }
        }

        let result = h.run(h.context([heartRate, weight], chunkLimit: 2, deadline: deadline))

        XCTAssertEqual(result.status, .upToDate)
        XCTAssertTrue(result.backfillPending)
    }

    func testADeadlineInTheLiveLaneIsPartialBudget() {
        let h = LaneHarness()
        h.presetAnchors([weight, heartRate])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 20))
        let deadline = h.clock.now().addingTimeInterval(10)
        h.sink.onDeliver = { [unowned h] _ in h.clock.advance(20) }

        let result = h.run(h.context([heartRate, weight], deadline: deadline))

        XCTAssertEqual(result.status, .partial(.budget))
        XCTAssertEqual(h.sink.deliveries.map { $0.typeIds }, [[weight]], "die Frist endet vor dem nächsten Abrufen")
        XCTAssertNotNil(h.log.index(ofPrefix: "commit:\(weight)"), "was angenommen wurde, bleibt festgeschrieben")
        XCTAssertNil(h.log.index(ofPrefix: "commit:\(heartRate)"))
    }

    func testAnExpiredDeadlineAtTheStartEndsAsPartialBudgetWithoutReading() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))

        let result = h.run(h.context([weight], deadline: h.clock.now()))

        XCTAssertEqual(result.status, .partial(.budget))
        XCTAssertEqual(h.reader.totalCalls, 0)
        XCTAssertTrue(h.sink.deliveries.isEmpty)
    }

    // MARK: Löschungen

    func testDeletionsAreQueuedBeforeTheAnchorCommitAndADeletionOnlyChunkIsDelivered() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insertDeletion(typeId: weight, id: "gone-1")

        let result = h.run(h.context([weight]))

        XCTAssertEqual(h.sink.deliveries.count, 1, "ein Chunk nur mit Löschungen wird geliefert")
        XCTAssertEqual(h.sink.deliveries.first?.deleted, [DeletedRef(id: "gone-1", type: weight)])
        XCTAssertEqual(h.sink.deliveries.first?.ids, [])
        let enqueue = h.log.index(ofPrefix: "enqueue:\(weight)")
        let commit = h.log.index(ofPrefix: "commit:\(weight)")
        XCTAssertNotNil(enqueue)
        XCTAssertNotNil(commit)
        XCTAssertLessThan(enqueue ?? 0, commit ?? 0, "die Löschung steht in der Warteschlange, bevor der Anchor weiter ist")
        XCTAssertEqual(h.deletions.entries.first?.sentAt, nil, "nicht gesendet: der Server bekam das Feld nicht")
        XCTAssertEqual(result.deletionsQueued, 1)
        XCTAssertEqual(result.status, .upToDate, "Löschungen sind keine übertragenen Datensätze")
    }

    func testDeletionsReachedByTheServerAreMarkedWithTheSendTime() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insertDeletion(typeId: weight, id: "gone-1")
        h.sink.sendsDeletions = true

        _ = h.run(h.context([weight]))

        XCTAssertEqual(h.deletions.entries.first?.sentAt, h.clock.now())
    }

    func testAQueueFailureKeepsTheAnchorWhereItWasSoNoDeletionIsLost() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insertDeletion(typeId: weight, id: "gone-1")
        h.deletions.failEnqueue = true

        let result = h.run(h.context([weight]))

        XCTAssertNil(h.log.index(ofPrefix: "commit:"))
        XCTAssertEqual(result.status, .failed("deletion queue"))
    }

    // MARK: Gleiche Zeitpunkte über eine Chunk-Grenze

    func testThreeSamplesWithTheSameEndDateAcrossABackfillChunkBoundaryArriveExactlyOnce() {
        let h = LaneHarness()
        let tie = ago(h, 3_600)
        for id in ["a", "b", "c"] { h.reader.insert(heartRate, id: id, endDate: tie) }

        let result = h.run(h.context([heartRate], chunkLimit: 2))

        let all = h.sink.deliveries.flatMap { $0.ids }
        XCTAssertEqual(all.sorted(), ["a", "b", "c"], "alle drei kommen an, jedes genau einmal")
        XCTAssertEqual(h.store.plan.entries[heartRate]?.state, .done, "und der Zyklus endet")
        XCTAssertFalse(result.backfillPending)
        XCTAssertEqual(result.backfillRecords, 3)
        XCTAssertEqual(h.reader.windowCalls.map { $0.limit }, [2, 4], "die zweite Abfrage reicht um die bereits gelieferten Grenz-Samples")
    }

    func testFiveSamplesWithTheSameEndDateWithLimitTwoArriveExactlyOnce() {
        let h = LaneHarness()
        let tie = ago(h, 3_600)
        for id in ["a", "b", "c", "d", "e"] { h.reader.insert(heartRate, id: id, endDate: tie) }
        h.reader.insert(heartRate, id: "older", endDate: ago(h, 7_200))

        let result = h.run(h.context([heartRate], chunkLimit: 2))

        let all = h.sink.deliveries.flatMap { $0.ids }
        XCTAssertEqual(all.sorted(), ["a", "b", "c", "d", "e", "older"])
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertFalse(result.backfillPending)
    }

    func testASubMillisecondEndDateTieSurvivesTheRoundTripThroughTheFile() {
        let h = LaneHarness()
        // Drei Samples auf demselben Sub-Millisekunden-Zeitpunkt, ein Chunk je Zyklus. Der Plan geht
        // zwischen den Zyklen durch die Dateikodierung: ein gerundeter Rand würde das dritte verlieren.
        let tie = ago(h, 3_600).addingTimeInterval(0.0004)
        for id in ["a", "b", "c"] { h.reader.insert(heartRate, id: id, endDate: tie) }
        let store = RoundTripBackfillStore()
        let core = SyncCore(
            reader: h.reader, sink: h.sink, cursors: h.cursors, backfill: store,
            deletions: h.deletions, parking: h.parking, clock: h.clock, ordering: LaneOrdering()
        )
        h.sink.onDeliver = { [unowned h] delivery in
            if delivery.lane == .backfill { h.clock.advance(20) }
        }

        var cycles = 0
        while cycles < 6 {
            cycles += 1
            let semaphore = DispatchSemaphore(value: 0)
            let deadline = h.clock.now().addingTimeInterval(10)
            core.runCycle(h.context([heartRate], chunkLimit: 2, deadline: deadline)) { _ in semaphore.signal() }
            XCTAssertEqual(semaphore.wait(timeout: .now() + 15), .success)
            if !store.load().hasPending { break }
        }

        XCTAssertEqual(h.sink.deliveries.flatMap { $0.ids }.sorted(), ["a", "b", "c"], "alle drei genau einmal")
        XCTAssertGreaterThanOrEqual(cycles, 2, "der Plan wurde mindestens einmal über die Datei geladen")
        XCTAssertFalse(store.load().hasPending)
    }

    // MARK: Hängen, Lebenszeichen, Ereignisse

    func testAHangingReaderKeepsTheCoreBusyWithoutSpinningAndFinishesWhenReleased() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))
        h.reader.hangingTypes = [weight]

        let finished = DispatchSemaphore(value: 0)
        var result: CycleResult?
        h.core.runCycle(h.context([weight])) {
            result = $0
            finished.signal()
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .timedOut, "der Lauf wartet auf den Reader")
        XCTAssertTrue(h.core.isRunning)
        XCTAssertEqual(h.reader.liveCalls.count, 1, "kein Wiederholen in einer Schleife")

        h.reader.releaseHung()

        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(result?.status, .transferred)
        XCTAssertFalse(h.core.isRunning)
    }

    func testTheHeartbeatBeatsAtEveryCheckpoint() {
        let h = LaneHarness()
        h.presetAnchors([weight])
        h.reader.insert(weight, id: "w1", endDate: ago(h, 10))

        _ = h.run(h.context([weight]))

        // Fetch-Start, Fetch-Callback, Liefer-Start, Liefer-Ende, Commit.
        XCTAssertGreaterThanOrEqual(h.heartbeatCount, 5)
    }

    func testAnIdleCycleReportsUpToDateWithoutEvents() {
        let h = LaneHarness()
        h.presetAnchors([weight, heartRate])

        let result = h.run(h.context([weight, heartRate]))

        XCTAssertEqual(result.status, .upToDate)
        XCTAssertEqual(result.records, 0)
        XCTAssertFalse(result.needsCatchUp)
        XCTAssertFalse(result.backfillPending)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNil(h.log.index(ofPrefix: "commit:"), "ein unveränderter Anchor wird nicht neu geschrieben")
    }

    func testTypesOutsideTheContextAreNotBackfilled() {
        let h = LaneHarness()
        var plan = BackfillPlan.empty()
        plan.start(typeId: heartRate, now: h.clock.now(), daysBack: 14, origin: "bootstrap")
        h.store.plan = plan
        h.reader.insert(heartRate, id: "hr-1", endDate: ago(h, 600))

        let result = h.run(h.context([weight]))

        XCTAssertTrue(h.sink.deliveries.isEmpty)
        XCTAssertFalse(result.backfillPending, "ein nicht mehr verfolgter Typ zählt nicht als offen")
    }
}

/// Plan-Speicher, der jeden Stand durch die Dateikodierung schickt, wie ein echter es täte.
private final class RoundTripBackfillStore: BackfillStoring {
    private let lock = NSLock()
    private var data: Data?

    func load() -> BackfillPlan {
        lock.lock()
        defer { lock.unlock() }
        guard let data = data, let plan = try? BackfillPlan.decode(data) else { return BackfillPlan.empty() }
        return plan
    }

    func save(_ plan: BackfillPlan) throws {
        let encoded = try plan.encoded()
        lock.lock()
        data = encoded
        lock.unlock()
    }
}
