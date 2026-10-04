import Foundation
import HealthKit

// Fork-Zusatz (roboe93), Plan 05-08. Die Handgriffe um die Zwei-Spuren-Steuerung: der
// Observer-Vertrag, Nachholen auf Anforderung und die Messhaken für den Gerätenachweis (D-15).
//
// Nichts hiervon ändert den Ablauf des Zyklus. Der Observer-Vertrag betrifft nur den Moment, in dem
// HealthKit seine Rückmeldung bekommt; `requestBackfill` ersetzt den Anchor-Reset der Diagnose;
// `probeAnchors` und `debugHangNextLiveFetch` sind Werkzeuge für Spike S1 und das Szenario
// "hängende Sperre" und tun im Normalbetrieb nichts.

// MARK: - OneShot

/// Führt seine Aktion genau einmal aus, egal wie oft und von wo `fire()` kommt.
///
/// Gebraucht für die Rückmeldung eines `HKObserverQuery`: HealthKit drosselt die Zustellung, wenn
/// die Completion mehrfach ausbleibt, und ein doppelter Aufruf ist ein Fehler. Der Zyklus feuert
/// nach der Live-Runde, ein Zeitgeber spätestens nach 20 Sekunden. Wer zuerst kommt, gewinnt.
final class OneShot {

    private let lock = NSLock()
    private var action: (() -> Void)?
    private var didFire = false

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    /// `true`, wenn dieser Aufruf die Aktion ausgeführt hat. Die Aktion läuft außerhalb der Sperre.
    @discardableResult
    func fire() -> Bool {
        lock.lock()
        let pending = action
        action = nil
        didFire = true
        lock.unlock()
        guard let pending = pending else { return false }
        pending()
        return true
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFire
    }

    /// Feuert nach `seconds`, falls bis dahin niemand es getan hat.
    func fireAfter(_ seconds: TimeInterval, on queue: DispatchQueue = .global(qos: .utility)) {
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            fire()
        }
    }
}

/// Die Rückmeldungen der Observer, die auf eine Live-Runde warten.
final class ObserverCompletions {

    private let lock = NSLock()
    private var pending: [OneShot] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func add(_ shot: OneShot) {
        lock.lock()
        // Was der Zeitgeber schon gefeuert hat, braucht keinen Platz mehr.
        pending.removeAll { $0.hasFired }
        pending.append(shot)
        lock.unlock()
    }

    /// Feuert alle offenen, jede genau einmal, außerhalb der Sperre.
    @discardableResult
    func fireAll() -> Int {
        lock.lock()
        let taken = pending
        pending = []
        lock.unlock()
        return taken.filter { $0.fire() }.count
    }
}

// MARK: - Observer-Vertrag

extension OpenWearablesHealthSDK {

    /// Wie lange ein Observer höchstens auf seine Live-Runde wartet. Eine Annahme (A5): lang genug
    /// für den Normalfall, kurz genug, dass HealthKit die Rückmeldung nicht als ausgeblieben wertet.
    /// `var` als Testnaht.
    internal static var observerCompletionCap: TimeInterval = 20

    /// Ein Weckruf des `HKObserverQuery` (Pattern 8, Pitfall 8).
    ///
    /// Im Modus lanes kommt die Rückmeldung erst, wenn die nächste Live-Runde fertig ist, spätestens
    /// nach 20 Sekunden, genau einmal. Vorher kam sie vor jeder Arbeit: HealthKit drosselt die
    /// Zustellung, wenn die Completion dreimal ausbleibt, und wertet eine sofortige Antwort als
    /// "erledigt", bevor etwas geschah. Im Modus upstream bleibt es beim Original: sofort.
    ///
    /// - Parameter trigger: Testnaht, Vorgabe ist `triggerCombinedSync`.
    internal func handleObserverWake(
        typeIdentifier: String,
        completionHandler: @escaping () -> Void,
        trigger: ((String?) -> Void)? = nil
    ) {
        let start: (String?) -> Void = trigger ?? { [weak self] identifier in
            self?.triggerCombinedSync(typeIdentifier: identifier)
        }
        guard orchestration == .lanes else {
            start(typeIdentifier)
            completionHandler()
            return
        }
        let shot = OneShot(completionHandler)
        observerCompletions.add(shot)
        shot.fireAfter(Self.observerCompletionCap)
        start(typeIdentifier)
    }

    /// Feuert alle wartenden Observer-Rückmeldungen. Aufgerufen, wenn eine Live-Runde fertig ist,
    /// wenn ein Zyklus endet und wenn ein Lauf gar nicht erst beginnt: dann gibt es nichts mehr,
    /// worauf sie warten könnten.
    internal func fireObserverCompletions() {
        observerCompletions.fireAll()
    }
}

// MARK: - Nachholen auf Anforderung

/// Was `requestBackfillTypes` getan hat (Review ME-04). Nur HK-Identifier, nie Werte.
public struct BackfillRequestResult: Equatable, Sendable {
    /// Neu vorgemerkt: der Typ holt über das Sync-Fenster nach, sein Spiegel-Abgleich ist vergessen.
    public let queued: [String]
    /// Holte schon nach und behält seinen Stand. Hier hat sich nichts geändert.
    public let alreadyPending: [String]
    /// Nicht verfolgt oder unbekannt, ignoriert.
    public let ignored: [String]
    /// Nichts verändert: Modus upstream, oder der Plan ließ sich nicht speichern.
    public let failed: Bool

    public init(queued: [String], alreadyPending: [String], ignored: [String], failed: Bool) {
        self.queued = queued
        self.alreadyPending = alreadyPending
        self.ignored = ignored
        self.failed = failed
    }
}

extension OpenWearablesHealthSDK {

    /// Holt Typen nach, ohne Anchors zurückzusetzen (Ersatz für den bisherigen Anchor-Reset der
    /// Diagnose, der ein Neu-Export war).
    ///
    /// Nur im Modus lanes; im Modus upstream liefert der Aufruf `false` und ändert nichts. Für jeden
    /// bekannten Identifier entsteht ein offener Nachhol-Eintrag über das Sync-Fenster (Herkunft
    /// `request`); ein Typ, der schon nachholt, behält seinen Stand. Unbekannte Identifier werden
    /// ignoriert. Die Anchors der Live-Spur bleiben unangetastet: neue Daten laufen wie immer zuerst.
    ///
    /// - Returns: `true`, wenn mindestens ein Typ im Plan steht und ein Zyklus angestoßen wurde.
    ///   Was davon neu ist, sagt `requestBackfillTypes`.
    @discardableResult
    public func requestBackfill(typeIdentifiers: [String]) -> Bool {
        let result = requestBackfillTypes(typeIdentifiers)
        return !result.failed && !(result.queued.isEmpty && result.alreadyPending.isEmpty)
    }

    /// Wie `requestBackfill`, mit Auskunft je Typ (Review ME-04).
    ///
    /// Der Eintrag wird als ein Schritt auf den Stand der Datei gesetzt (`FileBackfillStore.update`):
    /// ein Zyklus, der gerade nachholt, überschreibt ihn nicht mehr, sondern übernimmt ihn noch im
    /// selben Zyklus. Der Spiegel-Abgleich für Messwerte (`resetMirrorDedupe`) wird erst danach und
    /// nur für die neu vorgemerkten Typen zurückgesetzt, sonst gälte das erneute Senden eines
    /// Messwerts als Spiegelkopie und käme nie an. Ein Typ, der schon nachholte, behält ihn: an
    /// seinem Nachholen ändert sich nichts.
    public func requestBackfillTypes(_ typeIdentifiers: [String]) -> BackfillRequestResult {
        guard orchestration == .lanes else {
            logMessage("requestBackfill ignored: orchestration is upstream")
            return BackfillRequestResult(queued: [], alreadyPending: [], ignored: [], failed: true)
        }
        let known = Set(getQueryableTypes().map { $0.identifier })
        var identifiers: [String] = []
        var ignored: [String] = []
        for identifier in typeIdentifiers {
            if known.contains(identifier) {
                if !identifiers.contains(identifier) { identifiers.append(identifier) }
            } else if !ignored.contains(identifier) {
                ignored.append(identifier)
            }
        }
        if !ignored.isEmpty {
            logMessage("requestBackfill: ignoring \(ignored.count) unknown type(s)")
        }
        guard !identifiers.isEmpty else {
            return BackfillRequestResult(queued: [], alreadyPending: [], ignored: ignored, failed: false)
        }

        let now = Date()
        let daysBack = lanesDaysBack()
        var queued: [String] = []
        var alreadyPending: [String] = []
        do {
            try makeBackfillStore().update { plan in
                queued = []
                alreadyPending = []
                for identifier in identifiers {
                    if plan.start(typeId: identifier, now: now, daysBack: daysBack, origin: "request") {
                        queued.append(identifier)
                    } else {
                        alreadyPending.append(identifier)
                    }
                }
            }
        } catch {
            // Nicht lesbar oder die Platte: nichts anfassen, der Aufrufer erfährt es.
            logMessage("requestBackfill: plan could not be saved")
            return BackfillRequestResult(queued: [], alreadyPending: [], ignored: ignored, failed: true)
        }
        if !queued.isEmpty {
            resetMirrorDedupe(forTypes: queued)
        }
        let events = queued.map { "request:\($0)" } + alreadyPending.map { "requestPending:\($0)" }
        runJournal.record(SyncJournalEntry(
            at: now, kind: "backfill", orchestration: "lanes",
            note: LaneEventSummary.note(events, shorten: { shortTypeName($0) })
        ))
        logMessage("requestBackfill: \(queued.count) type(s) queued, \(alreadyPending.count) already pending")

        syncAll(fullExport: false, trigger: .app("backfill")) { _ in }
        return BackfillRequestResult(queued: queued, alreadyPending: alreadyPending, ignored: ignored, failed: false)
    }
}

// MARK: - Spike S1: Anchor-Sonde

/// Ergebnis der Anchor-Sonde für einen Typ (Spike S1, D-06, A1).
///
/// `probeRowID` ist der Anchor, den eine Anchored Query mit nie treffendem Prädikat liefert,
/// `walkRowID` der aus dem Durchlauf über das Fenster (10.000 je Schritt, ohne Upload). Gleicher
/// Anchor in beiden heißt: die Sonde kann den Durchlauf ersetzen.
public struct AnchorProbeResult: Sendable, Equatable {
    public let typeIdentifier: String
    public let probeRowID: Int?
    public let walkRowID: Int?
    /// Die archivierten Bytes beider Anchors sind gleich.
    public let sameAnchor: Bool
    public let probeMs: Int
    public let walkMs: Int
    /// `unknown type`, `locked` oder ein Kurztext. `nil`, wenn beide Messungen gelungen sind.
    public let error: String?
}

enum AnchorProbe {

    /// Liest die `rowid` aus einem archivierten `HKQueryAnchor`. Das Archiv ist eine
    /// Property-List (NSKeyedArchiver); die `rowid` steht in dem Objekt, das den Anchor beschreibt
    /// (`$objects[1]` bei den Anchors vom Gerät). `nil`, wenn es sich nicht lesen lässt.
    static func rowID(from archived: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: archived, options: [], format: nil),
              let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any] else {
            return nil
        }
        for object in objects {
            guard let dictionary = object as? [String: Any], let value = dictionary["rowid"] as? NSNumber else { continue }
            return value.intValue
        }
        return nil
    }
}

extension OpenWearablesHealthSDK {

    /// Spike S1: je Typ nacheinander die Sonde (Anchored Query, deren Prädikat nichts trifft, ohne
    /// Anchor) und der Durchlauf (`captureAnchorStep`, Limit 10.000), ohne Upload und ohne etwas
    /// festzuschreiben. Verglichen werden die archivierten Bytes und die `rowid`, dazu die Dauer.
    ///
    /// Je Typ ein Journal-Eintrag `spike`: `S1 <kurzname> probe=<id> walk=<id> same=<bool>
    /// probeMs=<n> walkMs=<n>`. Der Schalter `lanes.anchorProbe` wird nicht umgestellt: das
    /// entscheidet Robert nach dem Spike.
    ///
    /// Der Durchlauf braucht bei dichten Typen Sekunden bis Minuten. `completion` kommt auf der
    /// Hauptschlange.
    public func probeAnchors(typeIdentifiers: [String], completion: @escaping ([AnchorProbeResult]) -> Void) {
        // Eine Generation, die es nie gibt: die Lebenszeichen des Durchlaufs verlängern keine Sperre.
        let reader = HealthKitReader(sdk: self, generation: -1)
        var results: [AnchorProbeResult] = []

        func finish() {
            DispatchQueue.main.async { completion(results) }
        }

        func record(_ result: AnchorProbeResult) {
            results.append(result)
            runJournal.record(SyncJournalEntry(at: Date(), kind: "spike", note: Self.spikeNote(result, short: shortTypeName(result.typeIdentifier))))
        }

        func next(_ index: Int) {
            guard index < typeIdentifiers.count else {
                finish()
                return
            }
            let identifier = typeIdentifiers[index]
            guard let type = reader.resolveType(identifier) else {
                record(AnchorProbeResult(
                    typeIdentifier: identifier, probeRowID: nil, walkRowID: nil, sameAnchor: false,
                    probeMs: 0, walkMs: 0, error: "unknown type"
                ))
                next(index + 1)
                return
            }

            let probeStart = Date()
            reader.anchorByProbe(type: type) { probe in
                let probeMs = Self.milliseconds(since: probeStart)
                let walkStart = Date()
                reader.anchorByPass(type: type) { walk in
                    let walkMs = Self.milliseconds(since: walkStart)
                    var probeData: Data?
                    var walkData: Data?
                    var failures: [String] = []
                    switch probe {
                    case .success(let data): probeData = data
                    case .failure(let failure): failures.append("probe=\(Self.describe(failure))")
                    }
                    switch walk {
                    case .success(let data): walkData = data
                    case .failure(let failure): failures.append("walk=\(Self.describe(failure))")
                    }
                    record(AnchorProbeResult(
                        typeIdentifier: identifier,
                        probeRowID: probeData.flatMap { AnchorProbe.rowID(from: $0) },
                        walkRowID: walkData.flatMap { AnchorProbe.rowID(from: $0) },
                        sameAnchor: probeData != nil && probeData == walkData,
                        probeMs: probeMs,
                        walkMs: walkMs,
                        error: failures.isEmpty ? nil : failures.joined(separator: " ")
                    ))
                    next(index + 1)
                }
            }
        }
        next(0)
    }

    /// Die Zeile im Journal. Nur Kurzname, rowids, Wahrheitswert und Laufzeiten, keine Werte (T-05-33).
    internal static func spikeNote(_ result: AnchorProbeResult, short: String) -> String {
        func id(_ value: Int?) -> String { value.map(String.init) ?? "nil" }
        var note = "S1 \(short) probe=\(id(result.probeRowID)) walk=\(id(result.walkRowID))"
        note += " same=\(result.sameAnchor) probeMs=\(result.probeMs) walkMs=\(result.walkMs)"
        if let error = result.error { note += " error=\(error)" }
        return note
    }

    private static func milliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private static func describe(_ failure: ReadFailure) -> String {
        switch failure {
        case .locked: return "locked"
        case .other(let text): return text.replacingOccurrences(of: " ", with: "_")
        }
    }
}

// MARK: - Szenario 4: hängende Sperre erzwingen

// Nur in Debug-Builds (T-05-32): in ausgelieferten Builds gibt es diesen Haken nicht. Er simuliert
// einen HealthKit-Rückruf, der nie kommt, ohne Debugger und ohne Umgebungsvariable: die App ruft
// ihn aus der Diagnose auf, danach hängt genau die nächste Live-Abfrage. Die Sperre verfällt nach
// 150 Sekunden, der nächste Auslöser übernimmt, der alte Lauf schreibt nichts mehr fest.
#if DEBUG
extension OpenWearablesHealthSDK {
    public func debugHangNextLiveFetch() {
        hangFlagLock.lock()
        hangNextLiveFetchArmed = true
        hangFlagLock.unlock()
        runJournal.record(SyncJournalEntry(at: Date(), kind: "spike", note: "hang armed"))
        logMessage("Debug: the next live fetch will hang")
    }

    /// Verbraucht das Einmal-Flag. `true` genau für den ersten Aufruf nach `debugHangNextLiveFetch()`.
    internal func consumeHangNextLiveFetch() -> Bool {
        hangFlagLock.lock()
        defer { hangFlagLock.unlock() }
        let armed = hangNextLiveFetchArmed
        hangNextLiveFetchArmed = false
        return armed
    }
}
#endif
