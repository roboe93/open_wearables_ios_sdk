import XCTest
@testable import OpenWearablesHealthSDK

/// Regel für abgewiesene Pakete (Plan 05-06, Task 1, Pitfall 3 "Giftpille").
final class RejectionPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_100_800)

    func testAnAttemptWithMoreThanOneItemHalvesTheLimit() {
        let (state, action) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 100, now: t0)

        XCTAssertEqual(action, .halve(to: 50))
        XCTAssertEqual(state.limit, 50)
        XCTAssertEqual(state.lastStatus, 422)
    }

    func testHalvingDoesNotCountAsARejectionAtLimitOne() {
        var state: RejectionState?
        var limit = 2_000
        var actions: [RejectionAction] = []
        while limit > 1 {
            let (next, action) = RejectionPolicy.decide(state: state, httpStatus: 400, attemptedLimit: limit, now: t0)
            state = next
            actions.append(action)
            if case .halve(let half) = action { limit = half } else { break }
        }

        XCTAssertEqual(limit, 1)
        XCTAssertEqual(state?.consecutive, 0, "bis hierher wurde nur halbiert")
        XCTAssertFalse(actions.contains(.park))
        XCTAssertFalse(actions.contains(.holdUntilNextCycle))
    }

    func testLimitThreeHalvesToOne() {
        let (_, action) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 3, now: t0)
        XCTAssertEqual(action, .halve(to: 1))
    }

    func testTheFirstTwoRejectionsAtLimitOneHoldUntilTheNextCycle() {
        let (first, firstAction) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 1, now: t0)
        XCTAssertEqual(firstAction, .holdUntilNextCycle)
        XCTAssertEqual(first.consecutive, 1)

        let (second, secondAction) = RejectionPolicy.decide(
            state: first, httpStatus: 422, attemptedLimit: 1, now: t0.addingTimeInterval(RejectionPolicy.countSpacing)
        )
        XCTAssertEqual(secondAction, .holdUntilNextCycle)
        XCTAssertEqual(second.consecutive, 2)
    }

    func testTheThirdRejectionAtLimitOneParks() {
        let second = RejectionState(consecutive: 2, limit: 1, lastStatus: 422, lastCountedAt: t0)

        let (state, action) = RejectionPolicy.decide(
            state: second, httpStatus: 422, attemptedLimit: 1, now: t0.addingTimeInterval(RejectionPolicy.countSpacing)
        )

        XCTAssertEqual(action, .park)
        XCTAssertEqual(state.consecutive, RejectionPolicy.parkAfter)
    }

    func testParkAfterIsThree() {
        XCTAssertEqual(RejectionPolicy.parkAfter, 3)
    }

    func testTheLastStatusIsTheLatestOne() {
        let first = RejectionState(consecutive: 1, limit: 1, lastStatus: 400, lastCountedAt: t0)
        let (state, _) = RejectionPolicy.decide(state: first, httpStatus: 422, attemptedLimit: 1, now: t0)
        XCTAssertEqual(state.lastStatus, 422)
    }

    func testAcceptanceResetsTheState() {
        var plan = BackfillPlan.empty()
        let key = BackfillPlan.rejectionKey(typeId: "HKQuantityTypeIdentifierBodyMass", lane: .live)
        let (state, _) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 1, now: t0)
        plan.rejections[key] = state

        plan.clearRejection(typeId: "HKQuantityTypeIdentifierBodyMass", lane: .live)
        let (again, action) = RejectionPolicy.decide(state: plan.rejections[key], httpStatus: 422, attemptedLimit: 1, now: t0)

        XCTAssertEqual(again.consecutive, 1, "nach einer Annahme zählt die Reihe von vorn")
        XCTAssertEqual(action, .holdUntilNextCycle)
    }

    func testAZeroOrNegativeAttemptIsTreatedAsASingleItem() {
        let (_, action) = RejectionPolicy.decide(state: nil, httpStatus: 400, attemptedLimit: 0, now: t0)
        XCTAssertEqual(action, .holdUntilNextCycle)
    }

    // MARK: Review HI-02

    /// Nur Antworten, die am Inhalt des Pakets hängen, grenzen ein und können parken. 403 (Rechte),
    /// 404/405 (Route nach einem Deploy oder Umzug), 408, 409 und 429 (Rate-Limit) sagen nichts über
    /// den Datensatz: wer darauf parkte, legte gültige Daten ab.
    func testOnlyContentStatusesAreRecordSpecific() {
        for status in [400, 413, 422] {
            XCTAssertTrue(RejectionPolicy.isRecordSpecific(status), "\(status)")
        }
        for status in [401, 403, 404, 405, 408, 409, 410, 429, 451, 500, 502, 503] {
            XCTAssertFalse(RejectionPolicy.isRecordSpecific(status), "\(status)")
        }
    }

    /// Drei Ablehnungen in kurzem Abstand (Vordergrund, Observer im Minutentakt) sind kein
    /// dauerhaftes Urteil: gezählt wird höchstens einmal je `countSpacing`.
    func testRejectionsWithinTheSpacingCountOnlyOnce() {
        var state: RejectionState?
        var actions: [RejectionAction] = []
        for minute in 0..<5 {
            let (next, action) = RejectionPolicy.decide(
                state: state, httpStatus: 422, attemptedLimit: 1, now: t0.addingTimeInterval(Double(minute) * 120)
            )
            state = next
            actions.append(action)
        }
        XCTAssertEqual(state?.consecutive, 1)
        XCTAssertFalse(actions.contains(.park))
    }

    func testThreeRejectionsSpacedByTheIntervalPark() {
        var state: RejectionState?
        var last: RejectionAction?
        for step in 0..<3 {
            let (next, action) = RejectionPolicy.decide(
                state: state, httpStatus: 400, attemptedLimit: 1,
                now: t0.addingTimeInterval(Double(step) * RejectionPolicy.countSpacing)
            )
            state = next
            last = action
        }
        XCTAssertEqual(last, .park)
        XCTAssertEqual(state?.lastCountedAt, t0.addingTimeInterval(2 * RejectionPolicy.countSpacing))
    }

    /// Ein Zähler aus 0.15.0-ow.2 hat keinen Zeitpunkt. Er wird nicht übernommen, die Zählung
    /// beginnt von vorn: sonst parkte die erste Ablehnung nach dem Update sofort.
    func testALegacyCountWithoutATimestampStartsOver() {
        let legacy = RejectionState(consecutive: 2, limit: 1, lastStatus: 422)

        let (state, action) = RejectionPolicy.decide(state: legacy, httpStatus: 422, attemptedLimit: 1, now: t0)

        XCTAssertEqual(action, .holdUntilNextCycle)
        XCTAssertEqual(state.consecutive, 1)
        XCTAssertEqual(state.lastCountedAt, t0)
    }

    func testHalvingKeepsTheCountAndItsTimestamp() {
        let counted = RejectionState(consecutive: 1, limit: 1, lastStatus: 422, lastCountedAt: t0)

        let (state, action) = RejectionPolicy.decide(state: counted, httpStatus: 413, attemptedLimit: 8, now: t0.addingTimeInterval(9_999))

        XCTAssertEqual(action, .halve(to: 4))
        XCTAssertEqual(state.consecutive, 1)
        XCTAssertEqual(state.lastCountedAt, t0)
    }
}
