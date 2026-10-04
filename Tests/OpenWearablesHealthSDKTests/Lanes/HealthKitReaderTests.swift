import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Der HealthKit-Leser (Plan 05-07). Was HealthKit tatsächlich liefert, ist nur am Gerät prüfbar
/// (Spike S1, Plan 05-10). Hier steht, was ohne HealthKit prüfbar ist: Typauflösung, Verhalten bei
/// unbekanntem Typ und unlesbarem Anchor (ohne eine Abfrage zu stellen), die Fensterbedingung.
final class HealthKitReaderTests: XCTestCase {

    private let weight = "HKQuantityTypeIdentifierBodyMass"
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func withReader(tracking types: [HKSampleType], _ body: (HealthKitReader) -> Void) {
        let sdk = OpenWearablesHealthSDK.shared
        let previous = sdk.trackedTypes
        sdk.trackedTypes = types
        defer { sdk.trackedTypes = previous }
        body(HealthKitReader(sdk: sdk, generation: 1))
    }

    private func result<T>(
        _ call: (@escaping (Result<T, ReadFailure>) -> Void) -> Void
    ) -> Result<T, ReadFailure>? {
        var captured: Result<T, ReadFailure>?
        call { captured = $0 }
        return captured
    }

    // MARK: Typen

    func testTypesResolveByIdentifierFromTheTrackedTypes() {
        withReader(tracking: [HKQuantityType(.bodyMass), HKWorkoutType.workoutType()]) { reader in
            XCTAssertEqual(reader.resolveType(weight)?.identifier, weight)
            XCTAssertNotNil(reader.resolveType(HKWorkoutType.workoutType().identifier))
            XCTAssertNil(reader.resolveType("HKQuantityTypeIdentifierHeartRate"), "nicht verfolgt")
            XCTAssertNil(reader.resolveType("quatsch"))
        }
    }

    func testBloodPressureAndTheWorkoutRouteAreNeverQueryable() {
        let bloodPressure = HKCorrelationType(.bloodPressure)
        withReader(tracking: [bloodPressure, HKQuantityType(.bodyMass)]) { reader in
            XCTAssertNil(reader.resolveType(bloodPressure.identifier), "wie getQueryableTypes()")
            XCTAssertNil(reader.resolveType(HKSeriesType.workoutRoute().identifier), "Routen bleiben ausserhalb")
        }
    }

    func testIdentityIsTheUuidAndTheEndDate() {
        withReader(tracking: []) { reader in
            let end = epoch.addingTimeInterval(60)
            let sample = HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80),
                start: epoch, end: end
            )
            let identity = reader.identity(of: sample)
            XCTAssertEqual(identity.id, sample.uuid.uuidString)
            XCTAssertEqual(identity.endDate, end)
        }
    }

    // MARK: Unbekannter Typ: scheitert ohne Abfrage

    func testFetchLiveForAnUnknownIdentifierFailsWithOtherWithoutAskingHealthKit() {
        withReader(tracking: []) { reader in
            let outcome = result { reader.fetchLive(typeId: "gibt-es-nicht", anchor: Data(), limit: 10, completion: $0) }
            guard case .failure(.other(let reason))? = outcome else {
                return XCTFail("erwartet .failure(.other), bekommen \(String(describing: outcome))")
            }
            XCTAssertEqual(reason, "unknown type")
        }
    }

    func testFetchWindowAndCurrentAnchorForAnUnknownIdentifierFailWithOther() {
        withReader(tracking: []) { reader in
            let window = result {
                reader.fetchWindow(typeId: "gibt-es-nicht", floor: epoch, upTo: epoch, limit: 10, completion: $0)
            }
            guard case .failure(.other)? = window else {
                return XCTFail("erwartet .failure(.other), bekommen \(String(describing: window))")
            }
            let anchor = result { reader.currentAnchor(typeId: "gibt-es-nicht", completion: $0) }
            guard case .failure(.other)? = anchor else {
                return XCTFail("erwartet .failure(.other), bekommen \(String(describing: anchor))")
            }
        }
    }

    // MARK: Anchor: nur Secure Coding, nie "dann eben ohne"

    func testAnUnreadableAnchorFailsInsteadOfReadingTheWholeHistory() {
        withReader(tracking: [HKQuantityType(.bodyMass)]) { reader in
            let outcome = result { reader.fetchLive(typeId: weight, anchor: Data("müll".utf8), limit: 10, completion: $0) }
            guard case .failure(.other(let reason))? = outcome else {
                return XCTFail("erwartet .failure(.other), bekommen \(String(describing: outcome))")
            }
            XCTAssertEqual(reason, "anchor unreadable")
        }
    }

    func testAnArchiveOfAnotherClassIsNotAcceptedAsAnAnchor() throws {
        let foreign = try NSKeyedArchiver.archivedData(withRootObject: "kein Anchor" as NSString, requiringSecureCoding: true)
        withReader(tracking: [HKQuantityType(.bodyMass)]) { reader in
            let outcome = result { reader.fetchLive(typeId: weight, anchor: foreign, limit: 10, completion: $0) }
            guard case .failure(.other(let reason))? = outcome else {
                return XCTFail("erwartet .failure(.other), bekommen \(String(describing: outcome))")
            }
            XCTAssertEqual(reason, "anchor unreadable", "T-05-27: nur HKQueryAnchor wird entpackt")
        }
    }

    // MARK: Fensterbedingung

    private func sample(endingAt end: Date) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(.bodyMass),
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80),
            start: end.addingTimeInterval(-60), end: end
        )
    }

    func testTheWindowPredicateIncludesBothBoundsAndNothingBeyond() {
        let floor = epoch
        let upTo = epoch.addingTimeInterval(3600)
        let predicate = HealthKitReader.windowPredicate(floor: floor, upTo: upTo)

        XCTAssertTrue(predicate.evaluate(with: sample(endingAt: floor)), "untere Grenze inklusiv")
        XCTAssertTrue(predicate.evaluate(with: sample(endingAt: upTo)), "obere Grenze inklusiv")
        XCTAssertTrue(predicate.evaluate(with: sample(endingAt: epoch.addingTimeInterval(1800))))
        XCTAssertFalse(predicate.evaluate(with: sample(endingAt: floor.addingTimeInterval(-0.001))))
        XCTAssertFalse(predicate.evaluate(with: sample(endingAt: upTo.addingTimeInterval(0.001))))
    }

    func testTheWindowPredicateLooksAtTheEndDateNotTheStartDate() {
        let predicate = HealthKitReader.windowPredicate(floor: epoch, upTo: epoch.addingTimeInterval(100))
        // Beginnt vor dem Fenster, endet darin: zählt.
        let straddling = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 5),
            start: epoch.addingTimeInterval(-500), end: epoch.addingTimeInterval(50)
        )
        XCTAssertTrue(predicate.evaluate(with: straddling))
        XCTAssertTrue(predicate.predicateFormat.contains(HKPredicateKeyPathEndDate), predicate.predicateFormat)
    }
}
