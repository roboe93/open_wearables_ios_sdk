import XCTest
@testable import OpenWearablesHealthSDK

// Fakes für den Steuerungskern (Plan 05-06, D-14). Alles ohne HealthKit: der Kern ist generisch
// über den Sample-Typ. Die Fakes antworten synchron; der Kern springt bei jedem Rückruf auf seine
// eigene Queue und läuft dadurch ohne Rekursion durch.

/// Geordnetes Ereignisprotokoll: Lieferung, Warteschlange, Commit und Parken schreiben hinein,
/// damit Tests die Reihenfolge prüfen können (Commit nach Annahme, Löschung vor Anchor).
final class EventLog {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ event: String) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// Position des ersten Ereignisses mit diesem Präfix, optional erst nach einer Position.
    func index(ofPrefix prefix: String, after position: Int = -1) -> Int? {
        events.enumerated().first { $0.offset > position && $0.element.hasPrefix(prefix) }?.offset
    }

    func count(ofPrefix prefix: String) -> Int {
        events.filter { $0.hasPrefix(prefix) }.count
    }
}

struct FakeSample: Equatable {
    let id: String
    let typeId: String
    var endDate: Date
    /// Einfügereihenfolge, vergibt `FakeReader.insert`. Sie ist der Anchor.
    var insertion: Int = 0
}

final class FakeReader: HealthReading {
    typealias Item = FakeSample

    private let lock = NSLock()
    private var samples: [FakeSample] = []
    private var deletions: [(typeId: String, ref: DeletedRef, insertion: Int)] = []
    private var counter = 0

    /// Für diese Typen antworten alle Abfragen mit `.locked`.
    var lockedTypes: Set<String> = []
    /// Für diese Typen antworten Abfragen mit `.other(Text)`.
    var failingTypes: [String: String] = [:]
    /// Nur `currentAnchor` scheitert (`.other`).
    var failingAnchorTypes: Set<String> = []
    /// Für diese Typen kehrt `fetchLive` nie zurück, bis `releaseHung()` es auflöst.
    var hangingTypes: Set<String> = []

    var onFetchLive: ((String) -> Void)?
    var onFetchWindow: ((String) -> Void)?
    var onCurrentAnchor: ((String) -> Void)?

    private(set) var liveCalls: [(typeId: String, anchor: Int, limit: Int)] = []
    private(set) var windowCalls: [(typeId: String, floor: Date, upTo: Date, limit: Int)] = []
    private(set) var anchorCalls: [String] = []
    private var hung: [(typeId: String, anchor: AnchorToken, completion: (Result<LiveChunk<FakeSample>, ReadFailure>) -> Void)] = []

    var totalCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveCalls.count + windowCalls.count + anchorCalls.count
    }

    static func token(_ value: Int) -> AnchorToken { Data(String(value).utf8) }

    static func value(of token: AnchorToken) -> Int { Int(String(decoding: token, as: UTF8.self)) ?? 0 }

    @discardableResult
    func insert(_ typeId: String, id: String, endDate: Date) -> FakeSample {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        let sample = FakeSample(id: id, typeId: typeId, endDate: endDate, insertion: counter)
        samples.append(sample)
        return sample
    }

    func insertDeletion(typeId: String, id: String) {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        deletions.append((typeId, DeletedRef(id: id, type: typeId), counter))
    }

    /// Der Anchor, der "jetzt" für einen Typ gilt: die jüngste Einfügung dieses Typs.
    func anchorValue(for typeId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let latestSample = samples.filter { $0.typeId == typeId }.map { $0.insertion }.max() ?? 0
        let latestDeletion = deletions.filter { $0.typeId == typeId }.map { $0.insertion }.max() ?? 0
        return max(latestSample, latestDeletion)
    }

    func identity(of item: FakeSample) -> (id: String, endDate: Date) {
        (item.id, item.endDate)
    }

    func fetchLive(
        typeId: String, anchor: AnchorToken, limit: Int,
        completion: @escaping (Result<LiveChunk<FakeSample>, ReadFailure>) -> Void
    ) {
        lock.lock()
        liveCalls.append((typeId, FakeReader.value(of: anchor), limit))
        let hangs = hangingTypes.contains(typeId)
        if hangs { hung.append((typeId, anchor, completion)) }
        lock.unlock()

        onFetchLive?(typeId)
        if hangs { return }
        completion(liveResult(typeId: typeId, anchor: anchor, limit: limit))
    }

    /// Löst alle hängenden Abfragen mit dem, was inzwischen vorliegt.
    func releaseHung() {
        lock.lock()
        let pending = hung
        hung = []
        hangingTypes = []
        lock.unlock()
        for call in pending {
            call.completion(liveResult(typeId: call.typeId, anchor: call.anchor, limit: 100))
        }
    }

    private func liveResult(typeId: String, anchor: AnchorToken, limit: Int) -> Result<LiveChunk<FakeSample>, ReadFailure> {
        lock.lock()
        defer { lock.unlock() }
        if lockedTypes.contains(typeId) { return .failure(.locked) }
        if let text = failingTypes[typeId] { return .failure(.other(text)) }

        enum Entry { case sample(FakeSample), deletion(DeletedRef) }
        let after = FakeReader.value(of: anchor)
        var entries: [(insertion: Int, entry: Entry)] = []
        for sample in samples where sample.typeId == typeId && sample.insertion > after {
            entries.append((sample.insertion, .sample(sample)))
        }
        for deletion in deletions where deletion.typeId == typeId && deletion.insertion > after {
            entries.append((deletion.insertion, .deletion(deletion.ref)))
        }
        entries.sort { $0.insertion < $1.insertion }

        let taken = Array(entries.prefix(limit))
        var items: [FakeSample] = []
        var deleted: [DeletedRef] = []
        for item in taken {
            switch item.entry {
            case .sample(let sample): items.append(sample)
            case .deletion(let ref): deleted.append(ref)
            }
        }
        let newAnchor = taken.last.map { FakeReader.token($0.insertion) } ?? anchor
        return .success(LiveChunk(
            typeId: typeId, items: items, deleted: deleted,
            newAnchor: newAnchor, hasMore: entries.count > limit
        ))
    }

    func fetchWindow(
        typeId: String, floor: Date, upTo: Date, limit: Int,
        completion: @escaping (Result<WindowChunk<FakeSample>, ReadFailure>) -> Void
    ) {
        lock.lock()
        windowCalls.append((typeId, floor, upTo, limit))
        lock.unlock()

        onFetchWindow?(typeId)

        completion(windowResult(typeId: typeId, floor: floor, upTo: upTo, limit: limit))
    }

    private func windowResult(typeId: String, floor: Date, upTo: Date, limit: Int) -> Result<WindowChunk<FakeSample>, ReadFailure> {
        lock.lock()
        defer { lock.unlock() }
        if lockedTypes.contains(typeId) { return .failure(.locked) }
        if let text = failingTypes[typeId] { return .failure(.other(text)) }

        // Neuestes zuerst; bei gleichem Zeitpunkt nach Kennung, damit die Reihenfolge stabil ist.
        let inWindow = samples
            .filter { $0.typeId == typeId && $0.endDate >= floor && $0.endDate <= upTo }
            .sorted { $0.endDate != $1.endDate ? $0.endDate > $1.endDate : $0.id < $1.id }
        return .success(WindowChunk(
            typeId: typeId, items: Array(inWindow.prefix(limit)), hasMore: inWindow.count > limit
        ))
    }

    func currentAnchor(typeId: String, completion: @escaping (Result<AnchorToken, ReadFailure>) -> Void) {
        lock.lock()
        anchorCalls.append(typeId)
        lock.unlock()

        onCurrentAnchor?(typeId)

        if lockedTypes.contains(typeId) { completion(.failure(.locked)); return }
        if failingAnchorTypes.contains(typeId) || failingTypes[typeId] != nil {
            completion(.failure(.other("anchor")))
            return
        }
        completion(.success(FakeReader.token(anchorValue(for: typeId))))
    }
}

struct FakeDelivery: Equatable {
    let index: Int
    let lane: Lane
    /// Typen in der Reihenfolge ihres ersten Auftretens.
    let typeIds: [String]
    let ids: [String]
    let deleted: [DeletedRef]

    var count: Int { ids.count }
}

final class FakeSink: Delivering {
    typealias Item = FakeSample

    private let lock = NSLock()
    private let log: EventLog
    private var recorded: [FakeDelivery] = []

    /// Ob die Antwort `accepted` die Löschungen als gesendet meldet.
    var sendsDeletions = false
    /// Antwortskript. Ohne Skript nimmt der Sink an.
    var responder: ((FakeDelivery) -> DeliveryResult)?
    /// Läuft in `deliver`, bevor geantwortet wird. Hier greifen Tests ein (Einfügen, Abbrechen).
    var onDeliver: ((FakeDelivery) -> Void)?

    init(log: EventLog) { self.log = log }

    var deliveries: [FakeDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Weist jede Lieferung ab, für die `predicate` gilt, alle anderen nimmt er an.
    func rejectWhen(status: Int = 422, _ predicate: @escaping (FakeDelivery) -> Bool) {
        responder = { [unowned self] delivery in
            predicate(delivery) ? .rejected(httpStatus: status) : .accepted(sentDeleted: self.sendsDeletions)
        }
    }

    func deliver(
        _ items: [FakeSample], deleted: [DeletedRef], lane: Lane,
        completion: @escaping (DeliveryResult) -> Void
    ) {
        var typeIds: [String] = []
        for item in items where !typeIds.contains(item.typeId) { typeIds.append(item.typeId) }
        for ref in deleted where !typeIds.contains(ref.type) { typeIds.append(ref.type) }

        lock.lock()
        let delivery = FakeDelivery(
            index: recorded.count + 1, lane: lane, typeIds: typeIds, ids: items.map { $0.id }, deleted: deleted
        )
        recorded.append(delivery)
        lock.unlock()

        log.add("deliver:\(lane.rawValue):\(typeIds.joined(separator: "+")):\(items.count)")
        onDeliver?(delivery)
        completion(responder?(delivery) ?? .accepted(sentDeleted: sendsDeletions))
    }

    func parkingRecord(for item: FakeSample) -> Data? { Data(item.id.utf8) }
}

final class InMemoryCursorStore: CursorStore {
    private let lock = NSLock()
    private let log: EventLog
    private var anchors: [String: AnchorToken] = [:]

    init(log: EventLog) { self.log = log }

    func anchor(for typeId: String) -> AnchorToken? {
        lock.lock()
        defer { lock.unlock() }
        return anchors[typeId]
    }

    func commit(_ anchor: AnchorToken, for typeId: String) {
        lock.lock()
        anchors[typeId] = anchor
        lock.unlock()
        log.add("commit:\(typeId)")
    }

    /// Setzt einen Anchor, ohne dass es im Protokoll steht: der Zustand "vorhanden vor dem Zyklus".
    func preset(_ anchor: AnchorToken, for typeId: String) {
        lock.lock()
        anchors[typeId] = anchor
        lock.unlock()
    }
}

enum FakeStoreError: Error { case disk }

final class InMemoryBackfillStore: BackfillStoring {
    private let lock = NSLock()
    private var current = BackfillPlan.empty()
    private var saves = 0

    /// Lässt `save` scheitern, wie eine volle Platte.
    var failSaves = false
    /// Schreibt jedes erfolgreiche `save` als `plan.save` ins Protokoll.
    var log: EventLog?

    var plan: BackfillPlan {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func load() -> BackfillPlan { plan }

    func save(_ plan: BackfillPlan) throws {
        if failSaves { throw FakeStoreError.disk }
        lock.lock()
        current = plan
        saves += 1
        lock.unlock()
        log?.add("plan.save")
    }

    /// Wie `FileBackfillStore.update`: Lesen, Ändern und Schreiben in einem Schritt. Zählt wie
    /// `save` als Speichern.
    @discardableResult
    func update(_ mutate: (inout BackfillPlan) throws -> Void) throws -> BackfillPlan {
        if failSaves { throw FakeStoreError.disk }
        lock.lock()
        var plan = current
        do {
            try mutate(&plan)
        } catch {
            lock.unlock()
            throw error
        }
        current = plan
        saves += 1
        lock.unlock()
        log?.add("plan.save")
        return plan
    }
}

final class InMemoryDeletionQueue: DeletionQueueing {
    struct Entry: Equatable {
        let refs: [DeletedRef]
        let sentAt: Date?
    }

    private let lock = NSLock()
    private let log: EventLog
    private var recorded: [Entry] = []

    var failEnqueue = false

    init(log: EventLog) { self.log = log }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func enqueue(_ refs: [DeletedRef], sentAt: Date?) throws {
        if failEnqueue { throw FakeStoreError.disk }
        lock.lock()
        recorded.append(Entry(refs: refs, sentAt: sentAt))
        lock.unlock()
        log.add("enqueue:\(refs.map { $0.type }.joined(separator: "+")):\(refs.count)")
    }
}

final class InMemoryParking: RejectionParking {
    struct Parked: Equatable {
        let typeId: String
        let itemId: String
        let httpStatus: Int
        let record: Data?
    }

    private let lock = NSLock()
    private let log: EventLog
    private var recorded: [Parked] = []

    var failPark = false

    init(log: EventLog) { self.log = log }

    var parked: [Parked] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func park(typeId: String, itemId: String, httpStatus: Int, record: Data?) throws {
        if failPark { throw FakeStoreError.disk }
        lock.lock()
        recorded.append(Parked(typeId: typeId, itemId: itemId, httpStatus: httpStatus, record: record))
        lock.unlock()
        log.add("park:\(typeId):\(itemId)")
    }
}

final class ManualClock: LaneClock {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Alles, was ein Kerntest braucht, an einer Stelle.
final class LaneHarness {
    let log = EventLog()
    let reader = FakeReader()
    let sink: FakeSink
    let cursors: InMemoryCursorStore
    let store = InMemoryBackfillStore()
    let deletions: InMemoryDeletionQueue
    let parking: InMemoryParking
    /// 2026-10-04 08:00:00 UTC.
    let clock = ManualClock(Date(timeIntervalSince1970: 1_791_100_800))
    let core: SyncCore<FakeReader, FakeSink>

    private let flagLock = NSLock()
    /// Wie die Generationssperre im SDK: ein Abbruch wartet, bis ein laufender Schreibschritt fertig ist.
    private let commitLock = NSRecursiveLock()
    private var protectedAvailable = true
    private var cancelledFlag = false
    private var beats = 0

    init() {
        sink = FakeSink(log: log)
        cursors = InMemoryCursorStore(log: log)
        deletions = InMemoryDeletionQueue(log: log)
        parking = InMemoryParking(log: log)
        store.log = log
        core = SyncCore(
            reader: reader, sink: sink, cursors: cursors, backfill: store,
            deletions: deletions, parking: parking, clock: clock, ordering: LaneOrdering()
        )
    }

    var protectedDataAvailable: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return protectedAvailable }
        set { flagLock.lock(); protectedAvailable = newValue; flagLock.unlock() }
    }

    var cancelled: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return cancelledFlag }
        set {
            commitLock.lock()
            flagLock.lock()
            cancelledFlag = newValue
            flagLock.unlock()
            commitLock.unlock()
        }
    }

    var heartbeatCount: Int {
        flagLock.lock()
        defer { flagLock.unlock() }
        return beats
    }

    func context(
        _ typeIds: [String], daysBack: Int = 14, chunkLimit: Int = 100, deadline: Date? = nil
    ) -> CycleContext {
        CycleContext(
            typeIds: typeIds, daysBack: daysBack, chunkLimit: chunkLimit, deadline: deadline,
            isCancelled: { [unowned self] in self.cancelled },
            heartbeat: { [unowned self] in
                self.flagLock.lock()
                self.beats += 1
                self.flagLock.unlock()
            },
            isProtectedDataAvailable: { [unowned self] in self.protectedDataAvailable },
            // Wie im SDK: geschrieben wird nur mit gültiger Generation, Prüfung und Schreiben in
            // einem Schritt unter der Sperre des Harness.
            commitIfCurrent: { [unowned self] write in
                self.commitLock.lock()
                defer { self.commitLock.unlock() }
                guard !self.cancelled else { return false }
                try write()
                return true
            }
        )
    }

    /// Setzt die Anchors der Typen auf den heutigen Stand: alles, was danach eingefügt wird, ist neu.
    func presetAnchors(_ typeIds: [String]) {
        for typeId in typeIds {
            cursors.preset(FakeReader.token(reader.anchorValue(for: typeId)), for: typeId)
        }
    }

    /// Führt einen Zyklus aus und wartet auf sein Ergebnis.
    func run(_ context: CycleContext, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> CycleResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: CycleResult?
        core.runCycle(context) {
            result = $0
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            XCTFail("Der Zyklus endete nicht", file: file, line: line)
        }
        return result ?? CycleResult(
            status: .failed("timeout"), liveRecords: 0, backfillRecords: 0, perType: [:], deletionsQueued: 0,
            backfillPending: false, needsCatchUp: false, events: []
        )
    }
}
