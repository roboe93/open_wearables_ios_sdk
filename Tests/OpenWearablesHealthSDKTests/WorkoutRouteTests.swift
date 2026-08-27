import XCTest
import CoreLocation
@testable import OpenWearablesHealthSDK

final class WorkoutRouteTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Ein Meter in Grad Breite. Für Längengrade auf 52° Nord etwa 1.64-fach mehr.
    private let metreInDegrees = 1.0 / 111_320.0

    private func location(lat: Double = 52.5200123456,
                          lon: Double = 13.4050456789,
                          altitude: Double = 42.3,
                          accuracy: Double = 3.5,
                          verticalAccuracy: Double = 2.0,
                          at offset: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                   altitude: altitude,
                   horizontalAccuracy: accuracy,
                   verticalAccuracy: verticalAccuracy,
                   timestamp: t0.addingTimeInterval(offset))
    }

    // MARK: - Übernahme aus CoreLocation

    func testKeepsFullCoordinatePrecision() {
        let fixes = WorkoutRoute.fixes(from: [location()])
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(fixes[0].latitude, 52.5200123456)
        XCTAssertEqual(fixes[0].longitude, 13.4050456789)
        XCTAssertEqual(fixes[0].altitude, 42.3)
        XCTAssertEqual(fixes[0].horizontalAccuracy, 3.5)
    }

    func testSortsByTimestamp() {
        let fixes = WorkoutRoute.fixes(from: [location(at: 20), location(at: 0), location(at: 10)])
        XCTAssertEqual(fixes.map { $0.timestamp.timeIntervalSinceReferenceDate - 800_000_000 },
                       [0, 10, 20])
    }

    func testDropsFixesWithUnusableAccuracy() {
        let fixes = WorkoutRoute.fixes(from: [
            location(accuracy: 3, at: 0),
            location(accuracy: 120, at: 1),   // zu ungenau
            location(accuracy: -1, at: 2),    // ungültig
            location(accuracy: 50, at: 3)     // Grenzwert, bleibt
        ])
        XCTAssertEqual(fixes.count, 2)
        XCTAssertEqual(fixes.map(\.horizontalAccuracy), [3, 50])
    }

    func testDropsInvalidCoordinates() {
        let fixes = WorkoutRoute.fixes(from: [location(lat: 91, at: 0), location(at: 1)])
        XCTAssertEqual(fixes.count, 1)
    }

    func testFehlendeHoeheWirdNichtErfunden() {
        // CoreLocation meldet unbekannte Höhe über eine negative Vertikalgenauigkeit.
        let fixes = WorkoutRoute.fixes(from: [location(altitude: 0, verticalAccuracy: -1)])
        XCTAssertNil(fixes[0].altitude)
        XCTAssertNil(fixes[0].verticalAccuracy)
    }

    // MARK: - Ausdünnen auf ~1 Hz

    func testDownsamplesToOneFixPerSecond() {
        let dense = (0..<10).map { location(at: Double($0) * 0.2) }   // 5 Hz
        let thinned = WorkoutRoute.downsample(WorkoutRoute.fixes(from: dense), minimumInterval: 1)
        let seconds = thinned.map { $0.timestamp.timeIntervalSince(self.t0) }
        XCTAssertEqual(seconds.count, 3)
        for (actual, expected) in zip(seconds, [0, 1, 1.8]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
    }

    func testDownsamplingKeepsSparseRouteUntouched() {
        let sparse = (0..<5).map { location(at: Double($0) * 3) }
        let fixes = WorkoutRoute.fixes(from: sparse)
        XCTAssertEqual(WorkoutRoute.downsample(fixes, minimumInterval: 1).count, 5)
    }

    // MARK: - Douglas-Peucker

    func testSimplifyDropsPointsOnAStraightLine() {
        let straight = (0..<5).map { location(lat: 52.52 + Double($0) * 10 * metreInDegrees, at: Double($0)) }
        let simplified = WorkoutRoute.simplify(WorkoutRoute.fixes(from: straight), toleranceMeters: 2.5)
        XCTAssertEqual(simplified.count, 2, "Nur Anfang und Ende bleiben übrig")
    }

    func testSimplifyKeepsARealCorner() {
        // Mittelpunkt 10 m neben der Verbindungslinie — das ist eine Kurve.
        let corner = [
            location(lat: 52.52, lon: 13.40, at: 0),
            location(lat: 52.52 + 10 * metreInDegrees, lon: 13.405, at: 1),
            location(lat: 52.52, lon: 13.41, at: 2)
        ]
        let simplified = WorkoutRoute.simplify(WorkoutRoute.fixes(from: corner), toleranceMeters: 2.5)
        XCTAssertEqual(simplified.count, 3)
    }

    func testSimplifyDropsAnImperceptibleWobble() {
        let wobble = [
            location(lat: 52.52, lon: 13.40, at: 0),
            location(lat: 52.52 + 1 * metreInDegrees, lon: 13.405, at: 1),
            location(lat: 52.52, lon: 13.41, at: 2)
        ]
        let simplified = WorkoutRoute.simplify(WorkoutRoute.fixes(from: wobble), toleranceMeters: 2.5)
        XCTAssertEqual(simplified.count, 2)
    }

    func testSimplifyKeepsFirstAndLast() {
        let fixes = WorkoutRoute.fixes(from: [location(at: 0), location(at: 1)])
        XCTAssertEqual(WorkoutRoute.simplify(fixes, toleranceMeters: 2.5).count, 2)
    }

    func testSimplifyHandlesEmptyAndSingle() {
        XCTAssertTrue(WorkoutRoute.simplify([], toleranceMeters: 2.5).isEmpty)
        let one = WorkoutRoute.fixes(from: [location()])
        XCTAssertEqual(WorkoutRoute.simplify(one, toleranceMeters: 2.5).count, 1)
    }

    // MARK: - Nutzlast

    func testPayloadUsesTheKeysTheBackendReads() {
        let fixes = WorkoutRoute.fixes(from: [location()])
        let payload = WorkoutRoute.payload(fixes, dateFormatter: ISO8601DateFormatter())
        XCTAssertEqual(payload.count, 1)
        let fix = payload[0]
        XCTAssertEqual(fix["latitude"] as? Double, 52.5200123456)
        XCTAssertEqual(fix["longitude"] as? Double, 13.4050456789)
        XCTAssertEqual(fix["altitudeM"] as? Double, 42.3)
        XCTAssertEqual(fix["horizontalAccuracyM"] as? Double, 3.5)
        XCTAssertEqual(fix["verticalAccuracyM"] as? Double, 2.0)
        XCTAssertNotNil(fix["timestamp"] as? String)
    }

    func testPayloadOmitsUnknownAltitude() {
        let fixes = WorkoutRoute.fixes(from: [location(verticalAccuracy: -1)])
        let fix = WorkoutRoute.payload(fixes, dateFormatter: ISO8601DateFormatter())[0]
        XCTAssertNil(fix["altitudeM"])
        XCTAssertNil(fix["verticalAccuracyM"])
    }

    func testPayloadIsJSONSerializable() {
        let dense = (0..<50).map { location(lat: 52.52 + Double($0) * metreInDegrees, at: Double($0)) }
        let payload = WorkoutRoute.payload(WorkoutRoute.prepare(dense),
                                           dateFormatter: ISO8601DateFormatter())
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["route": payload]))
    }

    // MARK: - Gesamtkette

    func testPrepareRunsFilterThinningAndSimplification() {
        var input: [CLLocation] = []
        // 5 Hz auf gerader Linie, dazwischen ein unbrauchbarer Fix.
        for i in 0..<50 {
            input.append(location(lat: 52.52 + Double(i) * metreInDegrees,
                                  accuracy: i == 10 ? 300 : 5,
                                  at: Double(i) * 0.2))
        }
        let prepared = WorkoutRoute.prepare(input)
        XCTAssertEqual(prepared.count, 2, "Gerade Strecke schrumpft auf Anfang und Ende")
        XCTAssertEqual(prepared.first?.timestamp, t0)
    }

    func testPrepareOnEmptyInput() {
        XCTAssertTrue(WorkoutRoute.prepare([]).isEmpty)
    }
}
