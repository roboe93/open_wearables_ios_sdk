import Foundation
import UIKit

// Fork-Zusatz (roboe93). Persistiertes Lauf- und Wake-Journal.
//
// Warum es das gibt (Messung am iPhone 18 Pro, 04.10.2026, Befund 10): Seit dem 03.10.
// 19:32 stand weder in den Anchors noch im App-Protokoll ein einziger Schreibzugriff, und
// die Läufe, die das SDK selbst startet (Observer, SDK-BGTasks), erscheinen im App-Protokoll
// gar nicht. Ob iOS die App nicht weckt, ob sie weggewischt wurde oder ob die
// Hintergrundaktualisierung aus ist, lässt sich nur messen. Das Journal hält je Lauf, je
// Weckruf und je Adoption einen Eintrag fest, im App-Container, per `devicectl copy from`
// lesbar (`scripts/proof/pull-container.sh`, `scripts/proof/analyze_runs.py`).
//
// Datenschutz (Bedrohung T-05-09): Ein Eintrag enthält nur Typnamen, Zählungen,
// Zeitpunkte und Status. Keine Gesundheitswerte, keine User-ID, kein Token, keine URL.
// Wer einen Eintrag erweitert, hält das ein.

/// Ein Eintrag im Journal. Die Swift-Namen sind identisch zu den JSON-Schlüsseln; alle
/// Felder außer `at` und `kind` sind optional und fehlen in der Datei, wenn sie leer sind.
///
/// `kind` ist ein String statt eines Enums, damit ein Wert aus einer künftigen Version
/// lesbar bleibt: `run`, `lease`, `adoption`, `delivery`, `wake`, `switch`, `backfill`,
/// `deletions`, `spike`, `rejected`.
public struct SyncJournalEntry: Codable, Equatable, Sendable {
    /// Zeitpunkt des Eintrags. Bei `run` das Ende des Laufs.
    public var at: Date
    public var kind: String
    /// `SyncTrigger.journalValue`, etwa `observer:HKQuantityTypeIdentifierHeartRate`.
    public var trigger: String?
    /// `lanes` oder `upstream`.
    public var orchestration: String?
    /// `SyncOutcome.statusKey`.
    public var status: String?
    public var records: Int?
    public var live: Int?
    public var backfill: Int?
    public var deletions: Int?
    /// War HealthKit zu Beginn lesbar (`isProtectedDataAvailable`)? Bei Weckrufen: beim Weckruf.
    public var protectedStart: Bool?
    public var protectedEnd: Bool?
    public var lowPower: Bool?
    public var backfillPending: Bool?
    public var leaseTakenOver: Bool?
    /// `available`, `denied` oder `restricted` (`UIApplication.backgroundRefreshStatus`).
    public var bgRefresh: String?
    public var durationMs: Int?
    public var note: String?
    /// Bei `run`: `handedOver`, wenn der Eintrag die Antwort an einen übergebenen Auslöser ist. Seine
    /// Zahlen stehen im `run`-Eintrag des Zyklus noch einmal (Review ME-06). Fehlt bei ganzen Läufen.
    public var scope: String?

    public init(
        at: Date,
        kind: String,
        trigger: String? = nil,
        orchestration: String? = nil,
        status: String? = nil,
        records: Int? = nil,
        live: Int? = nil,
        backfill: Int? = nil,
        deletions: Int? = nil,
        protectedStart: Bool? = nil,
        protectedEnd: Bool? = nil,
        lowPower: Bool? = nil,
        backfillPending: Bool? = nil,
        leaseTakenOver: Bool? = nil,
        bgRefresh: String? = nil,
        durationMs: Int? = nil,
        note: String? = nil,
        scope: String? = nil
    ) {
        self.at = at
        self.kind = kind
        self.trigger = trigger
        self.orchestration = orchestration
        self.status = status
        self.records = records
        self.live = live
        self.backfill = backfill
        self.deletions = deletions
        self.protectedStart = protectedStart
        self.protectedEnd = protectedEnd
        self.lowPower = lowPower
        self.backfillPending = backfillPending
        self.leaseTakenOver = leaseTakenOver
        self.bgRefresh = bgRefresh
        self.durationMs = durationMs
        self.note = note
        self.scope = scope
    }
}

/// Die Einträge, die das SDK schreibt.
internal enum JournalKind {
    static let run = "run"
    static let wake = "wake"
    static let adoption = "adoption"
    static let delivery = "delivery"
    static let lease = "lease"
    /// Löschwarteschlange: Kappen nach Alter oder Anzahl, beschädigte Datei beiseitegelegt (Plan 05-07).
    static let deletions = "deletions"
}

/// Ring aus den jüngsten Einträgen, atomar in eine JSON-Datei geschrieben.
///
/// Gelesen wird vor jedem Schreiben von der Platte statt aus einem Cache: so kann ein zweiter
/// Schreiber (zweite Instanz, späterer Prozess) keinen fremden Eintrag überschreiben.
internal final class RunJournal {

    static let defaultCapacity = 200

    let directory: URL
    let capacity: Int

    var fileURL: URL { directory.appendingPathComponent("journal.json") }

    /// Serielle Queue: Lesen, Anhängen und Schreiben sind ein Schritt.
    private let queue = DispatchQueue(label: "health_journal")

    /// Einträge, die nicht geschrieben werden konnten, weil die Datei existiert, sich aber nicht
    /// lesen ließ (Schutzklasse vor dem ersten Entsperren nach dem Neustart). Sie bleiben im
    /// Speicher und gehen beim nächsten Schreiben mit raus. Nie wird eine nicht lesbare Datei
    /// mit einem Journal überschrieben, das nur den neuesten Eintrag kennt.
    private var pending: [SyncJournalEntry] = []

    init(directory: URL, capacity: Int = RunJournal.defaultCapacity) {
        self.directory = directory
        self.capacity = max(1, capacity)
    }

    /// Hängt einen Eintrag an. Das Schreiben ist synchron auf der eigenen Queue, damit ein
    /// Eintrag, den ein Hintergrundlauf unmittelbar vor dem Ende des BGTasks schreibt, auch
    /// auf der Platte liegt, bevor das System den Prozess anhält. Fehler beim Schreiben sind
    /// still: ein Journal darf den Sync nie stören.
    func record(_ entry: SyncJournalEntry) {
        queue.sync {
            switch loadLocked() {
            case .unreadable:
                pending.append(entry)
                if pending.count > capacity { pending.removeFirst(pending.count - capacity) }
            case .entries(let existing):
                var all = existing + pending + [entry]
                if all.count > capacity { all.removeFirst(all.count - capacity) }
                if write(all) { pending.removeAll() }
            }
        }
    }

    /// Alle gespeicherten Einträge, ältester zuerst. Nicht lesbar oder fehlend ergibt leer.
    func entries() -> [SyncJournalEntry] {
        queue.sync {
            if case .entries(let list) = loadLocked() { return list }
            return []
        }
    }

    // MARK: - Platte

    private enum Loaded {
        case entries([SyncJournalEntry])
        case unreadable
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Ein Element, dessen Dekodieren nie wirft: ein kaputter Eintrag fällt allein heraus.
    private struct Lossy: Decodable {
        let entry: SyncJournalEntry?
        init(from decoder: Decoder) throws {
            entry = try? SyncJournalEntry(from: decoder)
        }
    }

    private func loadLocked() -> Loaded {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .entries([]) }

        guard let data = try? Data(contentsOf: fileURL) else {
            // Die Datei ist da, aber nicht lesbar (Schutzklasse): nicht anfassen.
            return .unreadable
        }

        guard let items = try? decoder().decode([Lossy].self, from: data) else {
            moveUnreadableFileAside()
            return .entries([])
        }
        return .entries(items.compactMap { $0.entry })
    }

    /// Eine lesbare Datei, die kein Journal ist, wird beiseitegelegt statt überschrieben.
    /// Es bleibt höchstens eine solche Datei stehen, die neueste.
    private func moveUnreadableFileAside() {
        let aside = directory.appendingPathComponent("journal.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: fileURL, to: aside)
    }

    /// Schreibt atomar. Schutzklasse `completeUntilFirstUserAuthentication`: Hintergrundläufe
    /// nach dem ersten Entsperren müssen schreiben können, `.complete` ließe sie bei
    /// gesperrtem iPhone scheitern, und gerade diese Läufe will das Journal sehen.
    private func write(_ entries: [SyncJournalEntry]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return false }

        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: protection
            )
            try data.write(to: fileURL, options: [.atomic])
            // Atomares Schreiben ersetzt die Datei, die Schutzklasse gehört danach neu gesetzt.
            try? FileManager.default.setAttributes(protection, ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Zusammenfassung der Hintergrundzustellung

/// Sammelt die Antworten von `enableBackgroundDelivery` je Typ. Daraus entsteht **ein**
/// Journal-Eintrag statt 52, damit der Ring nicht volläuft.
internal final class DeliveryTally {
    private let lock = NSLock()
    private var okCount = 0
    private var failedNames: [String] = []

    /// Wie viele Namen im Eintrag stehen, der Rest wird als `+n` gezählt.
    private static let nameLimit = 12

    func record(shortName: String, success: Bool) {
        lock.lock()
        if success { okCount += 1 } else { failedNames.append(shortName) }
        lock.unlock()
    }

    /// `ok=<n> failed=<kurznamen>`, ohne Fehlschläge `failed=none`.
    var note: String {
        lock.lock()
        defer { lock.unlock() }
        guard !failedNames.isEmpty else { return "ok=\(okCount) failed=none" }
        let sorted = failedNames.sorted()
        var shown = sorted.prefix(Self.nameLimit).joined(separator: ",")
        if sorted.count > Self.nameLimit { shown += ",+\(sorted.count - Self.nameLimit)" }
        return "ok=\(okCount) failed=\(shown)"
    }
}

// MARK: - Anbindung im SDK

extension OpenWearablesHealthSDK {

    /// Das Journal im aktuellen Zustandsverzeichnis. Der Cache hängt am Verzeichnis, nicht
    /// am ersten Zugriff: Tests wechseln `stateDirectoryOverride` je Test.
    internal var runJournal: RunJournal {
        let directory = stateBaseDirectory().appendingPathComponent("health_journal", isDirectory: true)
        runJournalLock.lock()
        defer { runJournalLock.unlock() }
        if let cached = runJournalCache, cached.directory == directory { return cached }
        let journal = RunJournal(directory: directory)
        runJournalCache = journal
        return journal
    }

    /// Die jüngsten Einträge des Laufjournals, ältester zuerst.
    ///
    /// Nur Typnamen, Zählungen, Zeitpunkte und Status, keine Gesundheitswerte. Die Datei
    /// liegt unter `journalFileURL` im App-Container.
    public func journalEntries(limit: Int = 200) -> [SyncJournalEntry] {
        guard limit > 0 else { return [] }
        return Array(runJournal.entries().suffix(limit))
    }

    /// Pfad der Journaldatei (`Application Support/health_journal/journal.json`).
    public var journalFileURL: URL {
        runJournal.fileURL
    }

    // MARK: Zustands-Caches

    /// Zuletzt bekannter Sperrzustand: `true` heißt, HealthKit ist lesbar. `nil` heißt unbekannt.
    ///
    /// `UIApplication` darf nur auf der Hauptschlange gelesen werden, ein Lauf auf einem
    /// Hintergrund-Thread liest deshalb diesen Cache, gepflegt von den Benachrichtigungen.
    internal var protectedDataAvailableCache: Bool? {
        get {
            stateCacheLock.lock()
            defer { stateCacheLock.unlock() }
            return protectedDataAvailableValue
        }
        set {
            stateCacheLock.lock()
            protectedDataAvailableValue = newValue
            stateCacheLock.unlock()
        }
    }

    /// `available`, `denied`, `restricted` oder `nil` (unbekannt).
    internal var backgroundRefreshStatusCache: String? {
        get {
            stateCacheLock.lock()
            defer { stateCacheLock.unlock() }
            return backgroundRefreshStatusValue
        }
        set {
            stateCacheLock.lock()
            backgroundRefreshStatusValue = newValue
            stateCacheLock.unlock()
        }
    }

    /// Liest Sperrzustand und Hintergrundaktualisierung auf der Hauptschlange. Tests rufen
    /// das nie auf, sie setzen die Caches direkt.
    internal func refreshDeviceStateCaches() {
        let read = { [weak self] in
            guard let self = self else { return }
            self.protectedDataAvailableCache = UIApplication.shared.isProtectedDataAvailable
            self.refreshBackgroundRefreshStatusCache()
        }
        if Thread.isMainThread {
            read()
        } else {
            DispatchQueue.main.async(execute: read)
        }
    }

    /// Nur auf der Hauptschlange.
    internal func refreshBackgroundRefreshStatusCache() {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: backgroundRefreshStatusCache = "available"
        case .denied: backgroundRefreshStatusCache = "denied"
        case .restricted: backgroundRefreshStatusCache = "restricted"
        @unknown default: backgroundRefreshStatusCache = "unknown"
        }
    }

    /// Beobachtet die Hintergrundaktualisierung und hält fest, ob die App im Hintergrund
    /// gestartet wurde. Aus `configure` aufgerufen.
    internal func observeDeviceStateAndLaunch() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshDeviceStateCaches()

            if self.backgroundRefreshObserver == nil {
                self.backgroundRefreshObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.backgroundRefreshStatusDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.refreshBackgroundRefreshStatusCache()
                }
            }

            // Ein Start im Hintergrund ist der Weckruf, den Befund 10 sucht.
            if UIApplication.shared.applicationState == .background {
                self.journalWake(trigger: nil, note: "launch:background")
            }
        }
    }

    // MARK: Einträge

    /// Weckruf: SDK-BGTask, Entsperren, Start im Hintergrund oder ein verworfener Observer.
    /// Hält Sperrzustand, Hintergrundaktualisierung und Energiesparmodus zum Zeitpunkt fest.
    internal func journalWake(trigger: String?, note: String?) {
        runJournal.record(SyncJournalEntry(
            at: Date(),
            kind: JournalKind.wake,
            trigger: trigger,
            protectedStart: protectedDataAvailableCache,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            bgRefresh: backgroundRefreshStatusCache,
            note: note
        ))
    }

    /// Ein Lauf hat den Slot an einen neuen verloren (Plan 05-06). Der Grund ist `leaseExpired`
    /// (Frist ohne Lebenszeichen) oder `cancelled` (abgebrochen und nie zurückgekehrt), dazu die
    /// beiden Generationen. Nur Zahlen und Kurzwörter, keine Werte.
    internal func journalLeaseTakeover(reason: String, previousGeneration: Int, newGeneration: Int, at date: Date) {
        runJournal.record(SyncJournalEntry(
            at: date,
            kind: JournalKind.lease,
            leaseTakenOver: true,
            note: "takeover:\(reason) previous=\(previousGeneration) new=\(newGeneration)"
        ))
    }

    /// Ende eines Laufs. `protectedStart` ist der Sperrzustand bei Beginn, der Wert bei
    /// Ende kommt aus dem Cache.
    ///
    /// `note` (Plan 05-08) trägt die Ereignisse des Kerns, die keinen eigenen Eintrag haben
    /// (gesperrt, Lesefehler), als Kurznamen. Der Upstream-Pfad übergibt keinen.
    internal func journalRun(_ outcome: SyncOutcome, protectedStart: Bool?, note: String? = nil) {
        runJournal.record(SyncJournalEntry(
            at: outcome.finished,
            kind: JournalKind.run,
            trigger: outcome.trigger.journalValue,
            orchestration: outcome.orchestration.rawValue,
            status: outcome.statusKey,
            records: outcome.records,
            live: outcome.liveRecords,
            backfill: outcome.backfillRecords,
            deletions: outcome.deletionsQueued,
            protectedStart: protectedStart,
            protectedEnd: protectedDataAvailableCache,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            backfillPending: outcome.backfillPending,
            leaseTakenOver: outcome.leaseTakenOver,
            bgRefresh: backgroundRefreshStatusCache,
            durationMs: max(0, Int(outcome.finished.timeIntervalSince(outcome.started) * 1000)),
            note: note,
            scope: outcome.scope == .handedOver ? SyncOutcome.Scope.handedOver.rawValue : nil
        ))
    }
}
