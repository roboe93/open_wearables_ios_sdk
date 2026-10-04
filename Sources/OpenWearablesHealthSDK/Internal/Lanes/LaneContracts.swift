import Foundation

// Fork-Zusatz (roboe93), Plan 05-06. Verträge der Zwei-Spuren-Steuerung.
//
// Der Kern (`SyncCore`) kennt weder HealthKit noch UIKit. Er spricht nur mit diesen
// Protokollen, damit seine Politik (Reihenfolge, Priorität, Frist, Ergebnis) ohne Gerät
// mit Fakes prüfbar ist (D-14). Der Sample-Typ ist generisch (`Item`): HealthKit-Samples
// sind in Tests nicht herstellbar, und `HKDeletedObject` hat keinen öffentlichen
// Initialisierer, deshalb liefert der Reader eigene Werttypen (`DeletedRef`).
//
// Die Namen sind verbindlich: die Verdrahtung mit HealthKit (05-07, 05-08) baut dagegen.

/// Undurchsichtiger Anchor. Im Betrieb ein archivierter `HKQueryAnchor`.
typealias AnchorToken = Data

/// Welche Spur eine Lieferung gehört.
enum Lane: String, Codable {
    /// Anchor-basiert, läuft immer zuerst: alles, was nach dem Anchor dazukam.
    case live
    /// Datumsfenster, neuestes zuerst, nachrangig.
    case backfill
}

/// Eine in Health gelöschte Messung. `id` ist `HKDeletedObject.uuid`, `type` der HK-Identifier.
struct DeletedRef: Codable, Equatable, Hashable {
    let id: String
    let type: String
}

enum ReadFailure: Error, Equatable {
    /// HealthKit ist nicht lesbar (iPhone gesperrt). Nichts bewegt sich, der Lauf wartet.
    case locked
    /// Sonstiger Lesefehler. Der Text enthält nie Gesundheitswerte.
    case other(String)
}

/// Ergebnis einer Anchored Query: Samples und Löschungen seit `anchor`, dazu der neue Anchor.
struct LiveChunk<Item> {
    let typeId: String
    let items: [Item]
    let deleted: [DeletedRef]
    let newAnchor: AnchorToken
    /// Es gibt noch mehr hinter diesem Chunk.
    let hasMore: Bool
}

/// Ergebnis einer Fensterabfrage, neueste Samples zuerst.
struct WindowChunk<Item> {
    let typeId: String
    let items: [Item]
    /// Das Fenster enthält noch ältere Samples als die gelieferten.
    let hasMore: Bool
}

enum DeliveryResult: Equatable {
    /// Der Server hat mit 2xx angenommen. `sentDeleted`: die Löschungen waren Teil des Pakets.
    /// `notSent`: je HK-Identifier, wie viele der übergebenen Samples gar nicht hinausgingen
    /// (Spiegelkopien, Review ME-06). Sie gelten als erledigt, zählen aber nicht als übertragen.
    case accepted(sentDeleted: Bool, notSent: [String: Int] = [:])
    /// Der Server hat abgewiesen (4xx außer 401). Nichts darf festgeschrieben werden. Nur 400, 413
    /// und 422 gelten dem Kern als Urteil über den Datensatz (`RejectionPolicy.isRecordSpecific`),
    /// alle anderen behandelt er wie einen Serverfehler.
    case rejected(httpStatus: Int)
    /// Auth, Netz, 5xx. Der Text enthält nie Gesundheitswerte.
    case failed(String)
    /// Der Upload wurde abgebrochen (Generation verloren, Hintergrundzeit).
    case cancelled
}

/// Uhr, damit Fristen und Zeitstempel in Tests steuerbar sind.
protocol LaneClock: AnyObject {
    func now() -> Date
}

protocol HealthReading: AnyObject {
    associatedtype Item

    /// Kennung und Ende-Zeitpunkt eines Samples, für die Grenzbehandlung des Nachholens.
    func identity(of item: Item) -> (id: String, endDate: Date)

    /// Samples und Löschungen eines Typs seit `anchor`, höchstens `limit` (gelöschte zählen mit).
    func fetchLive(
        typeId: String, anchor: AnchorToken, limit: Int,
        completion: @escaping (Result<LiveChunk<Item>, ReadFailure>) -> Void
    )

    /// Samples mit `endDate` in `[floor, upTo]` (`upTo` inklusiv), neuestes zuerst.
    func fetchWindow(
        typeId: String, floor: Date, upTo: Date, limit: Int,
        completion: @escaping (Result<WindowChunk<Item>, ReadFailure>) -> Void
    )

    /// Der Anchor für "jetzt": alles, was danach in Health dazukommt, liefert die Live-Spur.
    func currentAnchor(typeId: String, completion: @escaping (Result<AnchorToken, ReadFailure>) -> Void)
}

protocol Delivering: AnyObject {
    associatedtype Item

    /// Liefert ein Paket aus Samples mehrerer Typen und deren Löschungen.
    func deliver(
        _ items: [Item], deleted: [DeletedRef], lane: Lane,
        completion: @escaping (DeliveryResult) -> Void
    )

    /// Serialisierter Datensatz für `health_rejected/`. `nil`, wenn er sich nicht darstellen lässt.
    func parkingRecord(for item: Item) -> Data?
}

/// Die Anchors der Live-Spur, je HK-Identifier.
protocol CursorStore: AnyObject {
    func anchor(for typeId: String) -> AnchorToken?
    func commit(_ anchor: AnchorToken, for typeId: String)
}

protocol BackfillStoring: AnyObject {
    func load() -> BackfillPlan
    func save(_ plan: BackfillPlan) throws
    /// Liest den aktuellen Stand, wendet `mutate` darauf an und schreibt ihn, als ein Schritt.
    /// Liefert den geschriebenen Plan. Ein Eintrag, den ein anderer Schreiber seit dem letzten
    /// Laden angelegt hat, geht so nie verloren (Review HI-01, ME-04).
    @discardableResult
    func update(_ mutate: (inout BackfillPlan) throws -> Void) throws -> BackfillPlan
}

extension BackfillStoring {
    /// Vorgabe für einfache Speicher (Tests): laden, ändern, speichern. `FileBackfillStore` macht
    /// daraus einen Schritt unter einer prozessweiten Sperre.
    @discardableResult
    func update(_ mutate: (inout BackfillPlan) throws -> Void) throws -> BackfillPlan {
        var plan = load()
        try mutate(&plan)
        try save(plan)
        return plan
    }
}

/// Warteschlange für Löschungen. Wird vor dem Anchor-Commit beschrieben, damit eine
/// Löschung nie verloren geht, wenn der Anchor schon weiter ist (D-12).
protocol DeletionQueueing: AnyObject {
    func enqueue(_ refs: [DeletedRef], sentAt: Date?) throws
}

/// Ablage für Datensätze, die der Server dauerhaft abweist. Nie still verwerfen.
protocol RejectionParking: AnyObject {
    func park(typeId: String, itemId: String, httpStatus: Int, record: Data?) throws
}

struct CycleContext {
    /// Abzufragende HK-Identifier.
    let typeIds: [String]
    /// Sync-Fenster für den Bootstrap-Backfill (14).
    let daysBack: Int
    /// 2000 im Vordergrund, 100 im Hintergrund.
    let chunkLimit: Int
    let deadline: Date?
    /// Die Generation ging verloren (Abbruch, Lease). Danach schreibt der Lauf nichts mehr fest.
    let isCancelled: () -> Bool
    /// Lebenszeichen an die Lease, an jeder Prüfstelle.
    let heartbeat: () -> Void
    let isProtectedDataAvailable: () -> Bool
    /// Führt `write` nur aus, solange die Generation des Zyklus gültig ist, und prüft und schreibt
    /// in einem Schritt: eine Übernahme kann sich nicht zwischen Prüfung und Schreiben schieben
    /// (Review HI-01, T-05-20). `false`: der Zyklus hat seine Generation verloren, nichts geschrieben.
    /// Jeder Schreibzugriff des Kerns auf Anchors und Nachholplan läuft hierüber.
    let commitIfCurrent: (() throws -> Void) throws -> Bool
}

struct CycleResult: Equatable {
    var status: SyncOutcome.Status
    var liveRecords: Int
    var backfillRecords: Int
    var perType: [String: Int]
    var deletionsQueued: Int
    var backfillPending: Bool
    var needsCatchUp: Bool
    /// Kurze Ereignisse fürs Journal (Bootstrap, Parken, Halbieren), ohne Werte.
    var events: [String]

    var records: Int { liveRecords + backfillRecords }
}
