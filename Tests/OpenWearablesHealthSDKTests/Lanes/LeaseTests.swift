import XCTest
@testable import OpenWearablesHealthSDK

/// Die Sperre mit Frist (Plan 05-06, Task 3, SYNC-09): eine Sperre ohne Lebenszeichen verfällt nach
/// 150 Sekunden von selbst, der alte Lauf kann danach nichts mehr festschreiben. Baut auf den
/// Run-Generationen von 0.15 auf (`SyncCancellationTests`), nichts zweites daneben.
final class LeaseTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_100_800)

    // MARK: Reine Entscheidung

    func testGrantsTheSlotWhenNothingRuns() {
        XCTAssertEqual(
            SyncLease.decide(isSyncing: false, cancelRequestedAt: nil, leaseDeadline: nil, now: t0),
            .grant
        )
        XCTAssertEqual(
            SyncLease.decide(isSyncing: false, cancelRequestedAt: t0.addingTimeInterval(-500), leaseDeadline: t0.addingTimeInterval(-500), now: t0),
            .grant,
            "ein freier Slot wird nie übernommen, egal was an alten Zeiten übrig ist"
        )
    }

    func testABusyRunWithALeaseInTheFutureKeepsTheSlot() {
        let decision = SyncLease.decide(
            isSyncing: true, cancelRequestedAt: nil, leaseDeadline: t0.addingTimeInterval(10), now: t0
        )
        XCTAssertEqual(decision, .busy)
    }

    func testTheLeaseIsNotExpiredAtTheExactDeadline() {
        let decision = SyncLease.decide(isSyncing: true, cancelRequestedAt: nil, leaseDeadline: t0, now: t0)
        XCTAssertEqual(decision, .busy, "übernommen wird erst, wenn die Frist überschritten ist")
    }

    func testAnExpiredLeaseIsTakenOver() {
        let decision = SyncLease.decide(
            isSyncing: true, cancelRequestedAt: nil, leaseDeadline: t0.addingTimeInterval(-1), now: t0
        )
        XCTAssertEqual(decision, .takeOver("leaseExpired"))
    }

    func testACancelRequestOlderThanSixtySecondsIsTakenOver() {
        let decision = SyncLease.decide(
            isSyncing: true, cancelRequestedAt: t0.addingTimeInterval(-61),
            leaseDeadline: t0.addingTimeInterval(100), now: t0
        )
        XCTAssertEqual(decision, .takeOver("cancelled"), "die Regel von 0.15 lebt weiter")
    }

    func testARecentCancelRequestStillKeepsTheSlot() {
        let decision = SyncLease.decide(
            isSyncing: true, cancelRequestedAt: t0.addingTimeInterval(-30),
            leaseDeadline: t0.addingTimeInterval(100), now: t0
        )
        XCTAssertEqual(decision, .busy)
    }

    func testAnExpiredLeaseIsReportedAsSuchWhenBothRulesApply() {
        let decision = SyncLease.decide(
            isSyncing: true, cancelRequestedAt: t0.addingTimeInterval(-100),
            leaseDeadline: t0.addingTimeInterval(-5), now: t0
        )
        XCTAssertEqual(decision, .takeOver("leaseExpired"))
    }

    func testARunningSlotWithoutALeaseIsNeverExpired() {
        let decision = SyncLease.decide(isSyncing: true, cancelRequestedAt: nil, leaseDeadline: nil, now: t0)
        XCTAssertEqual(decision, .busy, "ohne Frist gibt es nichts, was verfallen könnte")
    }

    func testTheLeaseOutlastsTheForegroundRequestTimeout() {
        // Die Vordergrund-Session hat 120 s Timeout. Eine kürzere Frist übernähme einen legitim
        // langsamen Upload (Recherche, Pitfall 5).
        XCTAssertEqual(SyncLease.leaseDuration, 150)
        XCTAssertGreaterThan(SyncLease.leaseDuration, 120)
        XCTAssertEqual(SyncLease.cancelledTakeoverDelay, 60)
    }

    // MARK: Im SDK

    /// Setzt die Uhr des SDK und stellt sie danach zurück.
    private func withClock(_ sdk: OpenWearablesHealthSDK, _ body: (_ advance: (TimeInterval) -> Void) -> Void) {
        var current = t0
        let previous = sdk.now
        sdk.now = { current }
        defer { sdk.now = previous }
        body { current = current.addingTimeInterval($0) }
    }

    func testAHungRunLosesTheSlotAfterTheLeaseAndTheOldRunIsLockedOut() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let first = sdk.beginSyncRun() else { return XCTFail("Der erste Lauf sollte den Slot bekommen") }
                XCTAssertEqual(sdk.leaseDeadline, t0.addingTimeInterval(150))

                advance(151)
                guard let second = sdk.beginSyncRun() else {
                    sdk.finishSync(generation: first)
                    return XCTFail("Nach 151 s ohne Lebenszeichen sollte der zweite Lauf übernehmen")
                }
                defer { sdk.finishSync(generation: second) }

                XCTAssertEqual(second, first + 1)
                XCTAssertTrue(sdk.isSyncCancelled(generation: first), "der alte Lauf ist ausgesperrt")
                XCTAssertFalse(sdk.isSyncCancelled(generation: second))

                sdk.finishSync(generation: first)
                XCTAssertTrue(sdk.isSyncInProgress, "das Ende des alten Laufs gibt den Slot nicht frei")
            }
            XCTAssertFalse(sdk.isSyncInProgress)
        }
    }

    func testARunWithinItsLeaseKeepsTheSlot() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                defer { sdk.finishSync(generation: generation) }

                advance(149)
                XCTAssertNil(sdk.beginSyncRun(), "149 s sind noch innerhalb der Frist")
            }
        }
    }

    func testAHeartbeatExtendsTheLease() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                defer { sdk.finishSync(generation: generation) }

                advance(100)
                sdk.heartbeat(generation: generation)
                XCTAssertEqual(sdk.leaseDeadline, t0.addingTimeInterval(250))

                advance(100)
                XCTAssertNil(sdk.beginSyncRun(), "bei +200 s trägt der Heartbeat von +100 s noch")
                XCTAssertFalse(sdk.isSyncCancelled(generation: generation))
            }
        }
    }

    func testALiveRunThatKeepsBeatingIsNeverTakenOver() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                defer { sdk.finishSync(generation: generation) }

                for _ in 0..<6 {
                    advance(100)
                    sdk.heartbeat(generation: generation)
                    XCTAssertNil(sdk.beginSyncRun())
                }
            }
        }
    }

    func testAHeartbeatOfASupersededRunExtendsNothing() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let first = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                advance(151)
                guard let second = sdk.beginSyncRun() else {
                    sdk.finishSync(generation: first)
                    return XCTFail("Übernahme erwartet")
                }
                defer { sdk.finishSync(generation: second) }
                let deadline = sdk.leaseDeadline
                XCTAssertEqual(deadline, t0.addingTimeInterval(151 + 150))

                advance(10)
                sdk.heartbeat(generation: first)

                XCTAssertEqual(sdk.leaseDeadline, deadline, "der überholte Lauf lebt nur scheinbar")
            }
        }
    }

    func testAHeartbeatWithoutARunDoesNothing() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { _ in
                sdk.heartbeat(generation: 1)
                XCTAssertNil(sdk.leaseDeadline)
            }
        }
    }

    func testFinishingTheRunClearsTheLease() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                XCTAssertNotNil(sdk.leaseDeadline)

                sdk.finishSync(generation: generation)

                XCTAssertNil(sdk.leaseDeadline)
                XCTAssertFalse(sdk.isSyncInProgress)
            }
        }
    }

    func testTheTakeoverIsWrittenToTheJournalAndMarkedInTheStatsOfTheNewRun() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let first = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                XCTAssertEqual(sdk.runStats(for: first)?.snapshot().leaseTakenOver, false)

                advance(151)
                guard let second = sdk.beginSyncRun() else {
                    sdk.finishSync(generation: first)
                    return XCTFail("Übernahme erwartet")
                }
                defer { sdk.finishSync(generation: second) }

                XCTAssertEqual(sdk.runStats(for: second)?.snapshot().leaseTakenOver, true)
                let entries = sdk.journalEntries().filter { $0.kind == "lease" }
                XCTAssertEqual(entries.count, 1)
                XCTAssertTrue(entries.first?.note?.contains("leaseExpired") ?? false, entries.first?.note ?? "kein Eintrag")
                XCTAssertTrue(entries.first?.note?.contains("previous=\(first)") ?? false, "die alte Generation steht im Eintrag")
                XCTAssertEqual(entries.first?.leaseTakenOver, true)
            }
        }
    }

    func testNoJournalEntryWhenTheSlotWasFree() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { _ in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                defer { sdk.finishSync(generation: generation) }

                XCTAssertTrue(sdk.journalEntries().filter { $0.kind == "lease" }.isEmpty)
                XCTAssertEqual(sdk.runStats(for: generation)?.snapshot().leaseTakenOver, false)
            }
        }
    }

    func testTheCancelRuleOfTheOriginalStillTakesOverAfterSixtySeconds() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let first = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                sdk.cancelSync()

                advance(30)
                XCTAssertNil(sdk.beginSyncRun(), "30 s nach dem Abbruch gehört der Slot noch dem alten Lauf")

                advance(31)
                guard let second = sdk.beginSyncRun() else {
                    sdk.finishSync(generation: first)
                    return XCTFail("61 s nach dem Abbruch sollte übernommen werden")
                }
                defer { sdk.finishSync(generation: second) }

                XCTAssertEqual(second, first + 1)
                XCTAssertTrue(sdk.isSyncCancelled(generation: first))
                XCTAssertEqual(sdk.runStats(for: second)?.snapshot().leaseTakenOver, true)
                XCTAssertTrue(sdk.journalEntries().contains { $0.kind == "lease" && ($0.note ?? "").contains("cancelled") })
            }
        }
    }

    func testALateRunBeyondTheLeaseOfAFinishedRunStartsWithoutATakeover() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let first = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                sdk.finishSync(generation: first)

                advance(1_000)
                guard let second = sdk.beginSyncRun() else { return XCTFail("freier Slot") }
                defer { sdk.finishSync(generation: second) }

                XCTAssertEqual(sdk.runStats(for: second)?.snapshot().leaseTakenOver, false, "ein freier Slot ist keine Übernahme")
            }
        }
    }

    // MARK: Schreiben nur mit gültiger Generation (Review HI-01)

    func testACommitOfARunThatLostItsSlotIsRefusedAndWritesNothing() {
        withIsolatedSDK { sdk, _ in
            withClock(sdk) { advance in
                guard let old = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
                advance(151)
                guard let new = sdk.beginSyncRun() else {
                    sdk.finishSync(generation: old)
                    return XCTFail("Übernahme erwartet")
                }
                defer {
                    sdk.finishSync(generation: old)
                    sdk.finishSync(generation: new)
                }

                var writes: [Int] = []
                XCTAssertFalse(sdk.commitIfCurrent(generation: old) { writes.append(old) })
                XCTAssertTrue(sdk.commitIfCurrent(generation: new) { writes.append(new) })
                XCTAssertEqual(writes, [new], "nur der Lauf, dem der Slot gehört, schreibt")
            }
        }
    }

    func testACancelledRunCannotCommit() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
            defer { sdk.finishSync(generation: generation) }
            sdk.cancelSync()

            var wrote = false
            XCTAssertFalse(sdk.commitIfCurrent(generation: generation) { wrote = true })
            XCTAssertFalse(wrote)
        }
    }

    /// Prüfen und Schreiben sind ein Schritt: ein Abbruch (und ebenso eine Übernahme) wartet, bis
    /// ein Schreibschritt, der schon läuft, fertig ist. Danach schreibt der alte Lauf nichts mehr.
    /// Ohne das läge zwischen Prüfung und Schreiben ein Fenster, in dem ein neuerer Lauf schon
    /// geladen hat und der alte ihm den Stand überschreibt (TOCTOU).
    func testACancelWaitsForAWriteThatIsAlreadyRunningAndFencesTheNextOne() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("Slot nicht erhalten") }
            defer { sdk.finishSync(generation: generation) }

            let writing = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var writeEnded: Date?
            DispatchQueue.global().async {
                _ = sdk.commitIfCurrent(generation: generation) {
                    writing.signal()
                    Thread.sleep(forTimeInterval: 0.3)
                    lock.lock()
                    writeEnded = Date()
                    lock.unlock()
                }
                done.signal()
            }
            XCTAssertEqual(writing.wait(timeout: .now() + 5), .success)

            sdk.cancelSync()
            let cancelReturned = Date()

            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            lock.lock()
            let ended = writeEnded
            lock.unlock()
            XCTAssertNotNil(ended)
            XCTAssertGreaterThanOrEqual(cancelReturned, ended ?? .distantFuture, "der Abbruch kam erst nach dem Schreiben durch")

            var wroteAgain = false
            XCTAssertFalse(sdk.commitIfCurrent(generation: generation) { wroteAgain = true })
            XCTAssertFalse(wroteAgain)
        }
    }
}
