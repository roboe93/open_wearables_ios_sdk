import XCTest
import HealthKit
import CoreLocation
@testable import OpenWearablesHealthSDK

/// Die Verdrahtung: kommt eine eingesammelte Route auch im Workout-Objekt an,
/// das hochgeladen wird?
final class WorkoutRouteSerializationTests: XCTestCase {

    private let sdk = OpenWearablesHealthSDK.shared
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func workout() -> HKWorkout {
        // Der moderne HKWorkoutBuilder schreibt in den Health-Store; hier wird
        // nur ein Objekt zum Serialisieren gebraucht.
        HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
    }

    private func fixes(count: Int) -> [RouteFix] {
        (0..<count).map { i in
            RouteFix(timestamp: start.addingTimeInterval(Double(i)),
                     latitude: 52.5200123456 + Double(i) / 111_320.0,
                     longitude: 13.4050456789,
                     altitude: 42.3,
                     horizontalAccuracy: 3.5,
                     verticalAccuracy: 2.0)
        }
    }

    private func workoutPayload(_ payload: [String: Any]) -> [String: Any]? {
        ((payload["data"] as? [String: Any])?["workouts"] as? [[String: Any]])?.first
    }

    func testRouteReachesTheUploadedWorkout() {
        let w = workout()
        let payload = sdk.serializeCombinedStreaming(samples: [w], routes: [w.uuid: fixes(count: 3)])

        guard let mapped = workoutPayload(payload) else { return XCTFail("kein Workout") }
        guard let route = mapped["route"] as? [[String: Any]] else { return XCTFail("keine Route") }

        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[0]["latitude"] as? Double, 52.5200123456,
                       "Koordinaten dürfen unterwegs nicht gerundet werden")
        XCTAssertEqual(route[0]["altitudeM"] as? Double, 42.3)
        XCTAssertEqual(route[0]["horizontalAccuracyM"] as? Double, 3.5)
        XCTAssertNotNil(route[0]["timestamp"] as? String)
    }

    func testWorkoutWithoutRouteStaysNull() {
        let w = workout()
        let payload = sdk.serializeCombinedStreaming(samples: [w], routes: [:])

        guard let mapped = workoutPayload(payload) else { return XCTFail("kein Workout") }
        XCTAssertTrue(mapped["route"] is NSNull,
                      "Indoor-Workouts haben keine Route — das ist kein Fehler")
    }

    func testRouteOfAnotherWorkoutIsNotAttached() {
        let mine = workout()
        let other = workout()
        let payload = sdk.serializeCombinedStreaming(samples: [mine],
                                                     routes: [other.uuid: fixes(count: 3)])

        guard let mapped = workoutPayload(payload) else { return XCTFail("kein Workout") }
        XCTAssertTrue(mapped["route"] is NSNull)
    }

    func testPayloadWithRouteRemainsValidJSON() {
        let w = workout()
        let payload = sdk.serializeCombinedStreaming(samples: [w], routes: [w.uuid: fixes(count: 500)])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }
}
