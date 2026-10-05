import Foundation

// Fork-Zusatz (roboe93), Plan 09-03 (D-08). Das Zweitziel: dieselben Pakete zusätzlich an einen
// zweiten Server, mit eigener Datei-Outbox.
//
// Eingehängt wird es erst in 09-04 (nach dem 2xx des Primärziels einreihen, hinter einem Schalter,
// der standardmäßig aus ist). Hier entstehen nur die Bausteine:
//
//   - `SecondaryOutbox`: Dateien unter `health_secondary/outbox/`, Reihenfolge nach Dateiname,
//     `dead/` für Aufgegebenes, Deckel nach Größe und Alter. Nie stilles Löschen: was nicht
//     zugestellt wird, liegt in `dead/` und ist gezählt (`gapCount`).
//   - `SecondaryPolicy`: rein, entscheidet aus Status und Zeitpunkt.
//   - `SecondaryUploader`: eigene `URLSession`, seriell, ein Durchlauf je Ordner zur selben Zeit.
//
// Anchors hängen nur am Primärziel. Das Zweitziel berührt nie Cursor, Anmeldung oder Primärpfad:
// 401 und 403 pausieren nur das Zweitziel, ohne Abmeldung, ohne Auth-Rückruf an die App und ohne
// Token-Refresh. Die Hintergrund-Session des SDK wird nie benutzt: ihr Delegate liest
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
    /// Pakete, die der Deckel nach `dead/` verschoben hat: eine Lücke im Zweitziel.
    var gapCount: Int = 0
    var lastGapAt: Date?
    var lastSuccessAt: Date?
    /// Kurz und ohne Inhalt: `HTTP 503`, `auth 401`, `network(-1009)`.
    var lastError: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? SecondaryState.currentVersion
        files = try container.decodeIfPresent([String: SecondaryFileState].self, forKey: .files) ?? [:]
        gapCount = try container.decodeIfPresent(Int.self, forKey: .gapCount) ?? 0
        lastGapAt = try container.decodeIfPresent(Date.self, forKey: .lastGapAt)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

// MARK: - Wiederholungspolitik

enum SecondaryDecision: Equatable {
    /// 2xx: die Datei ist zugestellt und wird entfernt.
    case delivered
    /// Später erneut; der Durchlauf endet hier, die Reihenfolge bleibt.
    case retry(after: TimeInterval)
    /// 401/403: das Zweitziel ruht bis zum nächsten Durchlauf. Die Datei bleibt.
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
/// höchstens 1 Stunde.
struct SecondaryPolicy {
    static let initialBackoff: TimeInterval = 60
    static let maxBackoff: TimeInterval = 3600
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

    let baseDirectory: URL
    let maxBytes: Int
    let maxAge: TimeInterval

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
        maxAge: TimeInterval = SecondaryOutbox.defaultMaxAge
    ) {
        self.baseDirectory = baseDirectory
        self.clock = clock
        self.log = log
        self.maxBytes = max(1, maxBytes)
        self.maxAge = maxAge
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

    /// Verschiebt ein Paket nach `dead/`. Nie gelöscht. `false`, wenn das Verschieben scheitert:
    /// dann bleibt die Datei in `outbox/`.
    @discardableResult
    func markDead(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let moved = moveToDeadLocked(url)
        if moved {
            try? updateStateLocked { $0.files[url.lastPathComponent] = nil }
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
    /// `lastGapAt` wird gesetzt. Nichts wird gelöscht.
    func enforceCaps() {
        lock.lock()
        defer { lock.unlock() }
        enforceCapsLocked(now: clock.now())
    }

    private func enforceCapsLocked(now: Date) {
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

        guard moved > 0 else { return }
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
}

/// Sendet die wartenden Pakete seriell in Reihenfolge an das Zweitziel.
///
/// Eigene `URLSession` mit Standardkonfiguration (für Tests injizierbar). Der Durchlauf endet an
/// der ersten Wiederholung, an einer Pause und an einem Paket, dessen Backoff noch läuft. Ein
/// Paket in `dead/` hält die Reihe nicht auf.
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

        outbox.enforceCaps()
        outbox.pruneState()
        let files = outbox.pending()

        sendNext(files[...], target: target, result: SecondaryDrainResult()) { [log] result in
            Self.runningLock.lock()
            Self.running.remove(key)
            Self.runningLock.unlock()
            if result.delivered + result.retried + result.dead > 0 || result.paused || result.lastError != nil {
                log(
                    "Secondary: delivered=\(result.delivered) retried=\(result.retried) dead=\(result.dead) "
                        + "paused=\(result.paused ? 1 : 0) queued=\(files.count - result.delivered - result.dead) "
                        + "last=\(result.lastError ?? "-")"
                )
            }
            completion(result)
        }
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
            let decision = self.record(name: name, status: status, transportFailed: error != nil, failure: failure)

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
    private func record(name: String, status: Int?, transportFailed: Bool, failure: String) -> SecondaryDecision {
        let now = clock.now()
        var decision = SecondaryDecision.retry(after: SecondaryPolicy.initialBackoff)
        do {
            try outbox.updateState { state in
                var policy = SecondaryPolicy(state: state.files[name] ?? SecondaryFileState())
                decision = policy.decide(status: status, error: transportFailed, now: now)
                switch decision {
                case .delivered:
                    state.files[name] = nil
                    state.lastSuccessAt = now
                    state.lastError = nil
                case .dead:
                    state.files[name] = nil
                    state.lastError = failure
                case .retry, .pause:
                    state.files[name] = policy.state
                    state.lastError = failure
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
        return decision
    }

    /// Nur Code und Status, nie die Beschreibung (kann eine URL enthalten) oder den Antworttext.
    private static func describe(status: Int?, error: Error?) -> String {
        if let nsError = error as NSError? { return "network(\(nsError.code))" }
        guard let status = status else { return "no HTTP response" }
        if status == 401 || status == 403 { return "auth \(status)" }
        return "HTTP \(status)"
    }
}
