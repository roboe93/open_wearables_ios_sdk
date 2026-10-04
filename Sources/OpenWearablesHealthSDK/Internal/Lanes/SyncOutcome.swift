import Foundation

// Fork-Zusatz (roboe93), bewusst in einer eigenen Datei, damit künftige Upstream-Merges
// möglichst wenig Reibung haben.
//
// Warum es das gibt (Messung am iPhone 18 Pro, 02./03.10.2026): Die App las bisher
// Logzeilen, um zu erfahren, was ein Lauf getan hat. Ein Lauf bei gesperrtem iPhone
// ("protected data inaccessible") wurde so als "nichts Neues" verbucht, und nach dem
// Wechsel auf 0.15 fehlt die Zeile `HTTP 202` ganz. Jetzt liefert jeder Lauf des SDK
// genau ein `SyncOutcome`: egal ob die App, ein Observer, ein SDK-BGTask, das Entsperren
// oder das Netz ihn ausgelöst hat (Plan 05-03, D-09, D-10, D-13).

/// Welcher Ablauf einen Lauf gesteuert hat.
public enum SyncOrchestration: String, Codable, Sendable {
    /// Zwei-Spuren-Steuerung des Forks (neue Daten zuerst, Nachholen nachrangig).
    case lanes
    /// Ablauf des Original-SDK 0.15, der Rückweg (D-13).
    case upstream
}

/// Was einen Lauf ausgelöst hat.
public enum SyncTrigger: Equatable, Sendable {
    /// Die App selbst, mit einem Namen für die Herkunft (`app:<name>`).
    case app(String)
    /// Ein HealthKit-Observer. Der Typ ist der HK-Identifier, sofern bekannt.
    case observer(String?)
    /// SDK-eigener BGAppRefreshTask.
    case sdkRefresh
    /// SDK-eigener BGProcessingTask.
    case sdkProcessing
    /// Das iPhone wurde entsperrt (`protectedDataDidBecomeAvailable`).
    case unlock
    /// Die App kam in den Vordergrund.
    case foreground
    /// Das Netz kam zurück.
    case network
    /// `configure` stellte eine laufende Sync-Sitzung wieder her.
    case restore
    /// Der Erst-Start in `startBackgroundSync`.
    case kickoff

    /// Schreibweise im Journal und in `scripts/proof/analyze_runs.py`.
    public var journalValue: String {
        switch self {
        case .app(let name):
            return "app:\(name)"
        case .observer(let identifier):
            if let identifier = identifier, !identifier.isEmpty { return "observer:\(identifier)" }
            return "observer"
        case .sdkRefresh: return "sdkRefresh"
        case .sdkProcessing: return "sdkProcessing"
        case .unlock: return "unlock"
        case .foreground: return "foreground"
        case .network: return "network"
        case .restore: return "restore"
        case .kickoff: return "kickoff"
        }
    }
}

/// Das Ergebnis eines Laufs.
///
/// `partial` beschreibt nur die Live-Spur beziehungsweise im Upstream-Modus eine unfertige
/// Sitzung. Offenes Nachholen allein macht keinen Lauf `partial`: ein Lauf, der live sauber
/// war, aber noch Nachholen übrig hat, ist `transferred` oder `upToDate` mit
/// `backfillPending == true`. Sonst entstünde wieder die 48-Stunden-Kette aus `partial`
/// (Erfolgskriterium 3).
public struct SyncOutcome: Equatable, Sendable {

    public enum Status: Equatable, Sendable {
        /// Fertig, und es gingen Datensätze raus.
        case transferred
        /// Fertig, nichts Neues.
        case upToDate
        /// Nicht fertig, der Cursor ist konsistent und der nächste Lauf macht weiter.
        case partial(PartialReason)
        /// HealthKit war nicht lesbar (iPhone gesperrt). Nichts bewegt, zählt nie als sauber.
        case deferredLocked
        /// Der Slot gehörte einem anderen Lauf. Der Halter behält ihn.
        case skippedBusy
        /// Der Server hat die Daten abgewiesen (HTTP 4xx außer 401). Der Cursor bewegt sich nicht.
        case rejected(httpStatus: Int)
        /// Auth, Netz oder Sonstiges. Der Text enthält nie Gesundheitswerte.
        case failed(String)
    }

    public enum PartialReason: String, Sendable {
        /// Datensatz-, Zeit- oder Fristbudget aufgebraucht.
        case budget
        /// Die Sperre (Lease) ist abgelaufen.
        case expired
        /// Von einem anderen Lauf verdrängt.
        case preempted
        /// Die Hintergrundzeit des Systems wurde knapp.
        case backgroundTime
        /// `cancelSync()` oder ein neuerer Lauf hat diesen beendet.
        case cancelled
        /// Nicht fertig, ohne dass ein genauerer Grund bekannt ist.
        case incomplete
    }

    public var status: Status
    /// Bestätigte (vom Server mit 2xx angenommene) Datensätze.
    public var records: Int
    /// HK-Identifier → bestätigte Datensätze. Speist die Diagnose der App je Typ.
    public var perType: [String: Int]
    /// Davon aus der inkrementellen Spur.
    public var liveRecords: Int
    /// Davon aus dem Nachholen beziehungsweise einem offenen Export.
    public var backfillRecords: Int
    public var deletionsQueued: Int
    /// Es gibt noch Nachholen. Das ist Information und macht den Lauf nicht zu `partial`.
    public var backfillPending: Bool
    /// Dieser Lauf hat die Sperre eines hängenden Laufs übernommen.
    public var leaseTakenOver: Bool
    public var orchestration: SyncOrchestration
    public var trigger: SyncTrigger
    public var started: Date
    public var finished: Date

    public init(
        status: Status,
        records: Int = 0,
        perType: [String: Int] = [:],
        liveRecords: Int = 0,
        backfillRecords: Int = 0,
        deletionsQueued: Int = 0,
        backfillPending: Bool = false,
        leaseTakenOver: Bool = false,
        orchestration: SyncOrchestration,
        trigger: SyncTrigger,
        started: Date,
        finished: Date
    ) {
        self.status = status
        self.records = records
        self.perType = perType
        self.liveRecords = liveRecords
        self.backfillRecords = backfillRecords
        self.deletionsQueued = deletionsQueued
        self.backfillPending = backfillPending
        self.leaseTakenOver = leaseTakenOver
        self.orchestration = orchestration
        self.trigger = trigger
        self.started = started
        self.finished = finished
    }

    /// Schreibweise im Journal: `transferred`, `upToDate`, `partial:<grund>`,
    /// `deferredLocked`, `skippedBusy`, `rejected:<http>`, `failed:<text>`.
    public var statusKey: String {
        switch status {
        case .transferred: return "transferred"
        case .upToDate: return "upToDate"
        case .partial(let reason): return "partial:\(reason.rawValue)"
        case .deferredLocked: return "deferredLocked"
        case .skippedBusy: return "skippedBusy"
        case .rejected(let httpStatus): return "rejected:\(httpStatus)"
        case .failed(let text): return "failed:\(text)"
        }
    }
}
