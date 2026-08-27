import Foundation
import CoreLocation

/// One GPS fix of a workout route, ready to be serialized.
internal struct RouteFix: Equatable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    /// `nil` when CoreLocation had no usable altitude for this fix.
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
}

/// Turns the locations of an `HKWorkoutRoute` into what the backend stores.
///
/// Three things happen on the way, and each of them is here rather than on the
/// server because the phone is where the cost lands: a one-hour run recorded at
/// the rate HealthKit hands out is a few hundred kilobytes of JSON, and a
/// backfill over months is a multiple of that.
///
/// - Fixes too inaccurate to place on a map are dropped.
/// - What is left is thinned to roughly one fix per second.
/// - Douglas-Peucker then removes every point that lies within a few metres of
///   the line its neighbours already describe. On a map the result is the same
///   track; the point count typically halves.
///
/// Coordinates are never rounded. The backend keeps them at full precision, and
/// three decimal places — what its generic numeric columns would give — is about
/// 110 m, which turns a route into a staircase.
internal enum WorkoutRoute {

    /// Beyond this a fix says little about where someone was. The backend
    /// discards anything over 100 m anyway; filtering earlier saves the bytes.
    internal static let maxHorizontalAccuracy: CLLocationAccuracy = 50

    /// Target spacing. Faster than this adds bytes, not information.
    internal static let minimumInterval: TimeInterval = 1

    /// How far a point may sit from the line between its neighbours before it
    /// counts as a corner. Below a few metres nothing is visible on a map.
    internal static let simplificationTolerance: CLLocationDistance = 2.5

    // MARK: - Pipeline

    /// The whole chain: read, thin, simplify.
    internal static func prepare(_ locations: [CLLocation]) -> [RouteFix] {
        simplify(downsample(fixes(from: locations), minimumInterval: minimumInterval),
                 toleranceMeters: simplificationTolerance)
    }

    /// Usable fixes in chronological order.
    ///
    /// A route can arrive as several samples — one per pause — so the order
    /// HealthKit hands them out is not necessarily the order they were run in.
    internal static func fixes(from locations: [CLLocation]) -> [RouteFix] {
        locations
            .filter { isUsable($0) }
            .sorted { $0.timestamp < $1.timestamp }
            .map { location in
                // CoreLocation signals "no altitude" with a negative vertical
                // accuracy; the altitude field then holds 0, not a height.
                let hasAltitude = location.verticalAccuracy > 0
                return RouteFix(timestamp: location.timestamp,
                                latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude,
                                altitude: hasAltitude ? location.altitude : nil,
                                horizontalAccuracy: location.horizontalAccuracy,
                                verticalAccuracy: hasAltitude ? location.verticalAccuracy : nil)
            }
    }

    /// Keeps the first fix and then only those far enough apart in time.
    internal static func downsample(_ fixes: [RouteFix],
                                    minimumInterval: TimeInterval) -> [RouteFix] {
        guard minimumInterval > 0, let first = fixes.first else { return fixes }

        var kept: [RouteFix] = [first]
        var last = first.timestamp
        for fix in fixes.dropFirst() {
            guard fix.timestamp.timeIntervalSince(last) >= minimumInterval else { continue }
            kept.append(fix)
            last = fix.timestamp
        }
        // The end of a route is where it stops, which a fixed grid would cut off.
        if let final = fixes.last, kept.last != final { kept.append(final) }
        return kept
    }

    /// Douglas-Peucker: drops every point closer to the line between the kept
    /// endpoints than `toleranceMeters`. First and last always survive.
    internal static func simplify(_ fixes: [RouteFix],
                                  toleranceMeters: CLLocationDistance) -> [RouteFix] {
        guard fixes.count > 2, toleranceMeters > 0 else { return fixes }

        // Metres relative to the first fix. Over the span of a workout the
        // error of this projection is far below the tolerance.
        let origin = fixes[0]
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(origin.latitude * .pi / 180)
        let points: [(x: Double, y: Double)] = fixes.map {
            ((($0.longitude - origin.longitude) * lonScale),
             (($0.latitude - origin.latitude) * latScale))
        }

        var keep = [Bool](repeating: false, count: fixes.count)
        keep[0] = true
        keep[fixes.count - 1] = true

        // Explicit stack rather than recursion: a long route would otherwise
        // nest thousands of frames deep.
        var stack: [(Int, Int)] = [(0, fixes.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }

            var farthest = start
            var maxDistance = 0.0
            for index in (start + 1)..<end {
                let distance = perpendicularDistance(points[index],
                                                     from: points[start], to: points[end])
                if distance > maxDistance {
                    maxDistance = distance
                    farthest = index
                }
            }

            guard maxDistance > toleranceMeters else { continue }
            keep[farthest] = true
            stack.append((start, farthest))
            stack.append((farthest, end))
        }

        return zip(fixes, keep).compactMap { $1 ? $0 : nil }
    }

    // MARK: - Serialization

    /// The shape the backend reads. Optional values are left out rather than
    /// sent as null — a missing altitude is not an altitude of zero.
    internal static func payload(_ fixes: [RouteFix],
                                 dateFormatter: ISO8601DateFormatter) -> [[String: Any]] {
        fixes.map { fix in
            var entry: [String: Any] = [
                "timestamp": dateFormatter.string(from: fix.timestamp),
                "latitude": fix.latitude,
                "longitude": fix.longitude
            ]
            if let altitude = fix.altitude { entry["altitudeM"] = altitude }
            if let horizontal = fix.horizontalAccuracy { entry["horizontalAccuracyM"] = horizontal }
            if let vertical = fix.verticalAccuracy { entry["verticalAccuracyM"] = vertical }
            return entry
        }
    }

    // MARK: - Helpers

    private static func isUsable(_ location: CLLocation) -> Bool {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return false }
        // A negative accuracy means the fix is invalid, not that it is precise.
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxHorizontalAccuracy else { return false }
        return true
    }

    private static func perpendicularDistance(_ point: (x: Double, y: Double),
                                              from start: (x: Double, y: Double),
                                              to end: (x: Double, y: Double)) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            // Start and end coincide — a loop that returns to its origin.
            return hypot(point.x - start.x, point.y - start.y)
        }

        let cross = abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x)
        return cross / sqrt(lengthSquared)
    }
}
