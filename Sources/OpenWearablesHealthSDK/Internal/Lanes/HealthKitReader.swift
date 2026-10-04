import Foundation
import HealthKit

// Fork-Zusatz (roboe93), Plan 05-07. Der HealthKit-Leser der Zwei-Spuren-Steuerung.
//
// Er erfüllt `HealthReading` (LaneContracts) mit echten Abfragen. Politik (Reihenfolge,
// Priorität, Frist, Parken) liegt im Kern, hier steht nur das Lesen. Der Leser ist nur am Gerät
// prüfbar (Spike S1, Plan 05-10): HealthKit liefert im Test keine Samples. Geprüft wird hier,
// dass er übersetzt, Typen richtig auflöst und bei einem unbekannten Typ ohne Abfrage scheitert.
//
// Je Zyklus ein Leser: die Generation des Laufs gehört dem Durchlauf für den Anchor "jetzt"
// (Lebenszeichen an die Lease, siehe `captureAnchorStep`).

final class HealthKitReader: HealthReading {
    typealias Item = HKSample

    /// Wie viele Samples ein Schritt des Durchlaufs für den Anchor "jetzt" liest (wie in 0.15).
    static let anchorPassLimit = 10_000

    private weak var sdk: OpenWearablesHealthSDK?
    private let generation: Int

    init(sdk: OpenWearablesHealthSDK, generation: Int) {
        self.sdk = sdk
        self.generation = generation
    }

    // MARK: Typen

    /// Der abfragbare Typ zu einem Identifier. `nil` für alles, was nicht in `getQueryableTypes()`
    /// steht (nicht verfolgt, Blutdruck, Workout-Route): der Leser fragt nie einen Typ ab, den die
    /// Verfolgung nicht kennt.
    internal func resolveType(_ typeId: String) -> HKSampleType? {
        sdk?.getQueryableTypes().first { $0.identifier == typeId }
    }

    func identity(of item: HKSample) -> (id: String, endDate: Date) {
        (item.uuid.uuidString, item.endDate)
    }

    // MARK: Live-Spur

    /// Samples und Löschungen seit `anchor`, ohne Datumsgrenze (löst D9). Das ist nur für Typen
    /// mit Anchor zulässig, ein Typ ohne Anchor würde die ganze Historie von vorn lesen
    /// (Pitfall 4, T-05-28). Dafür sorgt der Kern: er bootstrappt zuerst.
    func fetchLive(
        typeId: String, anchor: AnchorToken, limit: Int,
        completion: @escaping (Result<LiveChunk<HKSample>, ReadFailure>) -> Void
    ) {
        guard let sdk = sdk, let type = resolveType(typeId) else {
            completion(.failure(.other("unknown type")))
            return
        }
        // Nur Secure Coding (T-05-27). Ein Anchor, der sich nicht lesen lässt, heißt nie "ohne
        // Anchor": der Typ würde sonst die Historie neu lesen.
        guard let queryAnchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor) else {
            completion(.failure(.other("anchor unreadable")))
            return
        }
        let limit = max(1, limit)

        let query = HKAnchoredObjectQuery(
            type: type, predicate: nil, anchor: queryAnchor, limit: limit
        ) { [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            autoreleasepool {
                guard let self = self, let sdk = self.sdk else {
                    completion(.failure(.other("sdk released")))
                    return
                }
                if let error = error {
                    completion(.failure(self.failure(for: error, sdk: sdk)))
                    return
                }

                let samples = samplesOrNil ?? []
                // `deletedObjects` (HKDeletedObject) tragen nur uuid und Metadaten: daraus wird eine DeletedRef.
                let deleted = (deletedObjects ?? []).map { DeletedRef(id: $0.uuid.uuidString, type: typeId) }

                let token: AnchorToken
                if let newAnchor = newAnchor {
                    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) else {
                        completion(.failure(.other("anchor archive")))
                        return
                    }
                    token = data
                } else if samples.isEmpty && deleted.isEmpty {
                    // Nichts Neues und kein neuer Anchor: der alte gilt weiter, der Kern schreibt nichts.
                    token = anchor
                } else {
                    // Daten ohne Anchor dahinter: nie erneut lesen lassen, nie raten.
                    completion(.failure(.other("anchor missing")))
                    return
                }

                // Gelöschte zählen gegen das Limit (0.14-Regel): ein Chunk aus Samples und Löschungen
                // sah sonst wie der letzte aus, und der Anchor für den Rest rückte nie vor.
                let hasMore = samples.count + deleted.count >= limit
                completion(.success(LiveChunk(
                    typeId: typeId, items: samples, deleted: deleted, newAnchor: token, hasMore: hasMore
                )))
            }
        }
        sdk.healthStore.execute(query)
    }

    // MARK: Nachholen

    /// Samples mit `endDate` in `[floor, upTo]`, beide Grenzen inklusiv, neuestes zuerst.
    func fetchWindow(
        typeId: String, floor: Date, upTo: Date, limit: Int,
        completion: @escaping (Result<WindowChunk<HKSample>, ReadFailure>) -> Void
    ) {
        guard let sdk = sdk, let type = resolveType(typeId) else {
            completion(.failure(.other("unknown type")))
            return
        }
        let limit = max(1, limit)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: type,
            predicate: Self.windowPredicate(floor: floor, upTo: upTo),
            limit: limit,
            sortDescriptors: [sort]
        ) { [weak self] _, samplesOrNil, error in
            autoreleasepool {
                guard let self = self, let sdk = self.sdk else {
                    completion(.failure(.other("sdk released")))
                    return
                }
                if let error = error {
                    completion(.failure(self.failure(for: error, sdk: sdk)))
                    return
                }
                let samples = samplesOrNil ?? []
                completion(.success(WindowChunk(typeId: typeId, items: samples, hasMore: samples.count == limit)))
            }
        }
        sdk.healthStore.execute(query)
    }

    /// `endDate >= floor AND endDate <= upTo`. Ausdrücklich statt `predicateForSamples(withStart:end:)`:
    /// die Grenzen sind dort nicht als inklusiv dokumentiert, der Kern verlässt sich aber darauf
    /// (ein Sample genau auf dem Rand wird über die Kennung der Grenze gefiltert, nicht ausgelassen).
    internal static func windowPredicate(floor: Date, upTo: Date) -> NSPredicate {
        NSPredicate(
            format: "%K >= %@ AND %K <= %@",
            HKPredicateKeyPathEndDate, floor as NSDate,
            HKPredicateKeyPathEndDate, upTo as NSDate
        )
    }

    // MARK: Anchor für "jetzt"

    /// Standard: der Durchlauf über `captureAnchorStep` (Limit 10.000, ohne Upload, wie 0.15). Er
    /// braucht bei dichten Typen Sekunden bis Minuten, ist aber am Gerät belegt.
    ///
    /// Nur mit dem Schalter `lanes.anchorProbe` die Sonde (A1, Spike S1 entscheidet): eine
    /// Anchored Query, deren Prädikat nichts trifft, soll den aktuellen Anchor des Typs liefern.
    /// Liefert die Sonde etwas anderes als erwartet (Samples, kein Anchor, ein Fehler außer
    /// "gesperrt"), fällt der Leser auf den Durchlauf zurück statt einen Anchor zu raten.
    func currentAnchor(typeId: String, completion: @escaping (Result<AnchorToken, ReadFailure>) -> Void) {
        guard let sdk = sdk, let type = resolveType(typeId) else {
            completion(.failure(.other("unknown type")))
            return
        }
        guard sdk.lanesAnchorProbe else {
            anchorByPass(type: type, completion: completion)
            return
        }
        anchorByProbe(type: type) { [weak self] result in
            guard let self = self else { completion(result); return }
            switch result {
            case .success, .failure(.locked):
                completion(result)
            case .failure(.other(let reason)):
                self.sdk?.logMessage("\(typeId): anchor probe unusable (\(reason)) - falling back to the pass")
                self.anchorByPass(type: type, completion: completion)
            }
        }
    }

    private func anchorByPass(
        type: HKSampleType, completion: @escaping (Result<AnchorToken, ReadFailure>) -> Void
    ) {
        guard let sdk = sdk else { completion(.failure(.other("sdk released"))); return }
        // `onError` und `completion` laufen nacheinander im selben Rückruf.
        let captured = CapturedError()
        sdk.captureAnchorStep(
            type: type, anchor: nil, limit: Self.anchorPassLimit, generation: generation,
            onError: { captured.error = $0 }
        ) { [weak self] anchor in
            guard let self = self, let sdk = self.sdk else {
                completion(.failure(.other("sdk released")))
                return
            }
            if let error = captured.error {
                completion(.failure(self.failure(for: error, sdk: sdk)))
                return
            }
            guard let anchor = anchor else {
                completion(.failure(.other("anchor missing")))
                return
            }
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
                completion(.failure(.other("anchor archive")))
                return
            }
            completion(.success(data))
        }
    }

    private func anchorByProbe(
        type: HKSampleType, completion: @escaping (Result<AnchorToken, ReadFailure>) -> Void
    ) {
        guard let sdk = sdk else { completion(.failure(.other("sdk released"))); return }
        sdk.heartbeat(generation: generation)

        // Ein Prädikat, das nie trifft: keine Samples, nur der Anchor.
        let never = HKQuery.predicateForSamples(withStart: .distantFuture, end: nil, options: [])
        let query = HKAnchoredObjectQuery(
            type: type, predicate: never, anchor: nil, limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, deleted, newAnchor, error in
            guard let self = self, let sdk = self.sdk else {
                completion(.failure(.other("sdk released")))
                return
            }
            if let error = error {
                completion(.failure(self.failure(for: error, sdk: sdk)))
                return
            }
            guard (samples ?? []).isEmpty, (deleted ?? []).isEmpty else {
                completion(.failure(.other("probe returned data")))
                return
            }
            guard let newAnchor = newAnchor,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) else {
                completion(.failure(.other("probe returned no anchor")))
                return
            }
            completion(.success(data))
        }
        sdk.healthStore.execute(query)
    }

    // MARK: Fehler

    /// Gesperrt oder sonstiger Fehler. Der Text enthält nur Fehlerdomäne und Code, keine Werte.
    private func failure(for error: Error, sdk: OpenWearablesHealthSDK) -> ReadFailure {
        if sdk.isProtectedDataError(error) { return .locked }
        let nsError = error as NSError
        return .other("healthkit(\(nsError.domain)#\(nsError.code))")
    }

    private final class CapturedError {
        var error: Error?
    }
}
