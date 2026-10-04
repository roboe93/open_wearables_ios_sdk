import Foundation

// Fork-Zusatz (roboe93), Plan 05-06. Der Plan für das Nachholen: je Typ ein Datumsfenster,
// das von neu nach alt abgearbeitet wird.
//
// Der Zustand liegt bewusst in einer eigenen Datei und nie in `SyncState`: der Rückweg auf
// den Upstream-Ablauf (D-13) fände sonst eine halbe Zwei-Spuren-Sitzung vor (Recherche,
// Pitfall 7). `sessionId` dient später als `syncSessionId` der Nachhol-Pakete.
//
// Wie ein Typ nachgeholt wird (Pattern 3, D-06): Beim Bootstrap wird der Anchor für "jetzt"
// festgeschrieben und hier ein Fenster mit offener Obergrenze angelegt (`covered = jetzt +
// openEnd`, Review ME-07). Was danach in Health dazukommt, liefert die Live-Spur über den Anchor.
// Das Nachholen deckt Samples ab, die davor entstanden sind und ein `endDate` im Fenster
// `[floor, covered]` haben, neueste zuerst. Einfügereihenfolge (Anchor) und Datum (Fenster)
// überlappen sich nur, sie unterschneiden sich nie. Eine Überlappung ist harmlos, das Backend
// nimmt Samples idempotent an. Endete das Fenster bei "jetzt", fiele ein Sample, das vor dem
// Bootstrap eingetragen wurde und in der Zukunft endet (vorgetragene Mahlzeit, vorgehende Uhr),
// durch beide Spuren: der Anchor-Durchlauf überspringt es, das Fenster auch.

/// Zeitraster des Plans: ganze Millisekunden.
///
/// HealthKit-Zeitstempel haben Sub-Millisekunden-Anteile, eine JSON-Datei mit ISO-8601-Text
/// hat sie nicht. Wüchse oder schrumpfte `covered` beim Speichern um einen Bruchteil, ginge
/// ein Sample mit identischem `endDate` über eine Chunk-Grenze verloren: der Fensterrand ist
/// inklusiv, und "gleicher Zeitpunkt" muss vor und nach dem Laden dasselbe bedeuten. Deshalb
/// liegen alle Zeitpunkte des Plans auf dem Millisekunden-Raster, und `covered` wird nach oben
/// gerundet, damit es nie unter dem ältesten gelieferten Sample liegt.
enum LaneTime {

    static func ceil(_ date: Date) -> Date {
        fromMilliseconds((date.timeIntervalSince1970 * 1000).rounded(.up))
    }

    static func floor(_ date: Date) -> Date {
        fromMilliseconds((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func round(_ date: Date) -> Date {
        fromMilliseconds((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func fromMilliseconds(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static let wholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// `2026-10-04T08:15:30.123Z`. Die Millisekunden werden von Hand angehängt, weil das Runden
    /// im `ISO8601DateFormatter` nicht festgelegt ist.
    static func string(from date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var seconds = milliseconds / 1000
        var remainder = milliseconds % 1000
        if remainder < 0 {
            remainder += 1000
            seconds -= 1
        }
        let base = wholeSeconds.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(base.dropLast()) + String(format: ".%03dZ", Int(remainder))
    }

    /// Liest `…:30Z` und `…:30.123Z`. Mehr als drei Nachkommastellen werden abgeschnitten.
    static func date(from string: String) -> Date? {
        var base = string
        var fraction: Int64 = 0
        if let dot = string.firstIndex(of: ".") {
            var end = string.index(after: dot)
            while end < string.endIndex, "0123456789".contains(string[end]) {
                end = string.index(after: end)
            }
            let digits = String(string[string.index(after: dot)..<end])
            guard !digits.isEmpty else { return nil }
            base = String(string[..<dot]) + String(string[end...])
            fraction = Int64(String((digits + "000").prefix(3))) ?? 0
        }
        guard let whole = wholeSeconds.date(from: base) else { return nil }
        let milliseconds = Int64(whole.timeIntervalSince1970.rounded()) * 1000 + fraction
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

struct BackfillEntry: Codable, Equatable {

    enum State: String, Codable {
        case pending
        case done
    }

    /// Älteste Grenze des Fensters, inklusiv.
    var floor: Date
    /// Alles zwischen `floor` und `covered` ist noch offen, alles danach (neuer) ist geliefert.
    /// Inklusive Obergrenze der nächsten Abfrage.
    var covered: Date
    var startedAt: Date
    /// Kennungen bereits gelieferter Samples, deren `endDate` genau auf `covered` liegt. Die
    /// nächste Abfrage reicht bis `covered` inklusive und filtert sie wieder heraus.
    var boundaryIds: [String]
    var state: State
    /// `bootstrap`, `adoptedExport`, `reload`.
    var origin: String
}

/// Wie oft ein Typ in einer Spur zuletzt in Folge abgewiesen wurde (siehe `RejectionPolicy`).
struct RejectionState: Codable, Equatable {
    var consecutive: Int
    var limit: Int
    var lastStatus: Int
    var lastCountedAt: Date? = nil
}

struct BackfillPlan: Codable, Equatable {

    static let currentVersion = 1

    /// Wie weit das Fenster über "jetzt" hinausreicht (Review ME-07). 400 Tage statt
    /// `distantFuture`: der Wert übersteht den Weg durch die Datei unverändert und bleibt lesbar.
    static let openEnd: TimeInterval = 400 * 86_400

    /// Obergrenze eines Fensters, das bei `now` angelegt wird: offen, auf dem Millisekunden-Raster.
    static func openUpperBound(_ now: Date) -> Date {
        LaneTime.ceil(now.addingTimeInterval(openEnd))
    }

    var version: Int
    var sessionId: String
    var entries: [String: BackfillEntry]
    /// Schlüssel siehe `rejectionKey(typeId:lane:)`.
    var rejections: [String: RejectionState]

    static func empty() -> BackfillPlan {
        BackfillPlan(version: currentVersion, sessionId: UUID().uuidString, entries: [:], rejections: [:])
    }

    // MARK: Mutatoren

    /// Legt das Nachholen eines Typs an: Fenster von `daysBack` Tagen vor `now`, nach oben offen
    /// (`openUpperBound`, Review ME-07).
    ///
    /// Ein offener Typ behält seinen Stand (kein Neubeginn, sonst ginge der Fortschritt verloren);
    /// ein erledigter Typ beginnt neu.
    /// - Returns: `true`, wenn ein neuer Eintrag entstand.
    @discardableResult
    mutating func start(typeId: String, now: Date, daysBack: Int, origin: String) -> Bool {
        if let existing = entries[typeId], existing.state == .pending { return false }
        entries[typeId] = BackfillEntry(
            floor: LaneTime.floor(now.addingTimeInterval(-Double(daysBack) * 86_400)),
            covered: Self.openUpperBound(now),
            startedAt: LaneTime.round(now),
            boundaryIds: [],
            state: .pending,
            origin: origin
        )
        return true
    }

    /// Rückt `covered` zum Zeitpunkt des ältesten gelieferten Samples vor, also in der Zeit zurück.
    /// Nie vorwärts: ein Schritt in Richtung Gegenwart wird ignoriert. Nie unter `floor`.
    ///
    /// `boundaryIds` sind die Kennungen der gelieferten Samples auf genau diesem Zeitpunkt. Bleibt
    /// `covered` gleich (mehrere Samples mit identischem `endDate` über eine Chunk-Grenze), gelten die
    /// bisherigen Kennungen weiter, die neuen kommen hinzu.
    mutating func advance(typeId: String, to date: Date, boundaryIds: [String]) {
        guard var entry = entries[typeId], entry.state == .pending else { return }
        let target = LaneTime.ceil(date)
        if target > entry.covered { return }
        let next = max(target, entry.floor)
        if next == entry.covered {
            var merged = entry.boundaryIds
            for id in boundaryIds where !merged.contains(id) { merged.append(id) }
            entry.boundaryIds = merged
        } else {
            entry.covered = next
            entry.boundaryIds = boundaryIds
        }
        entries[typeId] = entry
    }

    mutating func markDone(typeId: String) {
        guard var entry = entries[typeId] else { return }
        entry.state = .done
        entry.boundaryIds = []
        entries[typeId] = entry
    }

    /// Übernimmt einen offenen Export des Upstream-Ablaufs: jeder nicht fertige Typ wird
    /// `pending` mit `covered = olderThan ?? now`, Herkunft `adoptedExport`. Fertige Typen
    /// bekommen keinen Eintrag. Bestehende Einträge bleiben unberührt (idempotent, Fortschritt
    /// wird nie überschrieben).
    ///
    /// - Parameter typeIds: alle Typen des offenen Exports. Ohne sie kennt die Übernahme nur
    ///   Typen mit Cursor und verlöre Typen, die der Export noch gar nicht begonnen hatte.
    mutating func adoptOpenExport(
        completedTypes: Set<String>,
        olderThanCursors: [String: Date],
        floor: Date,
        now: Date,
        typeIds: [String] = []
    ) {
        var candidates = Set(olderThanCursors.keys)
        candidates.formUnion(typeIds)
        candidates.subtract(completedTypes)

        for typeId in candidates.sorted() where entries[typeId] == nil {
            entries[typeId] = BackfillEntry(
                floor: LaneTime.floor(floor),
                covered: LaneTime.ceil(olderThanCursors[typeId] ?? now),
                startedAt: LaneTime.round(now),
                boundaryIds: [],
                state: .pending,
                origin: "adoptedExport"
            )
        }
    }

    /// Wiederherstellung nach einem Abbruch zwischen "Plan gespeichert" und "Anchor
    /// festgeschrieben" im Bootstrap: der Typ hat einen offenen Eintrag, aber noch keinen Anchor.
    /// Der neue Anchor gilt für jetzt, deshalb wächst `covered` bis zur offenen Obergrenze ab jetzt,
    /// sonst fehlte, was zwischen beiden Zeitpunkten entstand. Das frühere Fenster bleibt.
    mutating func reanchor(typeId: String, now: Date) {
        guard var entry = entries[typeId], entry.state == .pending else { return }
        let target = Self.openUpperBound(now)
        guard target > entry.covered else { return }
        entry.covered = target
        entry.boundaryIds = []
        entries[typeId] = entry
    }

    // MARK: Abfragen

    var hasPending: Bool {
        entries.values.contains { $0.state == .pending }
    }

    /// Offene Typen, Stufe-A-Typen zuerst (siehe `LaneOrdering`). Die Reihenfolge ist
    /// deterministisch: unbekannte Typen innerhalb einer Stufe stehen alphabetisch.
    func pendingTypeIds(_ ordering: LaneOrdering) -> [String] {
        let pending = entries.filter { $0.value.state == .pending }.map { $0.key }.sorted()
        let split = ordering.split(pending)
        return split.stageA + split.stageB
    }

    // MARK: Ablehnungszustand

    /// Der Zustand gilt je Typ und Spur: ein Giftsample in der einen Spur zählt nicht für die andere.
    static func rejectionKey(typeId: String, lane: Lane) -> String {
        lane == .live ? typeId : "\(typeId)@backfill"
    }

    mutating func clearRejection(typeId: String, lane: Lane) {
        rejections[BackfillPlan.rejectionKey(typeId: typeId, lane: lane)] = nil
    }

    // MARK: Datei

    /// Kodierung der Datei: ISO 8601 mit Millisekunden, damit `devicectl copy from` und
    /// `analyze_runs.py` sie lesen können und Zeitpunkte den Weg über die Platte unverändert überstehen.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LaneTime.string(from: date))
        }
        return encoder
    }

    /// Unbekannte Felder in der Datei brechen das Laden nicht. Ein Datum, das sich nicht lesen
    /// lässt, schon: es wird nie eines erfunden, sonst wüchse oder schrumpfte der offene Bereich.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = LaneTime.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Kein ISO-8601-Datum")
            }
            return date
        }
        return decoder
    }

    func encoded() throws -> Data {
        try BackfillPlan.makeEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> BackfillPlan {
        try makeDecoder().decode(BackfillPlan.self, from: data)
    }
}
