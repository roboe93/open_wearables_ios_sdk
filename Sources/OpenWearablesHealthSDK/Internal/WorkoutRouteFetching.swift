import Foundation
import HealthKit
import CoreLocation

extension OpenWearablesHealthSDK {

    /// The route type. Not covered by workout authorization — it is a series
    /// type of its own and has to be asked for separately.
    internal static var workoutRouteType: HKSeriesType { HKSeriesType.workoutRoute() }

    /// Routes for the given workouts, keyed by workout id.
    ///
    /// Workouts without a route — everything indoors — simply do not appear in
    /// the result. That is the normal case, not a failure.
    ///
    /// Sequential on purpose: a single route can be thousands of locations, and
    /// running every workout of a round at once would hold all of them in
    /// memory at the same time.
    internal func collectRoutes(for workouts: [HKWorkout],
                                completion: @escaping ([UUID: [RouteFix]]) -> Void) {
        guard !workouts.isEmpty else { completion([:]); return }
        collectRoutes(for: workouts, index: 0, collected: [:], completion: completion)
    }

    private func collectRoutes(for workouts: [HKWorkout], index: Int,
                               collected: [UUID: [RouteFix]],
                               completion: @escaping ([UUID: [RouteFix]]) -> Void) {
        guard index < workouts.count else { completion(collected); return }

        let workout = workouts[index]
        route(for: workout) { [weak self] fixes in
            guard let self = self else { completion(collected); return }

            var next = collected
            if !fixes.isEmpty { next[workout.uuid] = fixes }
            self.collectRoutes(for: workouts, index: index + 1,
                               collected: next, completion: completion)
        }
    }

    /// Every location of one workout, thinned and simplified.
    private func route(for workout: HKWorkout,
                       completion: @escaping ([RouteFix]) -> Void) {
        let query = HKAnchoredObjectQuery(
            type: Self.workoutRouteType,
            predicate: HKQuery.predicateForObjects(from: workout),
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, error in
            guard let self = self else { completion([]); return }

            if let error = error {
                // A missing authorization looks like an error here. Either way
                // the workout goes out without a route rather than not at all.
                self.logMessage("  route: \(error.localizedDescription) - skipping")
                completion([])
                return
            }

            // Pause and resume produce one route sample each.
            let routes = (samples as? [HKWorkoutRoute] ?? [])
                .sorted { $0.startDate < $1.startDate }
            guard !routes.isEmpty else { completion([]); return }

            self.locations(in: routes, index: 0, collected: []) { locations in
                completion(WorkoutRoute.prepare(locations))
            }
        }

        healthStore.execute(query)
    }

    private func locations(in routes: [HKWorkoutRoute], index: Int,
                           collected: [CLLocation],
                           completion: @escaping ([CLLocation]) -> Void) {
        guard index < routes.count else { completion(collected); return }

        locations(in: routes[index]) { [weak self] batch in
            guard let self = self else { completion(collected); return }
            self.locations(in: routes, index: index + 1,
                           collected: collected + batch, completion: completion)
        }
    }

    /// One route sample.
    ///
    /// `HKWorkoutRouteQuery` calls back repeatedly with slices of the track.
    /// Finishing on the first callback would cut the route short — only
    /// `done == true` means everything has arrived.
    private func locations(in route: HKWorkoutRoute,
                           completion: @escaping ([CLLocation]) -> Void) {
        var accumulated: [CLLocation] = []
        var finished = false

        let query = HKWorkoutRouteQuery(route: route) { [weak self] query, locations, done, error in
            guard !finished else { return }

            if let error = error {
                finished = true
                self?.healthStore.stop(query)
                self?.logMessage("  route locations: \(error.localizedDescription) - partial")
                completion(accumulated)
                return
            }

            accumulated.append(contentsOf: locations ?? [])

            guard done else { return }
            finished = true
            completion(accumulated)
        }

        healthStore.execute(query)
    }
}
