import Foundation

// Fork-Zusatz (roboe93), Plan 05-07. Die dauerhafte Löschwarteschlange (D-12, SYNC-12).
//
// Warum es sie gibt: Eine in Health gelöschte Messung ist flüchtig. Nur ein
// `HKAnchoredObjectQuery` liefert sie, und danach rückt der Anchor weiter. Railway setzt
// Löschungen heute nicht um (Befund 5: kein Handler für `deleted`), der Anchor muss aber
// trotzdem vorrücken. Ohne eigene Ablage wäre die Löschung verloren. Der Kern schreibt sie
// deshalb vor dem Anchor-Commit hierher (`SyncCore.commitLive`). Ein neuer Server (Phase 9)
// kann sie später aus dieser Warteschlange nachliefern.
//
// Datenschutz (T-05-25): Die Datei enthält nur Kennungen, Typen und Zeitpunkte, keine
// Gesundheitswerte. Sie wird nie ins Log geschrieben, dort stehen nur Zahlen.
//
// Format `queue.json` (der Auswerter `scripts/proof/analyze_runs.py` liest genau das):
//
//     { "version": 1,
//       "entries": [ { "id": "<uuid>", "type": "<HK-Identifier>",
//                      "queuedAt": "2026-10-04T08:15:30.123Z",
//                      "sentAt": "2026-10-04T08:16:02.000Z" } ] }   // sentAt fehlt = ungesendet
//
// Zweitziel (Plan 09-04, D-08): Jedes Ziel hat sein eigenes Gesendet-Kennzeichen. `sentAt` gehört
// dem Primärziel, `sentSecondaryAt` dem Zweitziel. Das Feld ist additiv und fehlt, solange es leer
// ist: die Dateiversion bleibt 1, eine Datei ohne `sentSecondaryAt` dekodiert wie bisher.
//
// Gedeckelt nach Anzahl und Alter (Entscheidung vom 04.10.2026). Jedes Kappen steht im Log und
// im Journal (`kind: "deletions"`), mit der Zahl der Einträge, die noch ungesendet waren: das
// ist der eigentliche Verlust, gesendete Einträge zu verlieren kostet nichts.

enum DeletionQueueError: Error, Equatable {
    /// Die Datei ist da, lässt sich aber nicht lesen (Schutzklasse vor dem ersten Entsperren,
    /// Rechte). Sie ist nicht beschädigt und wird deshalb nie umbenannt oder überschrieben.
    case unreadable
}

final class DeletionQueue: DeletionQueueing {

    struct Entry: Codable, Equatable {
        let id: String
        let type: String
        let queuedAt: Date
        var sentAt: Date?
        /// Wann die Löschung dauerhaft in die Outbox des Zweitziels kam. Fehlt = dort ungesendet.
        var sentSecondaryAt: Date?
    }

    private struct FileContent: Codable {
        var version: Int
        var entries: [Entry]
    }

    static let fileVersion = 1

    let directory: URL
    let maxEntries: Int
    let maxAge: TimeInterval

    var fileURL: URL { directory.appendingPathComponent("queue.json") }

    private let clock: LaneClock
    private let journal: RunJournal?
    private let log: (String) -> Void
    /// Das Zweitziel ist aktiv: ein Kappen nennt dann auch, wie viele dort noch ungesendet waren.
    /// Aus: Log und Journal bleiben wie vor 09-04.
    private let tracksSecondary: Bool

    /// Serielle Queue je Datei, für den ganzen Prozess: Lesen, Ändern und Schreiben sind ein
    /// Schritt, auch über Instanzen hinweg (Review LO-07). Zyklus, abgelöster Zyklus und
    /// `getSyncStatus` bauen je eine eigene Instanz.
    private let queue: DispatchQueue

    init(
        directory: URL,
        clock: LaneClock,
        journal: RunJournal?,
        log: @escaping (String) -> Void,
        maxEntries: Int = 50_000,
        maxAge: TimeInterval = 90 * 24 * 3600,
        tracksSecondary: Bool = false
    ) {
        self.directory = directory
        self.tracksSecondary = tracksSecondary
        self.queue = LaneFileLocks.queue(for: directory.appendingPathComponent("queue.json"))
        self.clock = clock
        self.journal = journal
        self.log = log
        self.maxEntries = max(1, maxEntries)
        self.maxAge = maxAge
    }

    // MARK: DeletionQueueing

    /// Hängt Löschungen an. Dieselbe Kennung ergibt einen Eintrag: die früheste `queuedAt` bleibt,
    /// `sentAt` wird gesetzt, wenn eines übergeben wird, und ein gesendeter Eintrag wird nie
    /// wieder ungesendet.
    ///
    /// - Throws: `DeletionQueueError.unreadable` oder einen Schreibfehler. Der Kern hält dann
    ///   den Anchor fest, die Löschung bliebe sonst unbemerkt verloren.
    func enqueue(_ refs: [DeletedRef], sentAt: Date?) throws {
        try enqueue(refs, sentAt: sentAt, sentSecondaryAt: nil)
    }

    /// Wie `enqueue(_:sentAt:)`, dazu das Kennzeichen des Zweitziels (Plan 09-04): Der Sender trägt
    /// die eigenen Löschungen eines Pakets damit ein, sobald das Zweitpaket dauerhaft in der Outbox
    /// liegt. Das geschieht vor dem Kern, der dieselben Einträge danach mit seinem `sentAt` erreicht.
    /// Jedes Kennzeichen wird nur gesetzt, wenn es fehlt, und nie wieder entfernt.
    func enqueue(_ refs: [DeletedRef], sentAt: Date?, sentSecondaryAt: Date?) throws {
        guard !refs.isEmpty else { return }
        try queue.sync {
            guard case .entries(var entries) = loadLocked() else { throw DeletionQueueError.unreadable }

            let now = clock.now()
            var position: [String: Int] = [:]
            for (index, entry) in entries.enumerated() { position[entry.id] = index }

            var changed = false
            for ref in refs {
                if let index = position[ref.id] {
                    if entries[index].sentAt == nil, let sentAt = sentAt {
                        entries[index].sentAt = sentAt
                        changed = true
                    }
                    if entries[index].sentSecondaryAt == nil, let sentSecondaryAt = sentSecondaryAt {
                        entries[index].sentSecondaryAt = sentSecondaryAt
                        changed = true
                    }
                } else {
                    entries.append(Entry(
                        id: ref.id, type: ref.type, queuedAt: now, sentAt: sentAt, sentSecondaryAt: sentSecondaryAt
                    ))
                    position[ref.id] = entries.count - 1
                    changed = true
                }
            }
            guard changed else { return }
            try writeCapped(&entries, now: now)
        }
    }

    // MARK: Abfragen und Markieren

    /// Die ältesten ungesendeten Löschungen zuerst. Eine nicht lesbare Datei ergibt leer: es wird
    /// nie etwas geraten.
    func unsent(limit: Int) -> [DeletedRef] {
        guard limit > 0 else { return [] }
        return queue.sync { () -> [DeletedRef] in
            guard case .entries(let entries) = loadLocked() else { return [] }
            var result: [DeletedRef] = []
            for entry in entries where entry.sentAt == nil {
                result.append(DeletedRef(id: entry.id, type: entry.type))
                if result.count == limit { break }
            }
            return result
        }
    }

    /// Setzt `sentAt` für die genannten Kennungen. Schon gesendete bleiben bei ihrem Zeitpunkt,
    /// unbekannte Kennungen werden übergangen. Ohne Änderung wird nicht geschrieben.
    func markSent(ids: [String], at date: Date) throws {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        try queue.sync {
            guard case .entries(var entries) = loadLocked() else { throw DeletionQueueError.unreadable }

            var changed = false
            for index in entries.indices where entries[index].sentAt == nil && wanted.contains(entries[index].id) {
                entries[index].sentAt = date
                changed = true
            }
            guard changed else { return }
            try writeCapped(&entries, now: clock.now())
        }
    }

    func stats() -> (total: Int, unsent: Int) {
        queue.sync { () -> (total: Int, unsent: Int) in
            guard case .entries(let entries) = loadLocked() else { return (total: 0, unsent: 0) }
            return (total: entries.count, unsent: entries.filter { $0.sentAt == nil }.count)
        }
    }

    // MARK: Zweitziel (Plan 09-04)

    /// Die ältesten fürs Zweitziel ungesendeten Löschungen zuerst. Das Kennzeichen des Primärziels
    /// spielt keine Rolle. Eine nicht lesbare Datei ergibt leer.
    func unsentSecondary(limit: Int) -> [DeletedRef] {
        guard limit > 0 else { return [] }
        return queue.sync { () -> [DeletedRef] in
            guard case .entries(let entries) = loadLocked() else { return [] }
            var result: [DeletedRef] = []
            for entry in entries where entry.sentSecondaryAt == nil {
                result.append(DeletedRef(id: entry.id, type: entry.type))
                if result.count == limit { break }
            }
            return result
        }
    }

    /// Setzt `sentSecondaryAt` für die genannten Kennungen. `sentAt` bleibt unberührt, ein schon
    /// gesetztes Kennzeichen bei seinem Zeitpunkt, unbekannte Kennungen werden übergangen.
    func markSentSecondary(ids: [String], at date: Date) throws {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        try queue.sync {
            guard case .entries(var entries) = loadLocked() else { throw DeletionQueueError.unreadable }

            var changed = false
            for index in entries.indices
            where entries[index].sentSecondaryAt == nil && wanted.contains(entries[index].id) {
                entries[index].sentSecondaryAt = date
                changed = true
            }
            guard changed else { return }
            try writeCapped(&entries, now: clock.now())
        }
    }

    /// Alle Einträge, ältester zuerst. Eine nicht lesbare Datei ergibt leer.
    func entries() -> [Entry] {
        queue.sync { () -> [Entry] in
            guard case .entries(let entries) = loadLocked() else { return [] }
            return entries
        }
    }

    // MARK: Deckel

    private struct Capped {
        var byAge = 0
        var byCount = 0
        var unsent = 0
        /// Fürs Zweitziel ungesendet. Nur genannt, wenn die Warteschlange das Zweitziel führt.
        var unsentSecondary = 0
        var total: Int { byAge + byCount }
    }

    /// Kappt nach Alter und Anzahl und schreibt. Log und Journal folgen erst nach erfolgreichem
    /// Schreiben: eine Meldung über ein Kappen, das nicht stattfand, wäre falsch.
    private func writeCapped(_ entries: inout [Entry], now: Date) throws {
        var capped = Capped()

        let cutoff = now.addingTimeInterval(-maxAge)
        let fresh = entries.filter { $0.queuedAt >= cutoff }
        if fresh.count != entries.count {
            let dropped = entries.filter { $0.queuedAt < cutoff }
            capped.byAge = dropped.count
            capped.unsent += dropped.filter { $0.sentAt == nil }.count
            capped.unsentSecondary += dropped.filter { $0.sentSecondaryAt == nil }.count
            entries = fresh
        }

        if entries.count > maxEntries {
            let overflow = entries.count - maxEntries
            let dropped = entries.prefix(overflow)
            capped.byCount = overflow
            capped.unsent += dropped.filter { $0.sentAt == nil }.count
            capped.unsentSecondary += dropped.filter { $0.sentSecondaryAt == nil }.count
            entries.removeFirst(overflow)
        }

        let data = try encode(FileContent(version: Self.fileVersion, entries: entries))
        try LaneFiles.writeAtomically(data, to: fileURL)

        if capped.total > 0 { report(capped, at: now) }
    }

    private func report(_ capped: Capped, at date: Date) {
        let reason: String
        let label: String
        switch (capped.byAge > 0, capped.byCount > 0) {
        case (true, true): reason = "age+count"; label = "Alter und Anzahl"
        case (true, false): reason = "age"; label = "Alter"
        default: reason = "count"; label = "Anzahl"
        }
        var line = "Löschwarteschlange gekappt: \(capped.total) Einträge (\(label)), davon \(capped.unsent) ungesendet"
        var note = "capped reason=\(reason) unsent=\(capped.unsent)"
        if tracksSecondary {
            line += ", fürs Zweitziel \(capped.unsentSecondary) ungesendet"
            note += " unsentSecondary=\(capped.unsentSecondary)"
        }
        log(line)
        journal?.record(SyncJournalEntry(
            at: date,
            kind: JournalKind.deletions,
            deletions: capped.total,
            note: note
        ))
    }

    // MARK: Platte

    private enum Loaded {
        case entries([Entry])
        case unreadable
    }

    private func loadLocked() -> Loaded {
        switch LaneFiles.read(fileURL) {
        case .missing:
            return .entries([])
        case .unreadable:
            return .unreadable
        case .data(let data):
            if let content = try? decoder().decode(FileContent.self, from: data) {
                return .entries(content.entries)
            }
            // Lesbar, aber kein gültiger Inhalt: umbenennen statt löschen, danach von vorn.
            guard let aside = LaneFiles.moveAside(fileURL, now: clock.now()) else {
                // Das Beiseitelegen scheiterte. Weiterzuschreiben hiesse, den Inhalt zu überschreiben.
                return .unreadable
            }
            log("Löschwarteschlange beschädigt: Datei als \(aside.lastPathComponent) beiseitegelegt, neue Warteschlange beginnt leer")
            journal?.record(SyncJournalEntry(
                at: clock.now(), kind: JournalKind.deletions, note: "corrupt: moved aside"
            ))
            return .entries([])
        }
    }

    private func decoder() -> JSONDecoder {
        BackfillPlan.makeDecoder()
    }

    /// Kompakt statt eingerückt: bei 50.000 Einträgen entscheidet das über Megabytes. Gleiche
    /// Zeitdarstellung wie `backfill.json` (ISO 8601 mit Millisekunden).
    private func encode(_ content: FileContent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LaneTime.string(from: date))
        }
        return try encoder.encode(content)
    }
}
