import XCTest
@testable import OpenWearablesHealthSDK

/// Regel für abgewiesene Pakete (Plan 05-06, Task 1, Pitfall 3 "Giftpille").
final class RejectionPolicyTests: XCTestCase {

    func testAnAttemptWithMoreThanOneItemHalvesTheLimit() {
        let (state, action) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 100)

        XCTAssertEqual(action, .halve(to: 50))
        XCTAssertEqual(state.limit, 50)
        XCTAssertEqual(state.lastStatus, 422)
    }

    func testHalvingDoesNotCountAsARejectionAtLimitOne() {
        var state: RejectionState?
        var limit = 2_000
        var actions: [RejectionAction] = []
        while limit > 1 {
            let (next, action) = RejectionPolicy.decide(state: state, httpStatus: 400, attemptedLimit: limit)
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
        let (_, action) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 3)
        XCTAssertEqual(action, .halve(to: 1))
    }

    func testTheFirstTwoRejectionsAtLimitOneHoldUntilTheNextCycle() {
        let (first, firstAction) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 1)
        XCTAssertEqual(firstAction, .holdUntilNextCycle)
        XCTAssertEqual(first.consecutive, 1)

        let (second, secondAction) = RejectionPolicy.decide(state: first, httpStatus: 422, attemptedLimit: 1)
        XCTAssertEqual(secondAction, .holdUntilNextCycle)
        XCTAssertEqual(second.consecutive, 2)
    }

    func testTheThirdRejectionAtLimitOneParks() {
        let second = RejectionState(consecutive: 2, limit: 1, lastStatus: 422)

        let (state, action) = RejectionPolicy.decide(state: second, httpStatus: 422, attemptedLimit: 1)

        XCTAssertEqual(action, .park)
        XCTAssertEqual(state.consecutive, RejectionPolicy.parkAfter)
    }

    func testParkAfterIsThree() {
        XCTAssertEqual(RejectionPolicy.parkAfter, 3)
    }

    func testTheLastStatusIsTheLatestOne() {
        let first = RejectionState(consecutive: 1, limit: 1, lastStatus: 400)
        let (state, _) = RejectionPolicy.decide(state: first, httpStatus: 422, attemptedLimit: 1)
        XCTAssertEqual(state.lastStatus, 422)
    }

    func testAcceptanceResetsTheState() {
        var plan = BackfillPlan.empty()
        let key = BackfillPlan.rejectionKey(typeId: "HKQuantityTypeIdentifierBodyMass", lane: .live)
        let (state, _) = RejectionPolicy.decide(state: nil, httpStatus: 422, attemptedLimit: 1)
        plan.rejections[key] = state

        plan.clearRejection(typeId: "HKQuantityTypeIdentifierBodyMass", lane: .live)
        let (again, action) = RejectionPolicy.decide(state: plan.rejections[key], httpStatus: 422, attemptedLimit: 1)

        XCTAssertEqual(again.consecutive, 1, "nach einer Annahme zählt die Reihe von vorn")
        XCTAssertEqual(action, .holdUntilNextCycle)
    }

    func testAZeroOrNegativeAttemptIsTreatedAsASingleItem() {
        let (_, action) = RejectionPolicy.decide(state: nil, httpStatus: 400, attemptedLimit: 0)
        XCTAssertEqual(action, .holdUntilNextCycle)
    }
}
