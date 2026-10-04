import Foundation

// Fork-Zusatz (roboe93), Plan 05-06. Der Kern der Zwei-Spuren-Steuerung (D-05, D-06).
//
// Warum es das gibt (Messung am iPhone 18 Pro, 02./03.10.2026): Das Original stellt einen offenen
// Export vor alle neuen Daten und setzt Anchors erst bei Abschluss. Der Schlaf einer Nacht ging
// dadurch nie raus, und ein gesperrter Hintergrundlauf überschrieb eine frische Sitzung. Hier gibt
// es deshalb zwei Spuren und genau einen Läufer:
//
//   * Live-Spur: anchor-basiert, läuft in jedem Zyklus zuerst, ohne Datumsgrenze. Seltene,
//     wertvolle Typen (Stufe A) gehen gebündelt vorweg, dichte Typen (Stufe B) danach in Chunks.
//   * Nachholen: Datumsfenster je Typ, neuestes zuerst, nachrangig. Vor jedem Chunk prüft der Läufer,
//     ob die Live-Spur etwas angefordert hat (`requestLiveRound`), und gibt dann ab. Ein offenes
//     Nachholen hält neue Daten nie auf. Der laufende Upload wird dabei nie abgebrochen.
//
// Kooperativ statt parallel: zwei Schreiber auf Anchors und Upload erzeugen genau die Rennen, die die
// Run-Generationen von 0.15 beseitigt haben (Recherche, Pattern 1). Die Latenz einer Live-Anforderung
// ist der Rest des laufenden Chunks.
//
// Anchor "jetzt" vor dem Nachholen (Pattern 3): Ein Typ ohne Anchor bekommt zuerst seinen aktuellen
// Anchor festgeschrieben, danach beginnt das Nachholen für alles, was davor entstand. Was danach in
// Health dazukommt, kommt genau einmal über die Live-Spur.
//
// Commit nur nach Annahme durch den Server und nur bei gültiger Generation (T-05-20). Löschungen
// gehen vor dem Anchor in die Warteschlange. Ein abgewiesenes Paket blockiert keinen anderen Typ
// (`RejectionPolicy`).
//
// Der Kern importiert weder HealthKit noch UIKit und ist mit Fakes prüfbar (D-14). Alle Schritte
// laufen auf einer eigenen seriellen Queue; Rückrufe des Readers und des Sinks springen dorthin
// zurück. Das schützt den Zustand und hält den Stapel flach, auch wenn ein Fake synchron antwortet.

// MARK: - Zustand eines Zyklus

/// Warum ein Zyklus früher endet.
private enum StopReason {
    case locked
    case failed
    case cancelled
    case deadline
}

/// Was ein Zyklus (oder eine Live-Runde darin) bis jetzt getan hat.
private struct Tally {
    var perType: [String: Int] = [:]
    var liveRecords = 0
    var backfillRecords = 0
    var deletionsQueued = 0
    var events: [String] = []
    var rejectedStatus: Int?
    var locked = false
    var failure: String?
    /// Die Frist endete die Live-Spur. Eine Frist im Nachholen setzt dies nie.
    var budgetHit = false
    var cancelled = false
    var backgroundTime = false

    mutating func setFailure(_ text: String) {
        if failure == nil { failure = text }
    }

    mutating func setRejected(_ status: Int) {
        if rejectedStatus == nil { rejectedStatus = status }
    }

    /// Was seit `earlier` dazukam. Für das Ergebnis einer einzelnen Live-Runde.
    func delta(since earlier: Tally) -> Tally {
        var result = Tally()
        for (typeId, count) in perType {
            let difference = count - (earlier.perType[typeId] ?? 0)
            if difference > 0 { result.perType[typeId] = difference }
        }
        result.liveRecords = liveRecords - earlier.liveRecords
        result.backfillRecords = backfillRecords - earlier.backfillRecords
        result.deletionsQueued = deletionsQueued - earlier.deletionsQueued
        result.events = Array(events.dropFirst(earlier.events.count))
        result.rejectedStatus = rejectedStatus != earlier.rejectedStatus ? rejectedStatus : nil
        result.locked = locked && !earlier.locked
        result.failure = failure != earlier.failure ? failure : nil
        result.budgetHit = budgetHit && !earlier.budgetHit
        result.cancelled = cancelled && !earlier.cancelled
        result.backgroundTime = backgroundTime && !earlier.backgroundTime
        return result
    }
}

private final class CycleRun {
    let context: CycleContext
    let completion: (CycleResult) -> Void
    let stageA: [String]
    let stageB: [String]
    let tracked: Set<String>

    var plan = BackfillPlan.empty()
    var tally = Tally()
    var stop: StopReason?
    /// Spur-Schlüssel (`BackfillPlan.rejectionKey`), die in diesem Zyklus nichts mehr versuchen:
    /// abgewiesen und wartend, oder nicht lesbar.
    var resting: Set<String> = []
    /// Halbierte Limits, die für den Rest des Zyklus gelten, damit ein Typ nicht nach jeder
    /// Annahme wieder mit dem großen Chunk anläuft.
    var limitOverride: [String: Int] = [:]

    init(context: CycleContext, ordering: LaneOrdering, completion: @escaping (CycleResult) -> Void) {
        self.context = context
        self.completion = completion
        let split = ordering.split(context.typeIds)
        stageA = split.stageA
        stageB = split.stageB
        tracked = Set(context.typeIds)
    }
}

// MARK: - Kern

final class SyncCore<Reader: HealthReading, Sink: Delivering> where Reader.Item == Sink.Item {

    typealias Item = Reader.Item
    typealias Waiter = (CycleResult) -> Void

    private static var bootstrapOrigin: String { "bootstrap" }

    private let reader: Reader
    private let sink: Sink
    private let cursors: CursorStore
    private let backfill: BackfillStoring
    private let deletions: DeletionQueueing
    private let parking: RejectionParking
    private let clock: LaneClock
    private let ordering: LaneOrdering

    private let queue = DispatchQueue(label: "health_sync_core")

    /// Schützt `running`, `livePending`, `waiters`, `roundWaiters` und `tightenedDeadline`. Wird nie gehalten, während fremder Code
    /// (Rückrufe, Waiter) läuft.
    private let stateLock = NSLock()
    private var running = false
    private var livePending = false
    private var waiters: [Waiter] = []
    /// Die Wartenden der Live-Runde, die gerade läuft. Hier statt in einer lokalen Liste, damit
    /// `drainWaiters` sie auch dann erreicht, wenn die Runde hängt (Review ME-03).
    private var roundWaiters: [Waiter] = []
    /// Von außen vorgezogene Frist des laufenden Zyklus (`tighten`). Gilt nur bis zu dessen Ende.
    private var tightenedDeadline: Date?

    init(
        reader: Reader, sink: Sink, cursors: CursorStore, backfill: BackfillStoring,
        deletions: DeletionQueueing, parking: RejectionParking, clock: LaneClock, ordering: LaneOrdering
    ) {
        self.reader = reader
        self.sink = sink
        self.cursors = cursors
        self.backfill = backfill
        self.deletions = deletions
        self.parking = parking
        self.clock = clock
        self.ordering = ordering
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// Führt einen Zyklus aus: Bootstrap, Live-Spur, Nachholen. `completion` kommt auf der Queue des
    /// Kerns. Läuft schon einer, endet der Aufruf sofort mit `skippedBusy` und fasst nichts an.
    func runCycle(_ context: CycleContext, completion: @escaping (CycleResult) -> Void) {
        stateLock.lock()
        if running {
            stateLock.unlock()
            completion(CycleResult(
                status: .skippedBusy, liveRecords: 0, backfillRecords: 0, perType: [:], deletionsQueued: 0,
                backfillPending: false, needsCatchUp: false, events: []
            ))
            return
        }
        running = true
        tightenedDeadline = nil
        stateLock.unlock()

        queue.async { [self] in
            start(CycleRun(context: context, ordering: ordering, completion: completion))
        }
    }

    /// Fordert eine Live-Runde an, während ein Zyklus läuft. Der Läufer gibt am nächsten Chunk-Rand
    /// vom Nachholen ab, liest die Live-Spur und ruft `waiter` danach genau einmal mit dem Ergebnis
    /// dieser Runde. Endet der Zyklus vorher (Abbruch, gesperrt, Fehler), bekommt der Waiter das
    /// Zyklusergebnis, damit er nie hängen bleibt.
    ///
    /// Läuft kein Zyklus, wird der Waiter nicht gerufen und nichts gemerkt: der Aufrufer startet
    /// dann einen Zyklus (`false`).
    @discardableResult
    func requestLiveRound(_ waiter: @escaping (CycleResult) -> Void) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running else { return false }
        waiters.append(waiter)
        livePending = true
        return true
    }

    /// Zieht die Frist des laufenden Zyklus vor (Review ME-01): ein Auslöser mit Frist, der an diesen
    /// Zyklus übergeben wird, oder der Ablauf-Handler eines Tasks ("jetzt"). Nie später als die
    /// Frist, die schon gilt. Wirkt an der nächsten Prüfstelle; ohne laufenden Zyklus geschieht nichts.
    func tighten(deadline: Date) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running else { return }
        tightenedDeadline = min(tightenedDeadline ?? deadline, deadline)
    }

    private func currentDeadline(_ run: CycleRun) -> Date? {
        stateLock.lock()
        let tightened = tightenedDeadline
        stateLock.unlock()
        switch (run.context.deadline, tightened) {
        case let (own?, other?): return min(own, other)
        case let (own?, nil): return own
        case let (nil, other?): return other
        case (nil, nil): return nil
        }
    }

    /// Beantwortet sofort alle, die auf eine Live-Runde warten, auch die der Runde, die gerade läuft,
    /// und vergisst sie (Review ME-03). Für einen Kern, der hängt (ein HealthKit-Rückruf kommt nie)
    /// oder abgelöst wurde: seine Wartenden bekämen sonst nie eine Antwort. Der Zyklus selbst läuft
    /// weiter; endet er später, ruft er sie nicht noch einmal.
    @discardableResult
    func drainWaiters(with result: CycleResult) -> Int {
        stateLock.lock()
        let taken = roundWaiters + waiters
        roundWaiters = []
        waiters = []
        livePending = false
        stateLock.unlock()
        for waiter in taken { waiter(result) }
        return taken.count
    }

    // MARK: Start und Ende

    private func start(_ run: CycleRun) {
        run.context.heartbeat()

        // Der Plan wird zuerst geladen, auch wenn der Lauf gleich endet: das Ergebnis meldet sonst
        // "nichts offen", obwohl nur nicht nachgesehen wurde. Das Laden ist eine lokale Datei, kein
        // Zugriff auf HealthKit oder den Server.
        run.plan = backfill.load()

        if run.context.isCancelled() {
            cancel(run)
            finish(run)
            return
        }

        // Gesperrt: nichts lesen, nichts liefern, nichts festschreiben. `needsCatchUp` sorgt dafür,
        // dass nach dem Entsperren nachgeholt wird.
        guard run.context.isProtectedDataAvailable() else {
            markLocked(run, event: "locked:beforeStart")
            finish(run)
            return
        }

        bootstrap(run, types: run.stageA + run.stageB, index: 0) { [self] in
            guard run.stop == nil else {
                finish(run)
                return
            }
            runLiveRound(run) { [self] in
                backfillLoop(run)
            }
        }
    }

    /// Beendet den Zyklus. Wer noch auf eine Live-Runde wartet, bekommt sie vorher, solange der
    /// Zyklus nicht abgebrochen ist; sonst das Zyklusergebnis.
    private func finish(_ run: CycleRun) {
        let (again, leftover) = settle(stopped: run.stop != nil)
        if again {
            runLiveRound(run) { [self] in finish(run) }
            return
        }
        let result = makeResult(run, tally: run.tally)
        for waiter in leftover { waiter(result) }
        run.completion(result)
    }

    /// Entscheidet unter der Sperre, ob noch eine Live-Runde läuft oder der Zyklus zu Ende ist.
    /// Beides in einem Schritt, damit sich kein Waiter zwischen Prüfung und Freigabe einschleicht.
    private func settle(stopped: Bool) -> (runLiveRound: Bool, leftover: [Waiter]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if livePending && !stopped { return (true, []) }
        running = false
        tightenedDeadline = nil
        let leftover = roundWaiters + waiters
        roundWaiters = []
        waiters = []
        livePending = false
        return (false, leftover)
    }

    /// Bei Rundenbeginn: die Wartenden gehören ab jetzt zu dieser Runde.
    private func moveWaitersIntoRound() {
        stateLock.lock()
        defer { stateLock.unlock() }
        roundWaiters += waiters
        waiters = []
        livePending = false
    }

    /// Bei Rundenende: wer zu dieser Runde gehört und noch nicht anders beantwortet wurde.
    private func takeRoundWaiters() -> [Waiter] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let taken = roundWaiters
        roundWaiters = []
        return taken
    }

    private func hasLivePending() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return livePending
    }

    private func makeResult(_ run: CycleRun, tally t: Tally) -> CycleResult {
        let budgetReason: SyncOutcome.PartialReason? = t.backgroundTime ? .backgroundTime : (t.budgetHit ? .budget : nil)
        let status = RunStats.status(
            completed: !t.cancelled && budgetReason == nil,
            records: t.liveRecords + t.backfillRecords,
            locked: t.locked,
            rejectedHTTPStatus: t.rejectedStatus,
            failure: t.failure,
            budgetReason: budgetReason,
            cancelled: t.cancelled
        )
        // Nur verfolgte Typen zählen: ein Typ, der nicht mehr abgefragt wird, hält nichts offen.
        let pending = run.plan.entries.contains { $0.value.state == .pending && run.tracked.contains($0.key) }
        return CycleResult(
            status: status,
            liveRecords: t.liveRecords,
            backfillRecords: t.backfillRecords,
            perType: t.perType,
            deletionsQueued: t.deletionsQueued,
            backfillPending: pending,
            needsCatchUp: t.locked,
            events: t.events
        )
    }

    // MARK: Prüfstellen

    /// Lebenszeichen, Abbruch und Frist. Vor jedem Abruf, jeder Lieferung und jedem Chunk.
    private func gate(_ run: CycleRun) -> StopReason? {
        run.context.heartbeat()
        if run.context.isCancelled() { return .cancelled }
        if let deadline = currentDeadline(run), clock.now() >= deadline { return .deadline }
        return nil
    }

    private func cancel(_ run: CycleRun) {
        run.tally.cancelled = true
        run.stop = .cancelled
    }

    /// Frist oder Abbruch in der Live-Spur. Die Frist macht den Lauf `partial(.budget)`.
    private func applyLiveStop(_ run: CycleRun, _ reason: StopReason) {
        switch reason {
        case .deadline:
            run.tally.budgetHit = true
            run.stop = .deadline
        default:
            cancel(run)
        }
    }

    private func markLocked(_ run: CycleRun, event: String) {
        run.tally.locked = true
        run.tally.events.append(event)
        if run.stop == nil { run.stop = .locked }
    }

    /// Ein Upload kam als abgebrochen zurück. Hat der Lauf seine Generation verloren, ist es ein
    /// Abbruch von außen. Sonst hat das System ihn beendet (Hintergrundzeit).
    private func markDeliveryCancelled(_ run: CycleRun) {
        if run.context.isCancelled() {
            cancel(run)
        } else {
            run.tally.backgroundTime = true
            run.stop = .cancelled
        }
    }

    // MARK: Bootstrap

    /// Für jeden Typ ohne Anchor: erst der Plan, dann der Anchor für "jetzt". Scheitert das Speichern
    /// des Plans, entsteht kein Anchor: ein Anchor ohne Plan ließe die Historie des Typs für immer
    /// ungeholt, ein Plan ohne Anchor lässt sich dagegen beim nächsten Zyklus reparieren.
    private func bootstrap(_ run: CycleRun, types: [String], index: Int, done: @escaping () -> Void) {
        guard index < types.count, run.stop == nil else {
            done()
            return
        }
        let typeId = types[index]
        let next = { [self] in bootstrap(run, types: types, index: index + 1, done: done) }

        guard cursors.anchor(for: typeId) == nil else {
            next()
            return
        }

        if let entry = run.plan.entries[typeId], entry.state == .pending, entry.origin != Self.bootstrapOrigin {
            // Ein übernommener offener Export ohne Anchor. Den Anchor legt die Übernahme an: für diesen
            // Typ wäre "jetzt" nicht der Zeitpunkt, an dem der alte Export begann. Der Kern rät nicht,
            // er macht es sichtbar.
            run.tally.events.append("noAnchor:\(typeId)")
            next()
            return
        }

        if let reason = gate(run) {
            applyLiveStop(run, reason)
            done()
            return
        }

        reader.currentAnchor(typeId: typeId) { [self] result in
            queue.async { [self] in
                run.context.heartbeat()
                switch result {
                case .failure(.locked):
                    markLocked(run, event: "locked:bootstrap:\(typeId)")
                    done()
                case .failure(.other):
                    run.tally.events.append("bootstrapFailed:\(typeId)")
                    run.tally.setFailure("bootstrap")
                    next()
                case .success(let anchor):
                    // "Jetzt" wird nach dem Lesen des Anchors bestimmt: alles, was vorher entstand, liegt
                    // im Fenster des Nachholens, alles danach kommt über den Anchor.
                    let now = clock.now()
                    let daysBack = run.context.daysBack
                    // Plan und Anchor nur mit gültiger Generation (HI-01): ein Zyklus, der während des
                    // Durchlaufs abgelöst wurde, überschriebe sonst den Plan des neueren und hinterließe
                    // einen Anchor ohne Nachholeintrag.
                    switch writePlan(run, { plan in
                        if let entry = plan.entries[typeId], entry.state == .pending {
                            plan.reanchor(typeId: typeId, now: now)
                        } else {
                            plan.start(typeId: typeId, now: now, daysBack: daysBack, origin: Self.bootstrapOrigin)
                        }
                    }) {
                    case .fenced:
                        cancel(run)
                        done()
                        return
                    case .failed:
                        run.tally.events.append("bootstrapFailed:\(typeId)")
                        run.tally.setFailure("bootstrap")
                        next()
                        return
                    case .written:
                        break
                    }
                    guard commitAnchor(run, anchor, for: typeId) else {
                        // Der Plan steht, der Anchor nicht: der nächste Zyklus verankert neu (`reanchor`).
                        cancel(run)
                        done()
                        return
                    }
                    run.context.heartbeat()
                    run.tally.events.append("bootstrap:\(typeId)")
                    next()
                }
            }
        }
    }

    // MARK: Live-Spur

    /// Eine Live-Runde: Stufe A gebündelt, danach Stufe B Typ für Typ. Wartende Anforderungen werden
    /// bei Rundenbeginn übernommen und nach der Runde mit deren Ergebnis bedient.
    private func runLiveRound(_ run: CycleRun, done: @escaping () -> Void) {
        moveWaitersIntoRound()
        let before = run.tally

        liveStage(run, types: run.stageA, bundled: true) { [self] in
            liveStageB(run, index: 0) {
                let taken = takeRoundWaiters()
                if !taken.isEmpty {
                    let result = makeResult(run, tally: run.tally.delta(since: before))
                    for waiter in taken { waiter(result) }
                }
                done()
            }
        }
    }

    private func liveStageB(_ run: CycleRun, index: Int, done: @escaping () -> Void) {
        guard index < run.stageB.count, run.stop == nil else {
            done()
            return
        }
        // Stufe B einzeln: ein dichter Typ hält höchstens einen Chunk im Speicher.
        liveStage(run, types: [run.stageB[index]], bundled: false) { [self] in
            liveStageB(run, index: index + 1, done: done)
        }
    }

    private func isLiveEligible(_ run: CycleRun, _ typeId: String) -> Bool {
        cursors.anchor(for: typeId) != nil
            && !run.resting.contains(BackfillPlan.rejectionKey(typeId: typeId, lane: .live))
    }

    /// Liest und liefert, bis alle Typen leer sind. Typen mit `hasMore` oder halbiertem Limit kommen
    /// im nächsten Durchgang erneut dran.
    private func liveStage(_ run: CycleRun, types: [String], bundled: Bool, done: @escaping () -> Void) {
        let eligible = types.filter { isLiveEligible(run, $0) }
        guard !eligible.isEmpty, run.stop == nil else {
            done()
            return
        }
        fetchPass(run, types: eligible, index: 0, collected: []) { [self] collected in
            // Nach einer Sperre darf liefern, was schon gelesen ist. Bei Abbruch oder Frist ist
            // `collected` ohnehin leer.
            let packages = bundled ? bundle(collected, limit: run.context.chunkLimit) : collected.map { [$0] }
            deliverPackages(run, packages, index: 0, refetch: []) { [self] refetch in
                guard run.stop == nil else {
                    done()
                    return
                }
                liveStage(run, types: types.filter { refetch.contains($0) }, bundled: bundled, done: done)
            }
        }
    }

    private func fetchPass(
        _ run: CycleRun, types: [String], index: Int, collected: [LiveChunk<Item>],
        done: @escaping ([LiveChunk<Item>]) -> Void
    ) {
        guard index < types.count else {
            done(collected)
            return
        }
        if let reason = gate(run) {
            applyLiveStop(run, reason)
            done([])
            return
        }
        let typeId = types[index]
        guard let anchor = cursors.anchor(for: typeId) else {
            fetchPass(run, types: types, index: index + 1, collected: collected, done: done)
            return
        }

        reader.fetchLive(typeId: typeId, anchor: anchor, limit: limit(for: typeId, lane: .live, run: run)) { [self] result in
            queue.async { [self] in
                run.context.heartbeat()
                switch result {
                case .failure(.locked):
                    markLocked(run, event: "locked:live:\(typeId)")
                    done(collected)
                case .failure(.other):
                    run.tally.events.append("readFailed:\(typeId)")
                    run.tally.setFailure("read")
                    run.resting.insert(BackfillPlan.rejectionKey(typeId: typeId, lane: .live))
                    fetchPass(run, types: types, index: index + 1, collected: collected, done: done)
                case .success(let chunk):
                    if chunk.items.isEmpty && chunk.deleted.isEmpty {
                        // Nichts zu liefern. Ein weitergerückter Anchor (HealthKit hat nur Fremdes
                        // übersprungen) wird festgehalten, damit er nicht erneut gelesen wird.
                        if chunk.newAnchor != anchor {
                            if commitAnchor(run, chunk.newAnchor, for: typeId) {
                                run.context.heartbeat()
                            } else {
                                cancel(run)
                            }
                        }
                        fetchPass(run, types: types, index: index + 1, collected: collected, done: done)
                    } else {
                        fetchPass(run, types: types, index: index + 1, collected: collected + [chunk], done: done)
                    }
                }
            }
        }
    }

    /// Bündelt Chunks zu Paketen bis `limit` Datensätze. Ein Chunk wird nie geteilt, ein Chunk nur mit
    /// Löschungen zählt als null Datensätze und fährt im aktuellen Paket mit.
    private func bundle(_ chunks: [LiveChunk<Item>], limit: Int) -> [[LiveChunk<Item>]] {
        var packages: [[LiveChunk<Item>]] = []
        var current: [LiveChunk<Item>] = []
        var size = 0
        for chunk in chunks {
            let count = chunk.items.count
            if !current.isEmpty && size + count > limit {
                packages.append(current)
                current = []
                size = 0
            }
            current.append(chunk)
            size += count
        }
        if !current.isEmpty { packages.append(current) }
        return packages
    }

    private func deliverPackages(
        _ run: CycleRun, _ packages: [[LiveChunk<Item>]], index: Int, refetch: Set<String>,
        done: @escaping (Set<String>) -> Void
    ) {
        guard index < packages.count else {
            done(refetch)
            return
        }
        // Nach einer Sperre darf noch raus, was schon gelesen ist; alles andere beendet den Zyklus.
        guard run.stop == nil || run.stop == .locked else {
            done(refetch)
            return
        }
        if let reason = gate(run) {
            applyLiveStop(run, reason)
            done(refetch)
            return
        }
        deliverPackage(run, packages[index]) { [self] more in
            deliverPackages(run, packages, index: index + 1, refetch: refetch.union(more), done: done)
        }
    }

    /// Liefert ein Paket der Live-Spur. `done` bekommt die Typen, die im nächsten Durchgang erneut
    /// gelesen werden sollen (mehr da, oder Limit halbiert).
    private func deliverPackage(_ run: CycleRun, _ package: [LiveChunk<Item>], done: @escaping (Set<String>) -> Void) {
        let items = package.flatMap { $0.items }
        let deleted = package.flatMap { $0.deleted }
        run.context.heartbeat()

        sink.deliver(items, deleted: deleted, lane: .live) { [self] result in
            queue.async { [self] in
                run.context.heartbeat()
                switch result {
                case .accepted(let sentDeleted):
                    // Bestätigt ist bestätigt, auch wenn der Lauf danach nichts mehr festschreiben darf.
                    for chunk in package { count(run, typeId: chunk.typeId, records: chunk.items.count, lane: .live) }
                    var refetch = Set<String>()
                    for chunk in package {
                        let before = cursors.anchor(for: chunk.typeId)
                        guard commitLive(run, chunk, sentDeleted: sentDeleted) else { break }
                        if chunk.hasMore {
                            if before == chunk.newAnchor {
                                // Der Reader meldet "mehr" ohne weiterzurücken. Nicht in einer Schleife enden.
                                run.tally.events.append("noProgress:\(chunk.typeId)")
                            } else {
                                refetch.insert(chunk.typeId)
                            }
                        }
                    }
                    done(refetch)

                case .rejected(let status) where !RejectionPolicy.isRecordSpecific(status):
                    // 403, 404, 429 und Co.: kein Urteil über den Datensatz (HI-02). Wie ein Serverfehler:
                    // nichts halbieren, nichts zählen, nichts parken, der Anchor bleibt.
                    refuse(run, httpStatus: status)
                    done([])

                case .rejected(let status):
                    if package.count > 1 {
                        // Ein Sammelpaket weist ein Typ allein ab: je Typ getrennt erneut senden, damit nur
                        // der Verursacher hängt.
                        run.tally.events.append("split:\(status)")
                        deliverPackages(run, package.map { [$0] }, index: 0, refetch: [], done: done)
                    } else {
                        handleLiveRejection(run, package[0], httpStatus: status, done: done)
                    }

                case .failed(let text):
                    run.tally.setFailure(text)
                    run.stop = .failed
                    done([])

                case .cancelled:
                    markDeliveryCancelled(run)
                    done([])
                }
            }
        }
    }

    /// Schreibt einen angenommenen Chunk fest: Löschungen zuerst in die Warteschlange, dann der Anchor.
    /// Nur bei gültiger Generation (T-05-20).
    private func commitLive(_ run: CycleRun, _ chunk: LiveChunk<Item>, sentDeleted: Bool) -> Bool {
        if run.context.isCancelled() {
            cancel(run)
            return false
        }
        if !chunk.deleted.isEmpty {
            do {
                try deletions.enqueue(chunk.deleted, sentAt: sentDeleted ? clock.now() : nil)
            } catch {
                // Der Anchor bliebe sonst nicht stehen und die Löschung wäre verloren.
                run.tally.events.append("deletionQueueFailed:\(chunk.typeId)")
                run.tally.setFailure("deletion queue")
                run.stop = .failed
                return false
            }
            run.tally.deletionsQueued += chunk.deleted.count
        }
        guard commitAnchor(run, chunk.newAnchor, for: chunk.typeId) else {
            cancel(run)
            return false
        }
        run.context.heartbeat()
        clearRejection(run, typeId: chunk.typeId, lane: .live)
        return true
    }

    /// Eine Abweisung, die nicht am Datensatz hängt (`RejectionPolicy.isRecordSpecific` ist falsch):
    /// der Zyklus endet als `failed("HTTP <Status>")`, wie bei einem Serverfehler.
    private func refuse(_ run: CycleRun, httpStatus: Int) {
        run.tally.events.append("refused:\(httpStatus)")
        run.tally.setFailure("HTTP \(httpStatus)")
        run.stop = .failed
    }

    private func handleLiveRejection(
        _ run: CycleRun, _ chunk: LiveChunk<Item>, httpStatus: Int, done: @escaping (Set<String>) -> Void
    ) {
        let typeId = chunk.typeId
        let key = BackfillPlan.rejectionKey(typeId: typeId, lane: .live)
        let attempted = max(chunk.items.count, 1)
        let (state, action) = RejectionPolicy.decide(
            state: run.plan.rejections[key], httpStatus: httpStatus, attemptedLimit: attempted, now: clock.now()
        )
        savePlan(run) { $0.rejections[key] = state }

        switch action {
        case .halve(let limit):
            run.limitOverride[key] = limit
            run.tally.events.append("halve:\(typeId):\(limit)")
            done([typeId])

        case .holdUntilNextCycle:
            run.resting.insert(key)
            run.tally.setRejected(httpStatus)
            run.tally.events.append("hold:\(typeId):\(httpStatus)")
            done([])

        case .park:
            run.tally.setRejected(httpStatus)
            // Höchstens ein Datensatz, sonst hätte nicht `park` herauskommen können. Scheitert das
            // Ablegen, rückt nichts weiter: ein Datensatz wird nie still übersprungen.
            for item in chunk.items {
                do {
                    try parking.park(
                        typeId: typeId, itemId: reader.identity(of: item).id,
                        httpStatus: httpStatus, record: sink.parkingRecord(for: item)
                    )
                } catch {
                    run.tally.events.append("parkFailed:\(typeId)")
                    run.tally.setFailure("parking")
                    run.resting.insert(key)
                    done([])
                    return
                }
            }
            // Löschungen des Chunks bleiben ungesendet in der Warteschlange, der Anchor rückt dahinter.
            guard commitLive(run, chunk, sentDeleted: false) else {
                done([])
                return
            }
            run.tally.events.append("parked:\(typeId)")
            done(chunk.hasMore ? [typeId] : [])
        }
    }

    // MARK: Nachholen

    private func backfillLoop(_ run: CycleRun) {
        guard run.stop == nil else {
            finish(run)
            return
        }

        // Vorrang der Live-Spur an jeder Chunk-Grenze.
        if hasLivePending() {
            runLiveRound(run) { [self] in backfillLoop(run) }
            return
        }

        if let reason = gate(run) {
            if reason == .cancelled {
                cancel(run)
            } else {
                // Eine Frist im Nachholen macht den Lauf nicht `partial`: neue Daten sind sauber raus.
                run.stop = .deadline
            }
            finish(run)
            return
        }

        func nextType() -> String? {
            run.plan.pendingTypeIds(ordering).first { typeId in
                run.tracked.contains(typeId)
                    && !run.resting.contains(BackfillPlan.rejectionKey(typeId: typeId, lane: .backfill))
            }
        }
        // Bevor der Zyklus endet: ein Auftrag, der während des Nachholens kam, läuft noch mit.
        guard let typeId = nextType() ?? (adoptNewPendingEntries(run) ? nextType() : nil) else {
            finish(run)
            return
        }
        backfillChunk(run, typeId: typeId) { [self] in backfillLoop(run) }
    }

    /// Ein Chunk eines Typs: Fenster `[floor, covered]` neuestes zuerst, bereits gelieferte Samples auf
    /// dem Rand herausfiltern, liefern, nach Annahme `covered` zurückrücken.
    private func backfillChunk(_ run: CycleRun, typeId: String, next: @escaping () -> Void) {
        guard let entry = run.plan.entries[typeId], entry.state == .pending else {
            next()
            return
        }
        let key = BackfillPlan.rejectionKey(typeId: typeId, lane: .backfill)
        let boundary = Set(entry.boundaryIds)
        // Mit den Grenz-Samples im Fenster bleibt es bei `limit` neuen: sie sind die neuesten.
        let fetchLimit = limit(for: typeId, lane: .backfill, run: run) + boundary.count

        reader.fetchWindow(typeId: typeId, floor: entry.floor, upTo: entry.covered, limit: fetchLimit) { [self] result in
            queue.async { [self] in
                run.context.heartbeat()
                switch result {
                case .failure(.locked):
                    markLocked(run, event: "locked:backfill:\(typeId)")
                    next()
                case .failure(.other):
                    run.tally.events.append("backfillReadFailed:\(typeId)")
                    run.tally.setFailure("read")
                    run.resting.insert(key)
                    next()
                case .success(let window):
                    let fresh = window.items.filter { !boundary.contains(reader.identity(of: $0).id) }
                    guard !fresh.isEmpty else {
                        // Im Fenster liegt nichts Ungeliefertes mehr.
                        if !savePlan(run, { $0.markDone(typeId: typeId) }), run.stop == nil {
                            run.stop = .failed
                        }
                        next()
                        return
                    }
                    deliverBackfill(run, typeId: typeId, fresh: fresh, hasMore: window.hasMore, next: next)
                }
            }
        }
    }

    private func deliverBackfill(
        _ run: CycleRun, typeId: String, fresh: [Item], hasMore: Bool, next: @escaping () -> Void
    ) {
        run.context.heartbeat()
        sink.deliver(fresh, deleted: [], lane: .backfill) { [self] result in
            queue.async { [self] in
                run.context.heartbeat()
                switch result {
                case .accepted:
                    count(run, typeId: typeId, records: fresh.count, lane: .backfill)
                    guard !run.context.isCancelled() else {
                        cancel(run)
                        next()
                        return
                    }
                    advanceBackfill(run, typeId: typeId, delivered: fresh, hasMore: hasMore)
                    clearRejection(run, typeId: typeId, lane: .backfill)
                    next()

                case .rejected(let status) where !RejectionPolicy.isRecordSpecific(status):
                    refuse(run, httpStatus: status)
                    next()

                case .rejected(let status):
                    handleBackfillRejection(run, typeId: typeId, fresh: fresh, hasMore: hasMore, httpStatus: status, next: next)

                case .failed(let text):
                    run.tally.setFailure(text)
                    run.stop = .failed
                    next()

                case .cancelled:
                    markDeliveryCancelled(run)
                    next()
                }
            }
        }
    }

    private func handleBackfillRejection(
        _ run: CycleRun, typeId: String, fresh: [Item], hasMore: Bool, httpStatus: Int, next: @escaping () -> Void
    ) {
        let key = BackfillPlan.rejectionKey(typeId: typeId, lane: .backfill)
        let (state, action) = RejectionPolicy.decide(
            state: run.plan.rejections[key], httpStatus: httpStatus, attemptedLimit: max(fresh.count, 1),
            now: clock.now()
        )
        savePlan(run) { $0.rejections[key] = state }

        switch action {
        case .halve(let limit):
            run.limitOverride[key] = limit
            run.tally.events.append("halve:\(typeId):\(limit)")
            next()

        case .holdUntilNextCycle:
            run.resting.insert(key)
            run.tally.setRejected(httpStatus)
            run.tally.events.append("hold:\(typeId):\(httpStatus)")
            next()

        case .park:
            run.tally.setRejected(httpStatus)
            for item in fresh {
                do {
                    try parking.park(
                        typeId: typeId, itemId: reader.identity(of: item).id,
                        httpStatus: httpStatus, record: sink.parkingRecord(for: item)
                    )
                } catch {
                    run.tally.events.append("parkFailed:\(typeId)")
                    run.tally.setFailure("parking")
                    run.resting.insert(key)
                    next()
                    return
                }
            }
            guard !run.context.isCancelled() else {
                cancel(run)
                next()
                return
            }
            advanceBackfill(run, typeId: typeId, delivered: fresh, hasMore: hasMore)
            clearRejection(run, typeId: typeId, lane: .backfill)
            run.tally.events.append("parked:\(typeId)")
            next()
        }
    }

    /// Rückt das Fenster hinter die gelieferten (oder geparkten) Samples. Gibt es nichts Älteres mehr,
    /// ist der Typ fertig; sonst bleibt auf dem ältesten Zeitpunkt die Liste seiner gelieferten
    /// Samples als Grenze.
    private func advanceBackfill(_ run: CycleRun, typeId: String, delivered: [Item], hasMore: Bool) {
        let mutation: (inout BackfillPlan) -> Void
        if !hasMore {
            mutation = { $0.markDone(typeId: typeId) }
        } else {
            let stamped = delivered.map { reader.identity(of: $0) }
            if let oldest = stamped.map({ $0.endDate }).min() {
                let bucket = LaneTime.ceil(oldest)
                let ids = stamped.filter { LaneTime.ceil($0.endDate) == bucket }.map { $0.id }
                mutation = { $0.advance(typeId: typeId, to: oldest, boundaryIds: ids) }
            } else {
                mutation = { _ in }
            }
        }
        var probe = run.plan
        mutation(&probe)
        if probe.entries[typeId] == run.plan.entries[typeId] {
            // Der Reader lieferte Samples außerhalb des Fensters. Ohne Fortschritt nicht in einer
            // Schleife enden.
            run.tally.events.append("noProgress:\(typeId)")
            run.resting.insert(BackfillPlan.rejectionKey(typeId: typeId, lane: .backfill))
        }
        if !savePlan(run, mutation), run.stop == nil { run.stop = .failed }
        run.context.heartbeat()
    }

    // MARK: Gemeinsames

    /// Limit je Typ und Spur: der Chunk, höchstens das gemerkte Limit nach einer Ablehnung, höchstens
    /// das in diesem Zyklus halbierte.
    private func limit(for typeId: String, lane: Lane, run: CycleRun) -> Int {
        let key = BackfillPlan.rejectionKey(typeId: typeId, lane: lane)
        var limit = run.context.chunkLimit
        if let state = run.plan.rejections[key] { limit = min(limit, state.limit) }
        if let override = run.limitOverride[key] { limit = min(limit, override) }
        return max(1, limit)
    }

    private func count(_ run: CycleRun, typeId: String, records: Int, lane: Lane) {
        guard records > 0 else { return }
        run.tally.perType[typeId, default: 0] += records
        if lane == .live {
            run.tally.liveRecords += records
        } else {
            run.tally.backfillRecords += records
        }
    }

    /// Nach einer Annahme zählt die Reihe der Ablehnungen von vorn.
    private func clearRejection(_ run: CycleRun, typeId: String, lane: Lane) {
        let key = BackfillPlan.rejectionKey(typeId: typeId, lane: lane)
        guard run.plan.rejections[key] != nil else { return }
        savePlan(run) { $0.clearRejection(typeId: typeId, lane: lane) }
    }

    private enum PlanWrite {
        case written
        /// Die Generation ist verloren, nichts geschrieben.
        case fenced
        /// Platte oder nicht lesbare Datei.
        case failed
    }

    /// Ändert den Plan als ein Schritt auf dem Stand der Datei (`update`) und nur mit gültiger
    /// Generation (HI-01). Danach ist `run.plan` der geschriebene Stand, mit allem, was andere
    /// Schreiber inzwischen angelegt haben (ME-04). Ohne Schreiben bleibt `run.plan`, wie er war.
    private func writePlan(_ run: CycleRun, _ mutate: @escaping (inout BackfillPlan) -> Void) -> PlanWrite {
        var written: BackfillPlan?
        do {
            let current = try run.context.commitIfCurrent { [backfill] in
                written = try backfill.update(mutate)
            }
            guard current, let plan = written else { return .fenced }
            run.plan = plan
            return .written
        } catch {
            return .failed
        }
    }

    /// `writePlan` für die übrigen Stellen: ein Fehlschlag steht im Ergebnis (`failed("plan")`), und
    /// die Änderung gilt wie bisher im Speicher; der Aufrufer entscheidet, ob er weitermacht. Eine
    /// verlorene Generation bricht den Zyklus ab. `true` nur, wenn geschrieben wurde.
    @discardableResult
    private func savePlan(_ run: CycleRun, _ mutate: @escaping (inout BackfillPlan) -> Void) -> Bool {
        switch writePlan(run, mutate) {
        case .written:
            return true
        case .fenced:
            cancel(run)
            return false
        case .failed:
            mutate(&run.plan)
            run.tally.events.append("planSaveFailed")
            run.tally.setFailure("plan")
            return false
        }
    }

    /// Schreibt einen Anchor nur mit gültiger Generation fest, geprüft und geschrieben in einem
    /// Schritt (HI-01). `false`: nichts geschrieben.
    private func commitAnchor(_ run: CycleRun, _ anchor: AnchorToken, for typeId: String) -> Bool {
        (try? run.context.commitIfCurrent { [cursors] in cursors.commit(anchor, for: typeId) }) ?? false
    }

    /// Übernimmt offene Einträge, die ein anderer Schreiber seit dem letzten Schreiben dieses
    /// Zyklus angelegt hat (`requestBackfill` während des Nachholens, ME-04). Nur hinzufügen, nie
    /// etwas entfernen. `true`, wenn etwas dazukam.
    private func adoptNewPendingEntries(_ run: CycleRun) -> Bool {
        let fresh = backfill.load()
        var added = false
        for (typeId, entry) in fresh.entries where entry.state == .pending {
            guard run.plan.entries[typeId]?.state != .pending else { continue }
            run.plan.entries[typeId] = entry
            added = true
        }
        return added
    }
}
