import Foundation

// Fork-Zusatz (roboe93), Plan 09-03 (D-08). Das Zweitziel: dieselben Pakete zusätzlich an einen
// zweiten Server, mit eigener Datei-Outbox.
//
// Eingehängt seit 09-04: `PayloadSink` reiht nach dem 2xx des Primärziels ein, hinter dem Schalter
// `lanes.secondary.enabled` (Standard aus), nur im Modus `lanes`. Die Bausteine:
//
//   - `SecondaryOutbox`: Dateien unter `health_secondary/outbox/`, Reihenfolge nach Dateiname,
//     `dead/` für Aufgegebenes, Deckel nach Größe und Alter. Nie stilles Löschen: was nicht
//     zugestellt wird, liegt in `dead/` und ist gezählt (`gapCount`). Seit ow.5 hat auch `dead/`
//     einen Deckel (50 MB, 30 Tage ab dem Verschieben). Darüber werden die ältesten Dateien
//     gelöscht und gezählt (`deadDropped`); das Primärziel hat diese Pakete ohnehin.
//   - `SecondaryPolicy`: rein, entscheidet aus Status und Zeitpunkt.
//   - `SecondaryUploader`: eigene `URLSession`, seriell, ein Durchlauf je Ordner zur selben Zeit.
//
// Anchors hängen nur am Primärziel. Das Zweitziel berührt nie Cursor, Anmeldung oder Primärpfad:
// 401 und 403 pausieren nur das Zweitziel, ohne Abmeldung, ohne Auth-Rückruf an die App und ohne
// Token-Refresh. Seit ow.5 mit wachsender Wartezeit (1 min, 5 min, 30 min, 2 h, dann 6 h), damit
// ein falscher Schlüssel nicht bei jedem Anstoß ein volles Paket kostet. Die Hintergrund-Session des SDK wird nie benutzt: ihr Delegate liest
// `taskDescription` als Eintrag der alten Outbox und würde Dateien nach deren Regeln löschen.
//
// Datenschutz (LO-12): Ins Log gehen nur Zahlen und Statuscodes, nie Ladung oder Antworttext.

// MARK: - Ziel

struct SecondaryTarget: Equatable {
    let host: URL
    let apiKey: String
    let userId: String

    /// `<host>/api/v1/sdk/users/<userId>/sync`, derselbe Weg wie beim Primärziel.
    var endpoint: URL {
        ["api", "v1", "sdk", "users", userId, "sync"].reduce(host) { $0.appendingPathComponent($1) }
    }
}

extension OpenWearablesHealthSDK {
    /// `health_secondary/` neben den übrigen Zustandsordnern.
    internal func secondaryDirectory() -> URL {
        stateBaseDirectory().appendingPathComponent("health_secondary", isDirectory: true)
    }

    // MARK: Einhängen (Plan 09-04)

    /// Host und Schlüssel aus dem Keychain, wenn beide brauchbar sind: ein absoluter http(s)-Host
    /// und ein nicht leerer Schlüssel.
    internal func secondaryCredentials() -> (host: URL, apiKey: String)? {
        guard let hostText = OpenWearablesHealthSdkKeychain.getSecondaryHost(),
              let host = Self.absoluteHTTPURL(from: hostText),
              let apiKey = OpenWearablesHealthSdkKeychain.getSecondaryApiKey()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return nil }
        return (host, apiKey)
    }

    /// Das Ziel für den Sender: Zugangsdaten des Zweitziels und der Nutzer des Primärziels.
    internal func secondaryTarget() -> SecondaryTarget? {
        guard let credentials = secondaryCredentials(), let userId = userId else { return nil }
        return SecondaryTarget(host: credentials.host, apiKey: credentials.apiKey, userId: userId)
    }

    /// D-08: Das Zweitziel wirkt nur, wenn der Schalter an ist (Standard aus), ein Ziel konfiguriert
    /// ist und der Modus `lanes` gilt. Im Modus `upstream` ruht es, vorhandene Dateien bleiben liegen
    /// (Recherche, Dual-Sink Punkt 2).
    internal var isSecondarySinkActive: Bool {
        lanesSecondaryEnabled && orchestration == .lanes && secondaryTarget() != nil
    }

    /// Eine Instanz über `health_secondary/`. Legt nichts an: Ordner entstehen erst beim Einreihen.
    internal func makeSecondaryOutbox() -> SecondaryOutbox {
        SecondaryOutbox(baseDirectory: secondaryDirectory(), log: { [weak self] in self?.logMessage($0) })
    }

    /// Stößt einen Durchlauf des Zweitziel-Senders an, nie blockierend (T-09-14): Die Arbeit läuft
    /// auf einer Hintergrund-Queue, der Aufrufer wartet nicht. Ohne aktives Zweitziel geschieht nichts,
    /// auch kein Zugriff auf `health_secondary/`. Zwei Anstöße zugleich senden nichts doppelt, der
    /// zweite meldet `skipped` (`SecondaryUploader`).
    ///
    /// Angestoßen wird nach jedem lanes-Zyklus (`trigger` `cycle`, mit den Zahlen seines Senders), bei
    /// der Rückkehr in den Vordergrund und wenn das Netz wieder da ist. Nach 401/403 sendet erst ein
    /// Anstoß nach Ablauf der Wartezeit wieder (`SecondaryState.pausedUntil`, ow.5).
    internal func drainSecondaryIfActive(
        trigger: String, enqueued: Int = 0, enqueueFailed: Int = 0,
        completion: ((SecondaryDrainResult?) -> Void)? = nil
    ) {
        guard lanesSecondaryEnabled, orchestration == .lanes, let target = secondaryTarget() else {
            completion?(nil)
            return
        }
        let outbox = makeSecondaryOutbox()
        let uploader = SecondaryUploader(
            outbox: outbox,
            session: secondarySessionOverride ?? SecondaryUploader.sharedSession,
            log: { [weak self] in self?.logMessage($0) }
        )
        DispatchQueue.global(qos: .utility).async { [weak self] in
            uploader.drain(target: target) { result in
                self?.journalSecondary(
                    result, trigger: trigger, enqueued: enqueued, enqueueFailed: enqueueFailed,
                    queued: outbox.counts().queued, state: outbox.state()
                )
                completion?(result)
            }
        }
    }

    /// Ein Journal-Eintrag je Durchlauf mit Wirkung (Art `secondary`): nur Zahlen und als Status der
    /// Kurztext des letzten Fehlers (`HTTP 503`, `auth 401`), `waiting` während der Wartezeit nach
    /// 401/403 oder `ok`. Kein Host, kein Schlüssel, kein Nutzer, keine Ladung (T-09-13). Ein
    /// Durchlauf ohne jede Wirkung schreibt nichts, sonst liefe der Ring (200) mit leeren Einträgen
    /// voll.
    ///
    /// Seit ow.5 trägt die Notiz `deadDropped` (Summe der aus `dead/` gelöschten Pakete) und während
    /// einer Wartezeit `waitUntil=<ISO 8601>`.
    private func journalSecondary(
        _ result: SecondaryDrainResult, trigger: String, enqueued: Int, enqueueFailed: Int, queued: Int,
        state: SecondaryState
    ) {
        let acted = result.delivered + result.retried + result.dead + result.dropped > 0
            || result.paused || result.lastError != nil
        guard acted || enqueued > 0 || enqueueFailed > 0 else { return }
        let status: String
        if result.skipped {
            status = "skipped"
        } else if let error = result.lastError {
            status = error
        } else {
            status = result.pausedUntil == nil ? "ok" : "waiting"
        }
        var note = "delivered=\(result.delivered) retried=\(result.retried) dead=\(result.dead) "
            + "paused=\(result.paused ? 1 : 0) queued=\(queued) enqueued=\(enqueued) failed=\(enqueueFailed) "
            + "deadDropped=\(state.deadDropped)"
        if let until = result.pausedUntil {
            note += " authFailures=\(state.authFailures) waitUntil=\(ISO8601DateFormatter().string(from: until))"
        }
        runJournal.record(SyncJournalEntry(
            at: Date(),
            kind: JournalKind.secondary,
            trigger: trigger,
            status: status,
            records: result.delivered,
            note: note
        ))
    }

    /// Entfernt `health_secondary/` ganz: Outbox, `dead/` und Zustand. Nur für `signOut`, die Dateien
    /// gehören dem abgemeldeten Nutzer.
    internal func clearSecondaryOutbox() {
        let directory = secondaryDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            logMessage("Cleared secondary outbox")
        } catch {
            logDiagnostic("Secondary: outbox could not be cleared")
        }
    }
}

// MARK: - Zustand

/// Gedächtnis je Datei der Outbox.
struct SecondaryFileState: Codable, Equatable {
    /// Gezählte Ablehnungen (400, 413, 422), höchstens eine je `SecondaryPolicy.countSpacing`.
    var rejections: [Date] = []
    /// Vorübergehende Fehler in Folge (5xx, 429, Netz, übrige 4xx), Grundlage des Backoffs.
    var failures: Int = 0
    /// Vorher wird die Datei nicht gesendet; der Durchlauf endet an ihr.
    var nextAttemptAt: Date?
    var lastStatus: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rejections = try container.decodeIfPresent([Date].self, forKey: .rejections) ?? []
        failures = try container.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        lastStatus = try container.decodeIfPresent(Int.self, forKey: .lastStatus)
    }
}

/// `health_secondary/state.json`.
struct SecondaryState: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = SecondaryState.currentVersion
    /// Schlüssel ist der Dateiname in `outbox/`.
    var files: [String: SecondaryFileState] = [:]
    /// Pakete, die das Zweitziel nie erreichen: vom Deckel nach `dead/` verschoben oder gar nicht
    /// erst einreihbar (Plan 09-04). Eine Lücke im Zweitziel.
    var gapCount: Int = 0
    var lastGapAt: Date?
    var lastSuccessAt: Date?
    /// Kurz und ohne Inhalt: `HTTP 503`, `auth 401`, `network(-1009)`.
    var lastError: String?
    /// 401/403 in Folge (ow.5), Grundlage der Wartezeit. Null nach einem 2xx und nach einer
    /// geänderten Konfiguration (`configureSecondarySink` mit anderem Host oder Schlüssel).
    var authFailures: Int = 0
    /// Nach 401/403 sendet der Sender bis dahin nichts an das Zweitziel (ow.5).
    var pausedUntil: Date?
    /// Aus `dead/` gelöschte Pakete (Deckel 50 MB, 30 Tage, ow.5). Summe, bis `signOut` den Ordner
    /// entfernt.
    var deadDropped: Int = 0

    init() {}

    // Die Felder aus ow.5 sind additiv: eine Datei aus ow.4 dekodiert, die Dateiversion bleibt 1.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? SecondaryState.currentVersion
        files = try container.decodeIfPresent([String: SecondaryFileState].self, forKey: .files) ?? [:]
        gapCount = try container.decodeIfPresent(Int.self, forKey: .gapCount) ?? 0
        lastGapAt = try container.decodeIfPresent(Date.self, forKey: .lastGapAt)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        authFailures = try container.decodeIfPresent(Int.self, forKey: .authFailures) ?? 0
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        deadDropped = try container.decodeIfPresent(Int.self, forKey: .deadDropped) ?? 0
    }
}

// MARK: - Wiederholungspolitik

enum SecondaryDecision: Equatable {
    /// 2xx: die Datei ist zugestellt und wird entfernt.
    case delivered
    /// Später erneut; der Durchlauf endet hier, die Reihenfolge bleibt.
    case retry(after: TimeInterval)
    /// 401/403: das Zweitziel ruht für die Wartezeit (`SecondaryPolicy.authWait`). Die Datei bleibt.
    case pause(authStatus: Int)
    /// Dritte gezählte Ablehnung: nach `dead/`, der Durchlauf geht mit der nächsten Datei weiter.
    case dead
}

/// Rein: Zustand rein, Entscheidung raus, die Uhr kommt als `now`.
///
/// Dieselbe Einstufung wie im Primärpfad (`RejectionPolicy.isRecordSpecific`): nur 400, 413 und 422
/// sind ein Urteil über das Paket. Drei davon im Abstand von je mindestens einer Stunde schicken es
/// nach `dead/`; eine Ablehnung innerhalb des Abstands zählt nicht und wartet bis zu seinem Ende.
/// Alles andere (5xx, 429, Netz, übrige 4xx) wird mit Backoff wiederholt: 1 Minute, verdoppelnd,
/// höchstens 1 Stunde. 401 und 403 betreffen das ganze Ziel, nicht das Paket: dafür gilt die
/// Staffel `authWaitSteps` (ow.5), im Zustand der Outbox und nicht je Datei.
struct SecondaryPolicy {
    static let initialBackoff: TimeInterval = 60
    static let maxBackoff: TimeInterval = 3600
    /// Wartezeit nach der 1., 2., 3., 4. und jeder weiteren Ablehnung mit 401/403 in Folge.
    static let authWaitSteps: [TimeInterval] = [60, 300, 1800, 7200, 21600]
    static let deadAfter = RejectionPolicy.parkAfter
    static let countSpacing = RejectionPolicy.countSpacing

    private(set) var state: SecondaryFileState

    init(state: SecondaryFileState = SecondaryFileState()) {
        self.state = state
    }

    mutating func decide(status: Int?, error: Bool, now: Date) -> SecondaryDecision {
        if !error, let status = status {
            if (200...299).contains(status) {
                state = SecondaryFileState()
                return .delivered
            }
            if status == 401 || status == 403 {
                state.lastStatus = status
                return .pause(authStatus: status)
            }
            if RejectionPolicy.isRecordSpecific(status) {
                state.lastStatus = status
                if let last = state.rejections.last {
                    let elapsed = now.timeIntervalSince(last)
                    if elapsed < Self.countSpacing {
                        let wait = Self.countSpacing - elapsed
                        state.nextAttemptAt = now.addingTimeInterval(wait)
                        return .retry(after: wait)
                    }
                }
                state.rejections.append(now)
                if state.rejections.count >= Self.deadAfter {
                    state.nextAttemptAt = nil
                    return .dead
                }
                state.nextAttemptAt = now.addingTimeInterval(Self.countSpacing)
                return .retry(after: Self.countSpacing)
            }
        }

        state.failures += 1
        state.lastStatus = error ? nil : status
        let delay = Self.backoff(afterFailures: state.failures)
        state.nextAttemptAt = now.addingTimeInterval(delay)
        return .retry(after: delay)
    }

    static func backoff(afterFailures failures: Int) -> TimeInterval {
        let exponent = min(max(failures - 1, 0), 16)
        return min(initialBackoff * pow(2, Double(exponent)), maxBackoff)
    }

    /// 1 min, 5 min, 30 min, 2 h, danach immer 6 h.
    static func authWait(afterFailures failures: Int) -> TimeInterval {
        authWaitSteps[min(max(failures - 1, 0), authWaitSteps.count - 1)]
    }
}

// MARK: - Outbox

/// Die Datei-Outbox des Zweitziels. Basis `health_secondary/`, darin `outbox/`, `dead/` und
/// `state.json`. Jede Datei ist ein fertiges Paket, so wie es hinausgeht.
///
/// Dateiname `<Millisekunden, 15 Stellen>-<UUID>.json`. Die Reihenfolge ist die des Namens; steht die
/// Uhr still oder läuft sie zurück, bekommt das neue Paket den Zeitstempel des letzten plus eins.
final class SecondaryOutbox {

    enum StoreError: Error, Equatable {
        /// `state.json` ist da, lässt sich aber nicht lesen (Schutzklasse, Rechte). Sie wird nie
        /// überschrieben.
        case unreadable
    }

    static let defaultMaxBytes = 200 * 1024 * 1024
    static let defaultMaxAge: TimeInterval = 30 * 24 * 3600
    /// Deckel für `dead/` (ow.5). Gemessen wird ab dem Verschieben, nicht ab dem Einreihen.
    static let defaultMaxDeadBytes = 50 * 1024 * 1024
    static let defaultMaxDeadAge: TimeInterval = 30 * 24 * 3600

    let baseDirectory: URL
    let maxBytes: Int
    let maxAge: TimeInterval
    let maxDeadBytes: Int
    let maxDeadAge: TimeInterval

    var outboxDirectory: URL { baseDirectory.appendingPathComponent("outbox", isDirectory: true) }
    var deadDirectory: URL { baseDirectory.appendingPathComponent("dead", isDirectory: true) }
    var stateURL: URL { baseDirectory.appendingPathComponent("state.json") }

    private let clock: LaneClock
    private let log: (String) -> Void
    /// Prozessweit je Ordner (`LaneFileLocks`): Einreihen, Deckel, Verschieben und Zustand sind je
    /// ein Schritt, auch wenn mehrere Instanzen denselben Ordner benutzen.
    private let lock: NSRecursiveLock

    init(
        baseDirectory: URL,
        clock: LaneClock = SystemLaneClock(),
        log: @escaping (String) -> Void = { _ in },
        maxBytes: Int = SecondaryOutbox.defaultMaxBytes,
        maxAge: TimeInterval = SecondaryOutbox.defaultMaxAge,
        maxDeadBytes: Int = SecondaryOutbox.defaultMaxDeadBytes,
        maxDeadAge: TimeInterval = SecondaryOutbox.defaultMaxDeadAge
    ) {
        self.baseDirectory = baseDirectory
        self.clock = clock
        self.log = log
        self.maxBytes = max(1, maxBytes)
        self.maxAge = maxAge
        self.maxDeadBytes = max(1, maxDeadBytes)
        self.maxDeadAge = maxDeadAge
        self.lock = LaneFileLocks.lock(for: baseDirectory.appendingPathComponent("state.json"))
    }

    // MARK: Einreihen und Lesen

    /// Schreibt das Paket atomar (Schutzklasse `completeUntilFirstUserAuthentication`, damit
    /// Hintergrundläufe bei gesperrtem iPhone schreiben können) und wendet danach die Deckel an.
    @discardableResult
    func enqueue(_ payload: Data) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let now = clock.now()
        var stamp = Self.milliseconds(now)
        if let last = pendingLocked().last.flatMap(Self.stamp(of:)), last >= stamp {
            stamp = last + 1
        }
        let url = outboxDirectory.appendingPathComponent(
            String(format: "%015lld", stamp) + "-" + UUID().uuidString + ".json"
        )
        try LaneFiles.writeAtomically(payload, to: url)
        enforceCapsLocked(now: now)
        return url
    }

    /// Wartende Pakete, ältestes zuerst.
    func pending() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return pendingLocked()
    }

    /// Aufgegebene Pakete, ältestes zuerst.
    func deadFiles() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return Self.packages(in: deadDirectory)
    }

    func counts() -> (queued: Int, dead: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let queued = pendingLocked()
        return (queued.count, Self.packages(in: deadDirectory).count, queued.reduce(0) { $0 + Self.size(of: $1) })
    }

    // MARK: Verschieben und Entfernen

    /// Verschiebt ein Paket nach `dead/`. Das Verschieben löscht nie. `false`, wenn es scheitert:
    /// dann bleibt die Datei in `outbox/`. Danach gilt der Deckel für `dead/`
    /// (`enforceDeadCapLocked`), der die ältesten Dateien dort löschen kann.
    @discardableResult
    func markDead(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let moved = moveToDeadLocked(url)
        if moved {
            try? updateStateLocked { $0.files[url.lastPathComponent] = nil }
            enforceDeadCapLocked(now: clock.now())
        }
        return moved
    }

    /// Entfernt ein zugestelltes Paket.
    func remove(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        try? updateStateLocked { $0.files[url.lastPathComponent] = nil }
    }

    // MARK: Deckel

    /// Älter als `maxAge` oder über `maxBytes`: die ältesten wandern nach `dead/`, `gapCount` steigt,
    /// `lastGapAt` wird gesetzt. Das Verschieben löscht nichts. Danach der Deckel für `dead/`; das
    /// Ergebnis ist die Zahl der dort gelöschten Pakete.
    @discardableResult
    func enforceCaps() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return enforceCapsLocked(now: clock.now())
    }

    @discardableResult
    private func enforceCapsLocked(now: Date) -> Int {
        var moved = 0

        for url in pendingLocked() where now.timeIntervalSince(Self.enqueuedAt(url)) > maxAge {
            if moveToDeadLocked(url) { moved += 1 }
        }

        let remaining = pendingLocked()
        var total = remaining.reduce(0) { $0 + Self.size(of: $1) }
        for url in remaining where total > maxBytes {
            let size = Self.size(of: url)
            if moveToDeadLocked(url) {
                total -= size
                moved += 1
            }
        }

        if moved > 0 {
            do {
                try updateStateLocked { state in
                    state.gapCount += moved
                    state.lastGapAt = now
                }
                log("Secondary: outbox over cap, moved \(moved) package(s) to dead/")
            } catch {
                log("Secondary: outbox over cap, moved \(moved) package(s) to dead/, gap count not recorded")
            }
        }
        return enforceDeadCapLocked(now: now)
    }

    /// Deckel für `dead/` (ow.5): Dateien, die länger als `maxDeadAge` dort liegen, und darüber
    /// hinaus die ältesten, solange `dead/` größer als `maxDeadBytes` ist, werden gelöscht. Das Alter
    /// zählt ab dem Verschieben (Änderungsdatum, beim Verschieben gesetzt). Gezählt in
    /// `deadDropped`. Die Pakete liegen beim Primärziel, das sie vorher angenommen hat.
    @discardableResult
    private func enforceDeadCapLocked(now: Date) -> Int {
        let files = Self.packages(in: deadDirectory)
            .map { (url: $0, at: Self.deadAt($0), size: Self.size(of: $0)) }
            .sorted { ($0.at, $0.url.lastPathComponent) < ($1.at, $1.url.lastPathComponent) }
        guard !files.isEmpty else { return 0 }

        var total = files.reduce(0) { $0 + $1.size }
        var dropped = 0
        for file in files where now.timeIntervalSince(file.at) > maxDeadAge || total > maxDeadBytes {
            do {
                try FileManager.default.removeItem(at: file.url)
                total -= file.size
                dropped += 1
            } catch {
                log("Secondary: could not delete a package from dead/")
            }
        }

        guard dropped > 0 else { return 0 }
        do {
            try updateStateLocked { $0.deadDropped += dropped }
            log("Secondary: dead/ over cap, deleted \(dropped) package(s)")
        } catch {
            log("Secondary: dead/ over cap, deleted \(dropped) package(s), count not recorded")
        }
        return dropped
    }

    /// Ein Paket ließ sich nicht einreihen (Platte voll, Rechte, Ordner fehlt). Es erreicht das
    /// Zweitziel nie und zählt deshalb als Lücke wie ein vom Deckel verschobenes (Plan 09-04).
    /// Scheitert auch das, bleibt es beim Log und bei der Zahl im Journal des Zyklus.
    func recordEnqueueFailure() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        do {
            try updateStateLocked { state in
                state.gapCount += 1
                state.lastGapAt = now
                state.lastError = "enqueue failed"
            }
        } catch {
            log("Secondary: enqueue failed, gap count not recorded")
        }
    }

    // MARK: Wartezeit nach 401/403

    /// Hebt die Wartezeit nach 401/403 auf (ow.5, geänderte Konfiguration). Gibt es keine, wird nichts
    /// geschrieben und kein Ordner angelegt.
    func clearAuthPause() {
        lock.lock()
        defer { lock.unlock() }
        guard case .state(let current) = loadLocked(),
              current.authFailures != 0 || current.pausedUntil != nil else { return }
        do {
            try updateStateLocked { state in
                state.authFailures = 0
                state.pausedUntil = nil
            }
        } catch {
            log("Secondary: auth wait could not be cleared")
        }
    }

    // MARK: Zustand

    var gapCount: Int { state().gapCount }
    var lastGapAt: Date? { state().lastGapAt }

    /// Fehlende Datei: leerer Zustand. Beschädigte Datei: beiseitegelegt, leerer Zustand. Nicht
    /// lesbare Datei: leerer Zustand im Speicher, die Datei bleibt.
    func state() -> SecondaryState {
        lock.lock()
        defer { lock.unlock() }
        switch loadLocked() {
        case .state(let state): return state
        case .unreadable: return SecondaryState()
        }
    }

    func fileState(for name: String) -> SecondaryFileState? {
        state().files[name]
    }

    /// Liest, ändert und schreibt als ein Schritt.
    func updateState(_ change: (inout SecondaryState) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try updateStateLocked(change)
    }

    /// Vergisst Einträge zu Dateien, die nicht mehr in `outbox/` liegen.
    func pruneState() {
        lock.lock()
        defer { lock.unlock() }
        let names = Set(pendingLocked().map(\.lastPathComponent))
        guard case .state(let current) = loadLocked(),
              current.files.keys.contains(where: { !names.contains($0) }) else { return }
        try? updateStateLocked { state in
            state.files = state.files.filter { names.contains($0.key) }
        }
    }

    // MARK: Intern

    private enum Loaded {
        case state(SecondaryState)
        case unreadable
    }

    private func loadLocked() -> Loaded {
        switch LaneFiles.read(stateURL) {
        case .missing:
            return .state(SecondaryState())
        case .unreadable:
            return .unreadable
        case .data(let data):
            if let state = try? BackfillPlan.makeDecoder().decode(SecondaryState.self, from: data) {
                return .state(state)
            }
            if let aside = LaneFiles.moveAside(stateURL, now: clock.now()) {
                log("Secondary: state.json unreadable as JSON, moved aside to \(aside.lastPathComponent)")
                return .state(SecondaryState())
            }
            return .unreadable
        }
    }

    private func updateStateLocked(_ change: (inout SecondaryState) -> Void) throws {
        guard case .state(var state) = loadLocked() else { throw StoreError.unreadable }
        change(&state)
        try LaneFiles.writeAtomically(try BackfillPlan.makeEncoder().encode(state), to: stateURL)
    }

    private func pendingLocked() -> [URL] {
        Self.packages(in: outboxDirectory)
    }

    private func moveToDeadLocked(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: deadDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let stem = url.deletingPathExtension().lastPathComponent
            var destination = deadDirectory.appendingPathComponent(url.lastPathComponent)
            var counter = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                counter += 1
                destination = deadDirectory.appendingPathComponent("\(stem)-\(counter).json")
            }
            try FileManager.default.moveItem(at: url, to: destination)
            // Das Alter in `dead/` zählt ab hier (`deadAt`). Scheitert das, gilt das alte
            // Änderungsdatum, und die Datei fällt höchstens früher unter den Deckel.
            try? FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: destination.path)
            return true
        } catch {
            log("Secondary: could not move a package to dead/")
            return false
        }
    }

    /// Pakete eines Ordners nach Namen sortiert. Nur Namen nach dem Schema, keine versteckten
    /// Zwischenstände eines atomaren Schreibens.
    private static func packages(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" && stamp(of: $0) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func stamp(of url: URL) -> Int64? {
        let name = url.lastPathComponent
        guard let dash = name.firstIndex(of: "-") else { return nil }
        return Int64(name[name.startIndex..<dash])
    }

    /// Zeitpunkt des Einreihens aus dem Namen, ersatzweise das Änderungsdatum.
    private static func enqueuedAt(_ url: URL) -> Date {
        if let stamp = stamp(of: url) {
            return Date(timeIntervalSince1970: Double(stamp) / 1000)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? Date()
    }

    /// Zeitpunkt des Verschiebens nach `dead/`: das dabei gesetzte Änderungsdatum, ersatzweise der
    /// Zeitpunkt des Einreihens.
    private static func deadAt(_ url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? enqueuedAt(url)
    }

    private static func size(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Sender

struct SecondaryDrainResult: Equatable {
    var delivered = 0
    var retried = 0
    var dead = 0
    /// 401/403: das Zweitziel ruht, nichts wurde entfernt.
    var paused = false
    /// Ein anderer Durchlauf über denselben Ordner lief schon; dieser hat nichts getan.
    var skipped = false
    /// Das erste wartende Paket ist erst ab diesem Zeitpunkt wieder dran (Backoff).
    var deferredUntil: Date?
    /// Kurz und ohne Inhalt: `HTTP 503`, `auth 401`, `network(-1009)`, `unreadable`.
    var lastError: String?
    /// Wartezeit nach 401/403 (ow.5): gesetzt, wenn dieser Durchlauf sie begonnen hat (`paused`) oder
    /// wegen ihr nichts gesendet hat.
    var pausedUntil: Date?
    /// Zu Beginn des Durchlaufs aus `dead/` gelöschte Pakete (Deckel, ow.5).
    var dropped = 0
}

/// Sendet die wartenden Pakete seriell in Reihenfolge an das Zweitziel.
///
/// Eigene `URLSession` mit Standardkonfiguration (für Tests injizierbar). Der Durchlauf endet an
/// der ersten Wiederholung, an einer Pause und an einem Paket, dessen Backoff noch läuft. Ein
/// Paket in `dead/` hält die Reihe nicht auf. Während der Wartezeit nach 401/403 sendet er nichts.
final class SecondaryUploader {

    private static let runningLock = NSLock()
    private static var running: Set<String> = []

    private let outbox: SecondaryOutbox
    private let session: URLSession
    private let clock: LaneClock
    private let log: (String) -> Void

    /// Eine Session für alle Sender im Prozess. Eine Session je Instanz würde nie invalidiert, und
    /// ein Sender je Zyklus häufte sie an.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(
        outbox: SecondaryOutbox,
        session: URLSession = SecondaryUploader.sharedSession,
        clock: LaneClock = SystemLaneClock(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.outbox = outbox
        self.session = session
        self.clock = clock
        self.log = log
    }

    /// Nie zwei Durchläufe über denselben Ordner zugleich, auch nicht aus zwei Instanzen: der
    /// zweite meldet sofort `skipped`.
    func drain(target: SecondaryTarget, completion: @escaping (SecondaryDrainResult) -> Void) {
        let key = outbox.baseDirectory.standardizedFileURL.path
        Self.runningLock.lock()
        if Self.running.contains(key) {
            Self.runningLock.unlock()
            var result = SecondaryDrainResult()
            result.skipped = true
            completion(result)
            return
        }
        Self.running.insert(key)
        Self.runningLock.unlock()

        var initial = SecondaryDrainResult()
        initial.dropped = outbox.enforceCaps()
        outbox.pruneState()
        let files = outbox.pending()

        let finish: (SecondaryDrainResult) -> Void = { [log] result in
            Self.runningLock.lock()
            Self.running.remove(key)
            Self.runningLock.unlock()
            if result.delivered + result.retried + result.dead > 0 || result.paused || result.lastError != nil {
                let wait = result.pausedUntil.map { " waitUntil=\(ISO8601DateFormatter().string(from: $0))" } ?? ""
                log(
                    "Secondary: delivered=\(result.delivered) retried=\(result.retried) dead=\(result.dead) "
                        + "paused=\(result.paused ? 1 : 0) queued=\(files.count - result.delivered - result.dead) "
                        + "last=\(result.lastError ?? "-")" + wait
                )
            }
            completion(result)
        }

        // Wartezeit nach 401/403: kein Versuch, bis sie abgelaufen ist (ow.5).
        if let until = outbox.state().pausedUntil, until > clock.now() {
            initial.pausedUntil = until
            finish(initial)
            return
        }

        sendNext(files[...], target: target, result: initial, done: finish)
    }

    private func sendNext(
        _ files: ArraySlice<URL>,
        target: SecondaryTarget,
        result: SecondaryDrainResult,
        done: @escaping (SecondaryDrainResult) -> Void
    ) {
        guard let file = files.first else {
            done(result)
            return
        }
        var result = result
        let name = file.lastPathComponent

        if let next = outbox.fileState(for: name)?.nextAttemptAt, next > clock.now() {
            result.deferredUntil = next
            done(result)
            return
        }

        guard let payload = try? Data(contentsOf: file) else {
            if !FileManager.default.fileExists(atPath: file.path) {
                // Inzwischen verschoben oder entfernt: weiter mit der nächsten.
                sendNext(files.dropFirst(), target: target, result: result, done: done)
            } else {
                result.lastError = "unreadable"
                done(result)
            }
            return
        }

        var request = URLRequest(url: target.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(target.apiKey, forHTTPHeaderField: "X-Open-Wearables-API-Key")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        request.setValue(OpenWearablesHealthSDK.sdkVersion, forHTTPHeaderField: "X-Open-Wearables-SDK-Version")
        request.setValue("ios", forHTTPHeaderField: "X-Open-Wearables-SDK-Platform")
        request.setValue(OpenWearablesHealthSDK.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = payload

        // Stark gehalten bis zur Antwort: ein zugestelltes Paket wird auch dann entfernt, wenn der
        // Aufrufer den Sender schon losgelassen hat. Die Session gibt den Block danach frei.
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let failure = Self.describe(status: status, error: error)
            let (decision, pausedUntil) = self.record(
                name: name, status: status, transportFailed: error != nil, failure: failure
            )

            switch decision {
            case .delivered:
                self.outbox.remove(file)
                result.delivered += 1
                self.sendNext(files.dropFirst(), target: target, result: result, done: done)
            case .retry:
                result.retried += 1
                result.lastError = failure
                done(result)
            case .pause(let authStatus):
                result.paused = true
                result.lastError = "auth \(authStatus)"
                result.pausedUntil = pausedUntil
                done(result)
            case .dead:
                if self.outbox.markDead(file) {
                    result.dead += 1
                    result.lastError = failure
                    self.sendNext(files.dropFirst(), target: target, result: result, done: done)
                } else {
                    // Ließ sich nicht verschieben: die Datei bleibt, der Durchlauf endet.
                    result.lastError = failure
                    done(result)
                }
            }
        }.resume()
    }

    /// Wendet die Politik auf den gespeicherten Zustand der Datei an und speichert das Ergebnis.
    /// Bei 401/403 kommt die neue Wartezeit mit zurück; ohne schreibbaren Zustand gibt es keine,
    /// dann versucht es der nächste Anstoß wieder (wie vor ow.5).
    private func record(
        name: String, status: Int?, transportFailed: Bool, failure: String
    ) -> (SecondaryDecision, Date?) {
        let now = clock.now()
        var decision = SecondaryDecision.retry(after: SecondaryPolicy.initialBackoff)
        var pausedUntil: Date?
        do {
            try outbox.updateState { state in
                var policy = SecondaryPolicy(state: state.files[name] ?? SecondaryFileState())
                decision = policy.decide(status: status, error: transportFailed, now: now)
                switch decision {
                case .delivered:
                    state.files[name] = nil
                    state.lastSuccessAt = now
                    state.lastError = nil
                    state.authFailures = 0
                    state.pausedUntil = nil
                case .dead:
                    state.files[name] = nil
                    state.lastError = failure
                case .retry:
                    state.files[name] = policy.state
                    state.lastError = failure
                case .pause:
                    state.files[name] = policy.state
                    state.lastError = failure
                    state.authFailures += 1
                    let until = now.addingTimeInterval(SecondaryPolicy.authWait(afterFailures: state.authFailures))
                    state.pausedUntil = until
                    pausedUntil = until
                }
            }
        } catch {
            // Zustand nicht schreibbar: entscheiden ohne neues Gedächtnis. Ein Paket wird so nie
            // aufgegeben, es wartet höchstens.
            var policy = SecondaryPolicy(state: outbox.fileState(for: name) ?? SecondaryFileState())
            decision = policy.decide(status: status, error: transportFailed, now: now)
            if decision == .dead { decision = .retry(after: SecondaryPolicy.countSpacing) }
            log("Secondary: state.json not writable")
        }
        return (decision, pausedUntil)
    }

    /// Nur Code und Status, nie die Beschreibung (kann eine URL enthalten) oder den Antworttext.
    private static func describe(status: Int?, error: Error?) -> String {
        if let nsError = error as NSError? { return "network(\(nsError.code))" }
        guard let status = status else { return "no HTTP response" }
        if status == 401 || status == 403 { return "auth \(status)" }
        return "HTTP \(status)"
    }
}
