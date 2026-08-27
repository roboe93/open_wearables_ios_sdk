import XCTest
@testable import OpenWearablesHealthSDK

/// In-memory stand-in for `UserDefaults`.
private final class MemoryStorage: MirrorDedupeStorage {
    var data: Data?
    func loadDedupeState() -> Data? { data }
    func saveDedupeState(_ newValue: Data?) { data = newValue }
}

/// A measurement as it reaches the ledger — mirrors what an `HKQuantitySample`
/// contributes, without depending on HealthKit in the test.
private struct Measurement {
    let type: String
    let start: Date
    let end: Date
    let value: Double
    /// Distinct per sample, exactly as HealthKit hands out distinct UUIDs to a
    /// mirrored copy. Only used to tell the two apart in assertions.
    let tag: String
}

final class MirrorDedupeLedgerTests: XCTestCase {

    private let weight = "HKQuantityTypeIdentifierBodyMass"
    private let steps = "HKQuantityTypeIdentifierStepCount"
    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func ledger(_ storage: MemoryStorage,
                        types: Set<String>? = nil) -> MirrorDedupeLedger {
        MirrorDedupeLedger(types: types ?? [weight], storage: storage)
    }

    private func key(_ m: Measurement) -> MeasurementKey? {
        MeasurementKey(type: m.type, start: m.start, end: m.end, value: m.value)
    }

    private func split(_ ledger: MirrorDedupeLedger,
                       _ items: [Measurement]) -> (kept: [String], keys: [MeasurementKey]) {
        let result = ledger.filterMirrored(items, key: key)
        return (result.kept.map(\.tag), result.newKeys)
    }

    private func measurement(_ tag: String, type: String? = nil,
                             offset: TimeInterval = 0, value: Double = 108.955) -> Measurement {
        let start = epoch.addingTimeInterval(offset)
        return Measurement(type: type ?? weight, start: start, end: start,
                           value: value, tag: tag)
    }

    // MARK: - Der eigentliche Befund

    func testKeepsOnlyOneOfTwoIdenticalMeasurementsFromDifferentApps() {
        let ledger = ledger(MemoryStorage())
        let (kept, _) = split(ledger, [measurement("withings"), measurement("yazio")])
        XCTAssertEqual(kept, ["withings"])
    }

    func testDropsMirrorThatArrivesInALaterBatch() {
        let storage = MemoryStorage()
        let first = ledger(storage)
        let (keptFirst, keys) = split(first, [measurement("withings")])
        XCTAssertEqual(keptFirst, ["withings"])
        first.commit(keys, at: epoch)

        // Neue Instanz: der Stand muss die Runde überleben.
        let second = ledger(storage)
        let (keptSecond, _) = split(second, [measurement("yazio")])
        XCTAssertEqual(keptSecond, [])
    }

    // MARK: - Was nicht zusammenfallen darf

    func testKeepsSameTimestampWithDifferentValues() {
        let ledger = ledger(MemoryStorage())
        let (kept, _) = split(ledger, [measurement("a", value: 108.955),
                                       measurement("b", value: 108.956)])
        XCTAssertEqual(kept, ["a", "b"])
    }

    func testKeepsSameValueAtDifferentTimestamps() {
        let ledger = ledger(MemoryStorage())
        let (kept, _) = split(ledger, [measurement("a"), measurement("b", offset: 1)])
        XCTAssertEqual(kept, ["a", "b"])
    }

    func testLeavesTypesOutsideTheDedupeSetUntouched() {
        let ledger = ledger(MemoryStorage())
        let (kept, keys) = split(ledger, [measurement("phone", type: steps, value: 10),
                                          measurement("watch", type: steps, value: 10)])
        XCTAssertEqual(kept, ["phone", "watch"])
        XCTAssertTrue(keys.isEmpty, "Fremde Typen gehören nicht ins Gedächtnis")
    }

    // MARK: - Nur bestätigte Übertragungen zählen

    func testUncommittedBatchPassesThroughAgain() {
        let storage = MemoryStorage()
        let first = ledger(storage)
        _ = split(first, [measurement("withings")])   // Upload scheitert: kein commit

        let second = ledger(storage)
        let (kept, _) = split(second, [measurement("withings")])
        XCTAssertEqual(kept, ["withings"], "Ohne Bestätigung darf nichts verloren gehen")
    }

    // MARK: - Der Stand darf nicht unbegrenzt wachsen

    func testForgetsEntriesOlderThanRetention() {
        let storage = MemoryStorage()
        let old = MirrorDedupeLedger(types: [weight], storage: storage,
                                     retention: 100, capacity: 1000)
        let (_, keys) = split(old, [measurement("withings")])
        old.commit(keys, at: epoch)

        let later = MirrorDedupeLedger(types: [weight], storage: storage,
                                       retention: 100, capacity: 1000,
                                       now: { self.epoch.addingTimeInterval(200) })
        let (kept, _) = split(later, [measurement("yazio")])
        XCTAssertEqual(kept, ["yazio"], "Alte Schlüssel werden vergessen")
    }

    func testKeepsNewestEntriesWhenCapacityIsExceeded() {
        let storage = MemoryStorage()
        let ledger = MirrorDedupeLedger(types: [weight], storage: storage,
                                        retention: 86_400 * 400, capacity: 2)
        for i in 0..<3 {
            let m = measurement("m\(i)", offset: TimeInterval(i))
            let (_, keys) = split(ledger, [m])
            ledger.commit(keys, at: epoch.addingTimeInterval(TimeInterval(i)))
        }
        let fresh = MirrorDedupeLedger(types: [weight], storage: storage,
                                       retention: 86_400 * 400, capacity: 2)
        let (kept, _) = split(fresh, [measurement("m0-mirror", offset: 0),
                                      measurement("m2-mirror", offset: 2)])
        XCTAssertEqual(kept, ["m0-mirror"], "Der älteste Schlüssel fiel aus der Obergrenze")
    }
}

// MARK: - Zurücksetzen von aussen

extension MirrorDedupeLedgerTests {

    func testForgettingATypeLetsItsHistoryThroughAgain() {
        let storage = MemoryStorage()
        let ledger = MirrorDedupeLedger(types: [weight, steps], storage: storage)
        let (_, keys) = split(ledger, [measurement("withings"),
                                       measurement("phone", type: steps, value: 10)])
        ledger.commit(keys, at: epoch)

        ledger.forget(types: [weight])

        let (kept, _) = split(ledger, [measurement("withings-again"),
                                       measurement("phone-again", type: steps, value: 10)])
        XCTAssertEqual(kept, ["withings-again"],
                       "Gewicht wieder frei, Schritte weiter gesperrt")
    }

    func testResetForgetsEverything() {
        let storage = MemoryStorage()
        let ledger = MirrorDedupeLedger(types: [weight], storage: storage)
        let (_, keys) = split(ledger, [measurement("withings")])
        ledger.commit(keys, at: epoch)
        XCTAssertEqual(ledger.count, 1)

        ledger.reset()

        let (kept, _) = split(ledger, [measurement("withings-again")])
        XCTAssertEqual(kept, ["withings-again"])
        XCTAssertNil(storage.data, "Auch die Ablage muss leer sein")
    }
}
