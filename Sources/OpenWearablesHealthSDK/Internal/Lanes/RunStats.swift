import Foundation
import HealthKit

// Fork-Zusatz (roboe93). Sammelt während eines Laufs, was später das `SyncOutcome` ergibt.
//
// Der Upstream-Ablauf kennt nur "fertig" oder "nicht fertig" (`Bool`) und loggt den Rest.
// Damit die App den Grund erfährt (gesperrt, abgewiesen, Hintergrundzeit, Netz), tragen die
// Stellen, die ihn kennen, ihn hier ein. Die Statistik ändert den Ablauf nicht: sie liest
// nichts zurück, was eine Entscheidung beeinflusst.

internal final class RunStats {

    /// Unveränderlicher Stand zum Zeitpunkt des Lesens.
    internal struct Snapshot: Equatable {
        var perType: [String: Int] = [:]
        var locked = false
        var rejectedHTTPStatus: Int?
        var failure: String?
        var budgetReason: SyncOutcome.PartialReason?
        var cancelled = false
        var leaseTakenOver = false

        var records: Int { perType.values.reduce(0, +) }
    }

    private let lock = NSLock()
    private var state = Snapshot()

    /// Datensätze, die der Server mit 2xx angenommen hat, je HK-Identifier.
    func addConfirmed(typeIdentifier: String, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        state.perType[typeIdentifier, default: 0] += count
        lock.unlock()
    }

    /// HealthKit war nicht lesbar. Wird gesetzt, bevor der Lauf mit `false` endet.
    func markLocked() {
        lock.lock()
        state.locked = true
        lock.unlock()
    }

    /// Der Server hat abgewiesen (4xx außer 401). Der erste Status bleibt stehen.
    func recordRejected(httpStatus: Int) {
        lock.lock()
        if state.rejectedHTTPStatus == nil { state.rejectedHTTPStatus = httpStatus }
        lock.unlock()
    }

    /// Auth, Netz oder Sonstiges. Der erste Text bleibt stehen. Nie Gesundheitswerte.
    func recordFailure(_ text: String) {
        lock.lock()
        if state.failure == nil { state.failure = text }
        lock.unlock()
    }

    /// Der Lauf hat wegen Budget, Frist oder Hintergrundzeit aufgehört. Der erste Grund bleibt.
    func markBudgetHit(_ reason: SyncOutcome.PartialReason) {
        lock.lock()
        if state.budgetReason == nil { state.budgetReason = reason }
        lock.unlock()
    }

    func markCancelled() {
        lock.lock()
        state.cancelled = true
        lock.unlock()
    }

    var leaseTakenOver: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return state.leaseTakenOver
        }
        set {
            lock.lock()
            state.leaseTakenOver = newValue
            lock.unlock()
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    // MARK: - Statusableitung

    /// Reihenfolge, weil die genauere Auskunft die gröbere schlägt:
    ///
    /// 1. abgewiesen (4xx außer 401): vor allem anderen, sonst bleibt eine Giftpille still
    /// 2. gesperrt: nie sauber, auch wenn vorher schon etwas übertragen wurde
    /// 3. Fehler (Netz, Auth, 5xx)
    /// 4. nicht fertig: Budget oder Hintergrundzeit, dann abgebrochen, sonst unbestimmt
    /// 5. fertig: mit Datensätzen `transferred`, ohne `upToDate`
    ///
    /// Ein fertiger Lauf ignoriert ein Budget-Flag: er hat alle Typen geschafft.
    static func status(
        completed: Bool,
        records: Int,
        locked: Bool,
        rejectedHTTPStatus: Int?,
        failure: String?,
        budgetReason: SyncOutcome.PartialReason?,
        cancelled: Bool
    ) -> SyncOutcome.Status {
        if let httpStatus = rejectedHTTPStatus { return .rejected(httpStatus: httpStatus) }
        if locked { return .deferredLocked }
        if let failure = failure { return .failed(failure) }
        if !completed {
            if let reason = budgetReason { return .partial(reason) }
            if cancelled { return .partial(.cancelled) }
            return .partial(.incomplete)
        }
        return records > 0 ? .transferred : .upToDate
    }

    static func status(completed: Bool, snapshot: Snapshot) -> SyncOutcome.Status {
        status(
            completed: completed, records: snapshot.records, locked: snapshot.locked,
            rejectedHTTPStatus: snapshot.rejectedHTTPStatus, failure: snapshot.failure,
            budgetReason: snapshot.budgetReason, cancelled: snapshot.cancelled
        )
    }
}

// MARK: - Register je Generation

extension OpenWearablesHealthSDK {

    /// Legt die Statistik für eine Generation an. Wird in `beginSyncRun()` aufgerufen
    /// und von `finishSync(generation:)` wieder entfernt.
    @discardableResult
    internal func registerRunStats(generation: Int) -> RunStats {
        let stats = RunStats()
        runStatsLock.lock()
        runStatsByGeneration[generation] = stats
        runStatsLock.unlock()
        return stats
    }

    /// `nil` für eine Generation ohne Statistik (etwa eine bereits beendete). Aufrufer
    /// tragen dann nichts ein, ein später Rückruf einer verdrängten Generation bleibt folgenlos.
    internal func runStats(for generation: Int) -> RunStats? {
        runStatsLock.lock()
        defer { runStatsLock.unlock() }
        return runStatsByGeneration[generation]
    }

    internal func removeRunStats(generation: Int) {
        runStatsLock.lock()
        runStatsByGeneration.removeValue(forKey: generation)
        runStatsLock.unlock()
    }

    /// Zählt die gesendeten Samples je Typ als bestätigt. Nur nach einem 2xx aufrufen.
    internal func recordConfirmed(_ samples: [HKSample], generation: Int) {
        guard let stats = runStats(for: generation) else { return }
        var counts: [String: Int] = [:]
        for sample in samples { counts[sample.sampleType.identifier, default: 0] += 1 }
        for (identifier, count) in counts {
            stats.addConfirmed(typeIdentifier: identifier, count: count)
        }
    }
}
