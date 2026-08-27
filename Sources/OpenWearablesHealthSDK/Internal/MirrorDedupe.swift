import Foundation

// MARK: - Storage

/// Where the ledger keeps what it has already seen. Split out so the dedupe
/// logic can be exercised without `UserDefaults`.
internal protocol MirrorDedupeStorage: AnyObject {
    func loadDedupeState() -> Data?
    func saveDedupeState(_ data: Data?)
}

extension UserDefaults: MirrorDedupeStorage {
    private static let dedupeKey = "com.openwearables.healthsdk.mirrorDedupe"

    internal func loadDedupeState() -> Data? {
        data(forKey: UserDefaults.dedupeKey)
    }

    internal func saveDedupeState(_ data: Data?) {
        set(data, forKey: UserDefaults.dedupeKey)
    }
}

// MARK: - Key

/// Identity of a measurement, independent of which app wrote it into HealthKit.
///
/// Times are held in whole milliseconds and values in millionths, so two
/// samples describing the same measurement produce byte-identical keys instead
/// of two floating point numbers that merely look alike.
internal struct MeasurementKey: Hashable, Codable {
    let type: String
    let start: Int
    let end: Int
    let value: Int

    init(type: String, start: Date, end: Date, value: Double) {
        self.type = type
        self.start = MeasurementKey.milliseconds(start)
        self.end = MeasurementKey.milliseconds(end)
        self.value = Int((value * 1_000_000).rounded())
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate * 1000).rounded())
    }
}

// MARK: - Ledger

/// Drops measurements that another app has mirrored back into HealthKit.
///
/// Companion apps routinely copy a measurement they read from Health back into
/// Health as their own sample: a Withings scale writes a weight, YAZIO reads it
/// and writes an identical one. HealthKit hands both a distinct UUID, so
/// deduplication by sample id — server side or anywhere else — cannot collapse
/// them, and every weigh-in is counted twice.
///
/// What gives them away is that they describe the *same measurement*: same
/// type, same instant, same value. That triple is the key here.
///
/// Two properties matter for not losing data:
///
/// - Only types where a mirrored copy carries no information are considered.
///   Two step samples of equal size at the same second come from the iPhone and
///   the Watch and are genuinely two measurements; body measurements are not.
/// - A key is remembered only once `commit` says the upload was confirmed. A
///   batch that never made it may pass through again unchanged.
internal final class MirrorDedupeLedger {

    /// Body measurements. These arrive from a scale and get mirrored by
    /// whatever nutrition or fitness app is connected to it.
    internal static let bodyMeasurementTypes: Set<String> = [
        HKQuantityTypeIdentifierValue.bodyMass,
        HKQuantityTypeIdentifierValue.bodyMassIndex,
        HKQuantityTypeIdentifierValue.bodyFatPercentage,
        HKQuantityTypeIdentifierValue.leanBodyMass,
        HKQuantityTypeIdentifierValue.height,
        HKQuantityTypeIdentifierValue.waistCircumference
    ]

    /// How far back the ledger remembers. Beyond the sync window a key can no
    /// longer be reached by a query, so keeping it serves no purpose.
    internal static let defaultRetention: TimeInterval = 86_400 * 400

    /// Upper bound on remembered keys. Body measurements accumulate slowly —
    /// a few per day at most — so this is a backstop, not a working limit.
    internal static let defaultCapacity = 20_000

    internal struct Result<T> {
        let kept: [T]
        let newKeys: [MeasurementKey]
    }

    private let types: Set<String>
    private let storage: MirrorDedupeStorage
    private let retention: TimeInterval
    private let capacity: Int
    private let now: () -> Date
    private let lock = NSLock()

    /// Key on the moment it was last confirmed — the date drives pruning.
    private var seen: [MeasurementKey: Date]

    internal init(types: Set<String> = MirrorDedupeLedger.bodyMeasurementTypes,
                  storage: MirrorDedupeStorage,
                  retention: TimeInterval = MirrorDedupeLedger.defaultRetention,
                  capacity: Int = MirrorDedupeLedger.defaultCapacity,
                  now: @escaping () -> Date = Date.init) {
        self.types = types
        self.storage = storage
        self.retention = retention
        self.capacity = capacity
        self.now = now
        self.seen = MirrorDedupeLedger.decode(storage.loadDedupeState())
        prune(at: now())
    }

    /// Sorts a batch into what should be sent and which keys that would claim.
    ///
    /// The keys are handed back rather than recorded: until the upload is
    /// confirmed, nothing may be marked as delivered.
    ///
    /// - Parameter key: The measurement's identity, or `nil` for a sample this
    ///   ledger has no business touching.
    internal func filterMirrored<T>(_ items: [T],
                                    key: (T) -> MeasurementKey?) -> Result<T> {
        lock.lock()
        defer { lock.unlock() }

        var kept: [T] = []
        var newKeys: [MeasurementKey] = []
        /// Mirrors inside a single batch never reach `seen` — they are caught here.
        var inBatch: Set<MeasurementKey> = []

        for item in items {
            guard let candidate = key(item), types.contains(candidate.type) else {
                kept.append(item)
                continue
            }
            guard seen[candidate] == nil, !inBatch.contains(candidate) else { continue }
            inBatch.insert(candidate)
            newKeys.append(candidate)
            kept.append(item)
        }

        return Result(kept: kept, newKeys: newKeys)
    }

    /// Records keys whose upload the server confirmed.
    internal func commit(_ keys: [MeasurementKey], at date: Date? = nil) {
        guard !keys.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        let stamp = date ?? now()
        for key in keys { seen[key] = stamp }
        prune(at: now())
        save()
    }

    /// Forgets everything. Belongs with `resetAnchors()`: after a full
    /// re-export the backend expects the history again, mirrors included —
    /// filtering it against an old ledger would silently thin it out.
    internal func reset() {
        lock.lock()
        defer { lock.unlock() }
        seen = [:]
        storage.saveDedupeState(nil)
    }

    /// Forgets the given types only.
    ///
    /// Needed because anchors can be reset per type from outside the SDK. A
    /// type whose history is about to be fetched again must not be measured
    /// against what the previous run delivered — everything would look like a
    /// mirror and nothing would be sent.
    internal func forget(types identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        seen = seen.filter { !identifiers.contains($0.key.type) }
        save()
    }

    internal var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    // MARK: - Housekeeping

    private func prune(at date: Date) {
        let cutoff = date.addingTimeInterval(-retention)
        seen = seen.filter { $0.value >= cutoff }

        guard seen.count > capacity else { return }
        let survivors = seen.sorted { $0.value > $1.value }.prefix(capacity)
        seen = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private func save() {
        let entries = seen.map { Entry(key: $0.key, seenAt: $0.value) }
        storage.saveDedupeState(try? JSONEncoder().encode(entries))
    }

    private struct Entry: Codable {
        let key: MeasurementKey
        let seenAt: Date
    }

    private static func decode(_ data: Data?) -> [MeasurementKey: Date] {
        guard let data,
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }
        return Dictionary(entries.map { ($0.key, $0.seenAt) },
                          uniquingKeysWith: { max($0, $1) })
    }
}

// MARK: - Identifiers

/// The raw identifier strings, spelled out so this file stays free of HealthKit
/// and the ledger remains testable on its own.
private enum HKQuantityTypeIdentifierValue {
    static let bodyMass = "HKQuantityTypeIdentifierBodyMass"
    static let bodyMassIndex = "HKQuantityTypeIdentifierBodyMassIndex"
    static let bodyFatPercentage = "HKQuantityTypeIdentifierBodyFatPercentage"
    static let leanBodyMass = "HKQuantityTypeIdentifierLeanBodyMass"
    static let height = "HKQuantityTypeIdentifierHeight"
    static let waistCircumference = "HKQuantityTypeIdentifierWaistCircumference"
}
