import XCTest
@testable import OpenWearablesHealthSDK

/// Stufenordnung der Live-Spur (Plan 05-06, Task 1).
final class LaneOrderingTests: XCTestCase {

    private let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
    private let workout = "HKWorkoutTypeIdentifier"
    private let bodyMass = "HKQuantityTypeIdentifierBodyMass"
    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let steps = "HKQuantityTypeIdentifierStepCount"

    func testSleepWorkoutAndWeightLeadStageAWhateverTheInputOrder() {
        let split = LaneOrdering().split([heartRate, bodyMass, steps, workout, sleep])

        XCTAssertEqual(Array(split.stageA.prefix(3)), [sleep, workout, bodyMass])
    }

    func testDenseTypesGoToStageB() {
        let split = LaneOrdering().split([sleep, heartRate, steps, bodyMass])

        XCTAssertEqual(split.stageA, [sleep, bodyMass])
        XCTAssertEqual(split.stageB, [heartRate, steps], "die Reihenfolge der Eingabe bleibt in Stufe B erhalten")
    }

    func testAnUnknownTypeLandsInStageA() {
        let unknown = "HKQuantityTypeIdentifierSomethingNew"

        let split = LaneOrdering().split([heartRate, unknown, sleep])

        XCTAssertEqual(split.stageA, [sleep, unknown], "Unbekanntes ist eher selten und wertvoll als dicht")
        XCTAssertEqual(split.stageB, [heartRate])
    }

    func testNoTypeIsLostOrDuplicated() {
        let input = [heartRate, sleep, "HKQuantityTypeIdentifierSomethingNew", steps, sleep, bodyMass]

        let split = LaneOrdering().split(input)

        XCTAssertEqual(Set(split.stageA + split.stageB), Set(input))
        XCTAssertEqual((split.stageA + split.stageB).count, Set(input).count, "doppelte Eingaben fallen weg")
    }

    func testAnEmptyInputGivesEmptyStages() {
        let split = LaneOrdering().split([])
        XCTAssertTrue(split.stageA.isEmpty)
        XCTAssertTrue(split.stageB.isEmpty)
    }

    func testPriorityStartsWithTheRareAndValuableTypes() {
        XCTAssertEqual(Array(LaneOrdering.priority.prefix(7)), [
            "HKCategoryTypeIdentifierSleepAnalysis",
            "HKWorkoutTypeIdentifier",
            "HKQuantityTypeIdentifierBodyMass",
            "HKQuantityTypeIdentifierBodyFatPercentage",
            "HKQuantityTypeIdentifierLeanBodyMass",
            "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            "HKQuantityTypeIdentifierRestingHeartRate",
        ])
    }

    func testTheDenseStartListHasFullIdentifiersAndNoOverlapWithPriority() {
        XCTAssertTrue(LaneOrdering.dense.contains("HKQuantityTypeIdentifierHeartRate"))
        XCTAssertTrue(LaneOrdering.dense.contains("HKQuantityTypeIdentifierStepCount"))
        XCTAssertTrue(LaneOrdering.dense.contains("HKQuantityTypeIdentifierFlightsClimbed"))
        XCTAssertEqual(LaneOrdering.dense.count, 24)
        XCTAssertTrue(LaneOrdering.dense.allSatisfy { $0.hasPrefix("HKQuantityTypeIdentifier") })
        XCTAssertTrue(Set(LaneOrdering.priority).isDisjoint(with: LaneOrdering.dense))
    }
}
