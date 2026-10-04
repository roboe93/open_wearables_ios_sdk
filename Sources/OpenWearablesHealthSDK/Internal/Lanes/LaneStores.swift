import Foundation

// Fork-Zusatz (roboe93), Plan 05-07. Speicher der Zwei-Spuren-Steuerung: Cursor, Nachholplan,
// geparkte Datensätze, Uhr und die Schalter in der Defaults-Suite.
//
// Grundsatz für jede Datei hier: nie löschen, nie still überschreiben (Arbeitsregel 2).
// Beschädigtes wird mit Zeitstempel umbenannt, Nicht-Lesbares (Schutzklasse vor dem ersten
// Entsperren) wird nicht angefasst.

// MARK: - Dateihilfen

enum LaneFiles {

    enum ReadResult {
        case missing
        case data(Data)
        /// Die Datei ist da, lässt sich aber nicht lesen. Das ist keine Beschädigung.
        case unreadable
    }

    static func read(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .data(data)
    }

    /// Atomar, mit Schutzklasse `completeUntilFirstUserAuthentication`. `.complete` ließe
    /// Hintergrundläufe bei gesperrtem iPhone scheitern, und gerade die sollen schreiben können
    /// (Recherche, Anti-Pattern ".complete-Dateischutz").
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Benennt die Datei in `<Name>.corrupt-<Zeitstempel>` um. Existiert der Name schon (zweite
    /// Beschädigung in derselben Sekunde), kommt ein Zähler dazu. `nil`, wenn das Umbenennen
    /// scheitert: dann darf der Aufrufer nicht weiterschreiben.
    static func moveAside(_ url: URL, now: Date) -> URL? {
        let folder = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).corrupt-\(timestamp(now))"
        var candidate = folder.appendingPathComponent(base)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = folder.appendingPathComponent("\(base)-\(counter)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: candidate)
            return candidate
        } catch {
            return nil
        }
    }

    /// `20261004T081530Z`, UTC, ohne Zeichen, die in Dateinamen stören.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// Ein Dateiname aus einer Kennung: nur Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich.
    /// Alles andere wird `_`, ein Pfadtrenner kann so nie aus dem Ordner herausführen.
    static func safeName(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var mapped = String(text.map { allowed.contains($0) ? $0 : "_" })
        // Ein Name aus lauter Punkten (`..`) bezeichnet ein Verzeichnis, kein Datei.
        if mapped.allSatisfy({ $0 == "." }) { mapped = String(repeating: "_", count: max(1, mapped.count)) }
        return mapped.isEmpty ? "_" : mapped
    }
}

// MARK: - Uhr

final class SystemLaneClock: LaneClock {
    init() {}
    func now() -> Date { Date() }
}

// MARK: - Cursor

/// Die Anchors der Live-Spur. Kein neues Format: derselbe Schlüssel `anchor.<userKey>.<HK-Identifier>`
/// und dieselben Bytes wie `loadAnchor`/`saveAnchor` (Recherche "Don't Hand-Roll"). Ein Anchor,
/// den 0.15 geschrieben hat, ist für die Spuren lesbar und umgekehrt, das ist der Rückweg (D-13).
///
/// Der Benutzerschlüssel gilt für den Zyklus, für den der Speicher gebaut wurde: wechselt das
/// Konto mitten im Lauf, schreibt der alte Lauf nicht in den Anchor-Satz des neuen.
final class DefaultsCursorStore: CursorStore {

    private weak var sdk: OpenWearablesHealthSDK?
    private let userKey: String

    init(sdk: OpenWearablesHealthSDK, userKey: String? = nil) {
        self.sdk = sdk
        self.userKey = userKey ?? sdk.userKey()
    }

    func anchor(for typeId: String) -> AnchorToken? {
        guard let sdk = sdk else { return nil }
        return sdk.defaults.data(forKey: sdk.anchorKey(typeIdentifier: typeId, userKey: userKey))
    }

    func commit(_ anchor: AnchorToken, for typeId: String) {
        sdk?.saveAnchorData(anchor, typeIdentifier: typeId, userKey: userKey)
    }
}

// MARK: - Nachholplan

/// Eine Sperre je Datei für den ganzen Prozess (Review LO-07).
///
/// Zyklus, abgelöster Zyklus, `requestBackfill` und `getSyncStatus` bauen je eine eigene
/// Speicher-Instanz. Eine Sperre je Instanz schützte deshalb nur vor sich selbst, und zwei
/// Schreiber verloren gegenseitig Einträge. Rekursiv: ein Rückruf aus dem Schreibschritt (Log)
/// darf denselben Speicher noch einmal anfassen.
enum LaneFileLocks {
    private static let guardLock = NSLock()
    private static var locks: [String: NSRecursiveLock] = [:]
    private static var queues: [String: DispatchQueue] = [:]

    /// Eine serielle Queue je Datei, für Speicher, die ihre Schritte als `queue.sync` ausführen
    /// (`DeletionQueue`).
    static func queue(for url: URL) -> DispatchQueue {
        let key = url.standardizedFileURL.path
        guardLock.lock()
        defer { guardLock.unlock() }
        if let existing = queues[key] { return existing }
        let created = DispatchQueue(label: "health_lanes_file.\(url.lastPathComponent)")
        queues[key] = created
        return created
    }

    static func lock(for url: URL) -> NSRecursiveLock {
        let key = url.standardizedFileURL.path
        guardLock.lock()
        defer { guardLock.unlock() }
        if let existing = locks[key] { return existing }
        let created = NSRecursiveLock()
        locks[key] = created
        return created
    }
}

/// `health_lanes/backfill.json`. Schreibt und liest über `BackfillPlan.encoded()` und `decode(_:)`,
/// nie über einen eigenen Encoder: nur so überleben Zeitpunkte unter einer Millisekunde den Weg
/// über die Platte (05-06, Abweichung 1).
///
/// Format (`scripts/proof/analyze_runs.py` liest es): `{ "version", "sessionId", "entries": { "<Typ>":
/// { "state": "pending|done", "floor", "covered", ... } }, "rejections": { ... } }`.
///
/// Mehrere Schreiber (Review HI-01, ME-04): Wer ändern will, nimmt `update`. Es liest den Stand
/// der Datei, wendet die Änderung an und schreibt, als ein Schritt unter der prozessweiten Sperre
/// der Datei. Ein Eintrag, den ein anderer Schreiber angelegt hat, bleibt so immer erhalten.
/// `save` ersetzt die Datei mit einem ganzen Plan und prüft dafür die Revision: hat sich die Datei
/// seit dem letzten Lesen oder Schreiben dieser Instanz geändert, wirft es `.conflict`, statt den
/// fremden Stand still zu überschreiben. Die Revision ist der Inhalt der Datei selbst; das Format
/// bleibt unverändert, ein Rückweg auf 0.15.0-ow.2 liest die Datei wie bisher.
final class FileBackfillStore: BackfillStoring {

    enum StoreError: Error, Equatable {
        /// Die Datei ist da, lässt sich aber nicht lesen. `save` ersetzt sie nicht durch einen
        /// Plan, der ihren Stand nicht kennt.
        case unreadable
        /// Die Datei hat sich seit dem letzten `load` oder Schreiben dieser Instanz geändert.
        case conflict
    }

    /// Was diese Instanz zuletzt in der Datei gesehen hat, die Revision für `save`.
    private enum Baseline {
        /// Nie geladen: `save` schreibt wie bisher, ohne Prüfung.
        case unknown
        /// Beim letzten Blick gab es keine Datei.
        case missing
        case content(Data)
    }

    let fileURL: URL

    private let clock: LaneClock
    private let log: (String) -> Void
    private let lock: NSRecursiveLock
    private var baseline: Baseline = .unknown

    init(directory: URL, clock: LaneClock = SystemLaneClock(), log: @escaping (String) -> Void = { _ in }) {
        self.fileURL = directory.appendingPathComponent("backfill.json")
        self.clock = clock
        self.log = log
        self.lock = LaneFileLocks.lock(for: directory.appendingPathComponent("backfill.json"))
    }

    /// Fehlende Datei: leerer Plan. Beschädigte Datei: beiseitegelegt, leerer Plan. Nicht lesbare
    /// Datei: leerer Plan im Speicher, die Datei bleibt, und `save` verweigert das Überschreiben.
    func load() -> BackfillPlan {
        lock.lock()
        defer { lock.unlock() }
        switch LaneFiles.read(fileURL) {
        case .missing:
            baseline = .missing
            return .empty()
        case .unreadable:
            baseline = .unknown
            return .empty()
        case .data(let data):
            if let plan = try? BackfillPlan.decode(data) {
                baseline = .content(data)
                return plan
            }
            baseline = moveCorruptAside() ? .missing : .unknown
            return .empty()
        }
    }

    func save(_ plan: BackfillPlan) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try plan.encoded()
        switch LaneFiles.read(fileURL) {
        case .unreadable:
            throw StoreError.unreadable
        case .data(let existing):
            if (try? BackfillPlan.decode(existing)) == nil {
                // Eine beschädigte Datei wird nie unbemerkt ersetzt, auch wenn niemand vorher geladen hat.
                if !moveCorruptAside() { throw StoreError.unreadable }
            } else {
                switch baseline {
                case .unknown:
                    break
                case .missing:
                    // Seit dem Laden hat ein anderer Schreiber die Datei angelegt.
                    throw StoreError.conflict
                case .content(let seen):
                    if seen != existing { throw StoreError.conflict }
                }
            }
        case .missing:
            break
        }
        try LaneFiles.writeAtomically(data, to: fileURL)
        baseline = .content(data)
    }

    @discardableResult
    func update(_ mutate: (inout BackfillPlan) throws -> Void) throws -> BackfillPlan {
        lock.lock()
        defer { lock.unlock() }
        var plan: BackfillPlan
        var existing: Data?
        switch LaneFiles.read(fileURL) {
        case .unreadable:
            throw StoreError.unreadable
        case .missing:
            plan = .empty()
        case .data(let data):
            if let decoded = try? BackfillPlan.decode(data) {
                plan = decoded
                existing = data
            } else {
                if !moveCorruptAside() { throw StoreError.unreadable }
                plan = .empty()
            }
        }
        let before = plan
        try mutate(&plan)
        if plan == before {
            // Nichts geändert, nichts geschrieben.
            baseline = existing.map { .content($0) } ?? .missing
            return plan
        }
        let data = try plan.encoded()
        try LaneFiles.writeAtomically(data, to: fileURL)
        baseline = .content(data)
        return plan
    }

    @discardableResult
    private func moveCorruptAside() -> Bool {
        guard let aside = LaneFiles.moveAside(fileURL, now: clock.now()) else { return false }
        log("Nachholplan beschädigt: Datei als \(aside.lastPathComponent) beiseitegelegt, neuer Plan beginnt leer")
        return true
    }
}

// MARK: - Geparkte Datensätze

/// `health_rejected/<Typ>-<Kennung>.json`. Ein Datensatz, den der Server dauerhaft abweist, wird
/// hierher abgelegt statt verworfen. Es wird nie gelöscht und nie überschrieben: eine zweite Ablage
/// derselben Kennung bekommt einen Zähler im Namen.
///
/// Der Datensatz enthält Gesundheitswerte (T-05-25): Datei in der App-Sandbox, nie im Log.
final class FileRejectionParking: RejectionParking {

    let directory: URL
    private let clock: LaneClock
    private let lock = NSLock()

    init(directory: URL, clock: LaneClock = SystemLaneClock()) {
        self.directory = directory
        self.clock = clock
    }

    func park(typeId: String, itemId: String, httpStatus: Int, record: Data?) throws {
        lock.lock()
        defer { lock.unlock() }

        var object: [String: Any] = [
            "typeId": typeId,
            "itemId": itemId,
            "httpStatus": httpStatus,
            "parkedAt": LaneTime.string(from: clock.now()),
            "record": NSNull()
        ]
        if let record = record {
            // Als JSON einbetten, wenn es eines ist, damit die Datei lesbar bleibt.
            if let parsed = try? JSONSerialization.jsonObject(with: record, options: [.fragmentsAllowed]) {
                object["record"] = parsed
            } else {
                object["recordBase64"] = record.base64EncodedString()
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])

        let base = "\(LaneFiles.safeName(typeId))-\(LaneFiles.safeName(itemId))"
        var url = directory.appendingPathComponent("\(base).json")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            counter += 1
            url = directory.appendingPathComponent("\(base)-\(counter).json")
        }
        try LaneFiles.writeAtomically(data, to: url)
    }

    // MARK: Sichtbar und erneut sendbar (Review HI-02)

    /// Unterordner für Datensätze, die nach dem erneuten Senden angenommen wurden. Verschoben,
    /// nie gelöscht.
    static let replayedFolder = "replayed"

    /// Die geparkten Datensätze, die noch auf eine Annahme warten, nach Namen sortiert. Ohne den
    /// Unterordner `replayed/`.
    func parkedFiles() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
    }

    func parkedCount() -> Int {
        parkedFiles().count
    }

    /// Das Paket eines geparkten Datensatzes, wie es beim Parken abgewiesen wurde. `nil`, wenn die
    /// Datei keinen lesbaren Datensatz enthält (dann bleibt sie liegen).
    func payload(of url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let record = object["record"] as? [String: Any] { return record }
        if let base64 = object["recordBase64"] as? String,
           let raw = Data(base64Encoded: base64),
           let record = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            return record
        }
        return nil
    }

    /// Verschiebt einen angenommenen Datensatz nach `replayed/`. Ein vorhandener Name wird nie
    /// überschrieben: es kommt ein Zähler dazu.
    @discardableResult
    func markReplayed(_ url: URL) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let folder = directory.appendingPathComponent(Self.replayedFolder, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let base = url.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(url.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            counter += 1
            target = folder.appendingPathComponent("\(base)-\(counter).json")
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

// MARK: - Schalter und Fabriken im SDK

enum LaneDefaultsKey {
    static let needsCatchUp = "lanes.needsCatchUp"
    static let sendDeletions = "lanes.sendDeletions"
    static let anchorProbe = "lanes.anchorProbe"
}

extension OpenWearablesHealthSDK {

    /// Der Lauf war gesperrt und hat nicht nachgesehen. Überlebt einen Neustart des Prozesses
    /// (Pattern 7). Gelesen wird bei jedem Zugriff aus der Suite.
    internal var lanesNeedsCatchUp: Bool {
        get { defaults.bool(forKey: LaneDefaultsKey.needsCatchUp) }
        set { defaults.set(newValue, forKey: LaneDefaultsKey.needsCatchUp) }
    }

    /// Schickt Löschungen als `data.deleted` mit. Standard aus: Railway kennt das Feld nicht (Befund 5),
    /// und ein unbekanntes Feld darf nie zum Hindernis werden (T-05-26).
    internal var lanesSendDeletions: Bool {
        get { defaults.bool(forKey: LaneDefaultsKey.sendDeletions) }
        set { defaults.set(newValue, forKey: LaneDefaultsKey.sendDeletions) }
    }

    /// Anchor "jetzt" per Sonde statt per Durchlauf. Standard aus, bis Spike S1 am Gerät die Sonde
    /// bestätigt (A1).
    internal var lanesAnchorProbe: Bool {
        get { defaults.bool(forKey: LaneDefaultsKey.anchorProbe) }
        set { defaults.set(newValue, forKey: LaneDefaultsKey.anchorProbe) }
    }

    internal func makeDeletionQueue() -> DeletionQueue {
        DeletionQueue(
            directory: stateBaseDirectory().appendingPathComponent("health_deletions", isDirectory: true),
            clock: SystemLaneClock(),
            journal: runJournal,
            log: { [weak self] in self?.logMessage($0) }
        )
    }

    internal func makeBackfillStore() -> FileBackfillStore {
        FileBackfillStore(
            directory: stateBaseDirectory().appendingPathComponent("health_lanes", isDirectory: true),
            log: { [weak self] in self?.logMessage($0) }
        )
    }

    internal func makeCursorStore() -> DefaultsCursorStore {
        DefaultsCursorStore(sdk: self)
    }

    internal func makeRejectionParking() -> FileRejectionParking {
        FileRejectionParking(
            directory: stateBaseDirectory().appendingPathComponent("health_rejected", isDirectory: true)
        )
    }
}
