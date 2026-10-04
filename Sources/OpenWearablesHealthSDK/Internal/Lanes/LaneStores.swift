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

/// `health_lanes/backfill.json`. Schreibt und liest über `BackfillPlan.encoded()` und `decode(_:)`,
/// nie über einen eigenen Encoder: nur so überleben Zeitpunkte unter einer Millisekunde den Weg
/// über die Platte (05-06, Abweichung 1).
///
/// Format (`scripts/proof/analyze_runs.py` liest es): `{ "version", "sessionId", "entries": { "<Typ>":
/// { "state": "pending|done", "floor", "covered", ... } }, "rejections": { ... } }`.
final class FileBackfillStore: BackfillStoring {

    enum StoreError: Error, Equatable {
        /// Die Datei ist da, lässt sich aber nicht lesen. `save` ersetzt sie nicht durch einen
        /// Plan, der ihren Stand nicht kennt.
        case unreadable
    }

    let fileURL: URL

    private let clock: LaneClock
    private let log: (String) -> Void
    private let lock = NSLock()

    init(directory: URL, clock: LaneClock = SystemLaneClock(), log: @escaping (String) -> Void = { _ in }) {
        self.fileURL = directory.appendingPathComponent("backfill.json")
        self.clock = clock
        self.log = log
    }

    /// Fehlende Datei: leerer Plan. Beschädigte Datei: beiseitegelegt, leerer Plan. Nicht lesbare
    /// Datei: leerer Plan im Speicher, die Datei bleibt, und `save` verweigert das Überschreiben.
    func load() -> BackfillPlan {
        lock.lock()
        defer { lock.unlock() }
        switch LaneFiles.read(fileURL) {
        case .missing, .unreadable:
            return .empty()
        case .data(let data):
            if let plan = try? BackfillPlan.decode(data) { return plan }
            moveCorruptAside()
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
            // Eine beschädigte Datei wird nie unbemerkt ersetzt, auch wenn niemand vorher geladen hat.
            if (try? BackfillPlan.decode(existing)) == nil, !moveCorruptAside() {
                throw StoreError.unreadable
            }
        case .missing:
            break
        }
        try LaneFiles.writeAtomically(data, to: fileURL)
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
