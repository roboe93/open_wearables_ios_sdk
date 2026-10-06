import Foundation
import HealthKit

// Fork-Zusatz (roboe93), Plan 05-07. Der Paket-Sender der Zwei-Spuren-Steuerung.
//
// Er erfüllt `Delivering` (LaneContracts): Mirror-Dedupe, Routen für Workouts, Paket bauen,
// hochladen, Ergebnis abbilden. Der Upload selbst (401-Pfad, Request-Id, Tracking, Abbruch je
// Generation) bleibt der vorhandene Status-Upload aus `Outbox.swift`, hier entsteht kein zweiter
// Upload-Code (Recherche "Don't Hand-Roll").
//
// Löschungen (D-12): Der Kern schreibt sie nach der Annahme in die Warteschlange. Der Sender
// schickt sie nur mit, wenn `lanes.sendDeletions` an ist. Railway kennt das Feld `deleted` nicht
// (Befund 5) und ignoriert es: ohne den Schalter bleibt das Paket Byte für Byte wie bisher
// (T-05-26). Das Format `data.deleted: [{"id", "type"}]` legt Phase 9 auf dem neuen Server fest.
//
// Zweitziel (D-08, Plan 09-04): Ist es aktiv (Schalter `lanes.secondary.enabled`, Standard aus,
// Ziel konfiguriert, Modus `lanes`), reiht der Sender nach dem 2xx des Primärziels und vor
// `completion` dasselbe Paket in die Datei-Outbox des Zweitziels ein. Einreihen nur nach Primär-2xx
// (Recherche, Dual-Sink Punkt 1): Beide Ziele spiegeln denselben bestätigten Stand, ein vom
// Primärziel abgewiesenes Paket (Halbieren, Parken) erreicht das Zweitziel nie, und die Anchors
// schreibt weiter allein der Kern nach dem Primärziel fest. Das Paket fürs Primärziel entsteht genau
// wie vorher. Das Zweitpaket trägt immer `data.deleted` (eigene plus fürs Zweitziel ungesendete,
// unabhängig von `lanes.sendDeletions`) und nur die Typen der Auswahl (K4). Ein Fehler beim
// Einreihen wird gezählt, beendet aber nie den Zyklus.

final class PayloadSink: Delivering {
    typealias Item = HKSample

    /// Höchstens so viele Löschungen pro Paket. Die eigenen Löschungen des Pakets gehen immer
    /// vollständig mit (der Kern markiert sie nach der Annahme als gesendet, ein gekürztes Paket
    /// würde sonst Löschungen als gesendet führen, die der Server nie sah). Ältere, noch
    /// ungesendete Einträge der Warteschlange füllen bis zu dieser Zahl auf.
    static let maxDeletionsPerPackage = 500

    /// Herkunft der Nachhol-Pakete.
    private static let historicalType = "historical"
    /// Herkunft der Live-Pakete: nie "historical" (Pitfall 7).
    private static let liveType = "live"

    private weak var sdk: OpenWearablesHealthSDK?
    private let endpoint: URL
    private let credential: String
    private let generation: Int
    private let deletions: DeletionQueue
    private let backfill: BackfillStoring
    private let sendDeletions: Bool
    private let clock: LaneClock
    /// Die Outbox des Zweitziels, nur wenn es zu Beginn des Zyklus aktiv war. Wie `sendDeletions`
    /// gilt die Entscheidung für den ganzen Zyklus.
    private let secondary: SecondaryOutbox?
    /// Typauswahl des Zweitziels (HK-Identifier), leer heißt alle.
    private let secondaryTypes: Set<String>
    private let countsLock = NSLock()
    private var enqueuedCount = 0
    private var failedCount = 0

    /// Ein Sender je Zyklus. `sendDeletions` gilt für den ganzen Zyklus: ein Schalter, der mitten
    /// im Lauf umspringt, ändert das Format erst im nächsten.
    init(
        sdk: OpenWearablesHealthSDK,
        endpoint: URL,
        credential: String,
        generation: Int,
        deletions: DeletionQueue,
        backfill: BackfillStoring,
        sendDeletions: Bool? = nil,
        clock: LaneClock = SystemLaneClock()
    ) {
        self.sdk = sdk
        self.endpoint = endpoint
        self.credential = credential
        self.generation = generation
        self.deletions = deletions
        self.backfill = backfill
        self.sendDeletions = sendDeletions ?? sdk.lanesSendDeletions
        self.clock = clock
        self.secondary = sdk.isSecondarySinkActive ? sdk.makeSecondaryOutbox() : nil
        self.secondaryTypes = Set(sdk.lanesSecondaryTypes)
    }

    /// Eingereihte und gescheiterte Zweitpakete dieses Senders, für das Journal nach dem Zyklus.
    var secondaryCounts: (enqueued: Int, failed: Int) {
        countsLock.lock()
        defer { countsLock.unlock() }
        return (enqueuedCount, failedCount)
    }

    // MARK: Delivering

    func deliver(
        _ items: [HKSample], deleted: [DeletedRef], lane: Lane,
        completion: @escaping (DeliveryResult) -> Void
    ) {
        guard let sdk = sdk else {
            completion(.failed("sdk released"))
            return
        }

        // Spiegelungen anderer Apps aussortieren. Die Schlüssel werden erst nach der Annahme
        // festgeschrieben: bis dahin gilt nichts als geliefert.
        let deduped = sdk.mirrorDedupe.filterMirrored(items) { sdk.measurementKey(for: $0) }
        let samples = deduped.kept
        // Was nicht hinausgeht, zählt der Kern nicht als übertragen (Review ME-06).
        let notSent = Self.countByType(items, minus: samples)

        // Ohne Schalter geht nichts von den Löschungen auf die Leitung. Der Kern schreibt sie
        // trotzdem in die Warteschlange.
        let ownDeletions = sendDeletions ? deleted : []

        guard !samples.isEmpty || !ownDeletions.isEmpty else {
            // Nichts, was ein Paket wert wäre (alles gespiegelt, oder nur Löschungen ohne Schalter).
            completion(.accepted(sentDeleted: false, notSent: notSent))
            return
        }

        let backlog = sendDeletions ? olderUnsentDeletions(besides: ownDeletions) : []
        let packageDeletions = ownDeletions + backlog

        let attribution: (sessionId: String?, syncType: String) = {
            switch lane {
            case .live: return (nil, Self.liveType)
            case .backfill: return (backfill.load().sessionId, Self.historicalType)
            }
        }()

        // Routen liegen nicht im Workout selbst, sondern in eigenen Samples, die nur asynchron zu
        // haben sind (Fork, GPS). Für alles andere kommt der Rückruf ohne Abfrage sofort.
        let workouts = samples.compactMap { $0 as? HKWorkout }
        sdk.collectRoutes(for: workouts) { [self] routes in
            guard let sdk = self.sdk else {
                completion(.failed("sdk released"))
                return
            }
            if !routes.isEmpty {
                let points = routes.values.reduce(0) { $0 + $1.count }
                sdk.logMessage("  Routes: \(routes.count) workout(s), \(points) fixes")
            }

            let payload = sdk.buildCombinedPayload(
                samples: samples, routes: routes, deleted: packageDeletions, attribution: attribution
            )

            self.upload(payload, sdk: sdk) { [self] result in
                switch result {
                case .accepted:
                    sdk.mirrorDedupe.commit(deduped.newKeys)
                    self.markSent(backlog, sdk: sdk)
                    self.enqueueSecondary(
                        samples: samples, routes: routes, own: deleted, attribution: attribution, sdk: sdk
                    )
                    completion(.accepted(sentDeleted: !packageDeletions.isEmpty, notSent: notSent))
                case .rejected(let status)
                    where !packageDeletions.isEmpty && !samples.isEmpty && RejectionPolicy.isRecordSpecific(status):
                    // Review HI-02: Der Server kann das Paket wegen der Löschungen abweisen (Feld
                    // `deleted` unbekannt, eine Altlast). Dann gingen gültige Samples ins Halbieren und
                    // am Ende ins Parken. Einmal ohne Löschungen wiederholen: wird das angenommen, sind
                    // die Samples durch und die Löschungen bleiben ungesendet in der Warteschlange.
                    sdk.logMessage("Package rejected (HTTP \(status)) with deletions - retrying once without them")
                    let withoutDeletions = sdk.buildCombinedPayload(
                        samples: samples, routes: routes, deleted: [], attribution: attribution
                    )
                    self.upload(withoutDeletions, sdk: sdk) { retry in
                        switch retry {
                        case .accepted:
                            sdk.mirrorDedupe.commit(deduped.newKeys)
                            // Das Zweitziel bekommt die Löschungen trotzdem: es kennt das Feld.
                            self.enqueueSecondary(
                                samples: samples, routes: routes, own: deleted, attribution: attribution, sdk: sdk
                            )
                            completion(.accepted(sentDeleted: false, notSent: notSent))
                        default:
                            completion(Self.deliveryResult(retry))
                        }
                    }
                default:
                    completion(Self.deliveryResult(result))
                }
            }
        }
    }

    /// Je HK-Identifier: wie viele aus `all` nicht in `kept` sind. Nur Einträge über null.
    private static func countByType(_ all: [HKSample], minus kept: [HKSample]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for sample in all { counts[sample.sampleType.identifier, default: 0] += 1 }
        for sample in kept { counts[sample.sampleType.identifier, default: 0] -= 1 }
        return counts.filter { $0.value > 0 }
    }

    /// Lädt ein Paket über den Status-Upload aus `Outbox.swift` hoch.
    private func upload(
        _ payload: [String: Any], sdk: OpenWearablesHealthSDK,
        completion: @escaping (UploadResult) -> Void
    ) {
        // Wie im Upstream-Pfad der frische Token: ein Refresh mitten im Zyklus gilt sofort.
        let credential = sdk.authCredential ?? self.credential
        sdk.uploadCombinedPayloadReportingStatus(
            payload: payload, endpoint: endpoint, credential: credential, generation: generation,
            completion: completion
        )
    }

    /// Ein Upload-Ergebnis ohne Annahme als Lieferergebnis.
    private static func deliveryResult(_ result: UploadResult) -> DeliveryResult {
        switch result {
        case .accepted:
            return .accepted(sentDeleted: false)
        case .rejected(let status):
            return .rejected(httpStatus: status)
        case .failed(let text):
            return .failed(text)
        case .cancelled:
            return .cancelled
        }
    }

    /// Der Datensatz für `health_rejected/`: dasselbe Paket, das der Server abgewiesen hat, für
    /// dieses eine Sample. Ohne Routen (sie machen die Datei groß, und sie sind nie der Grund) und
    /// ohne Herkunft aus der Sitzungsdatei (die Datei wird hier nicht angefasst, Pattern 9).
    func parkingRecord(for item: HKSample) -> Data? {
        guard let sdk = sdk else { return nil }
        let payload = sdk.buildCombinedPayload(
            samples: [item], attribution: (sessionId: nil, syncType: Self.liveType)
        )
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: Zweitziel (Plan 09-04)

    /// K4: Nur die Samples der Typauswahl, nach HK-Identifier (Workouts `HKWorkoutTypeIdentifier`,
    /// Schlaf `HKCategoryTypeIdentifierSleepAnalysis`). Leer heißt alle.
    static func secondarySamples(_ samples: [HKSample], types: Set<String>) -> [HKSample] {
        guard !types.isEmpty else { return samples }
        return samples.filter { types.contains($0.sampleType.identifier) }
    }

    /// Nach dem 2xx des Primärziels, vor `completion`: das Zweitpaket bauen, dauerhaft einreihen und
    /// erst danach seine Löschungen fürs Zweitziel als gesendet führen. Gesendet wird es später vom
    /// Sender des Zweitziels, nie hier.
    private func enqueueSecondary(
        samples: [HKSample], routes: [UUID: [RouteFix]], own: [DeletedRef],
        attribution: (sessionId: String?, syncType: String), sdk: OpenWearablesHealthSDK
    ) {
        guard let outbox = secondary else { return }

        let kept = Self.secondarySamples(samples, types: secondaryTypes)
        let backlog = olderUnsentSecondaryDeletions(besides: own)
        let packageDeletions = own + backlog
        guard !kept.isEmpty || !packageDeletions.isEmpty else { return }

        let payload = sdk.buildCombinedPayload(
            samples: kept, routes: routes, deleted: packageDeletions, attribution: attribution
        )
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try outbox.enqueue(data)
        } catch {
            countsLock.lock()
            failedCount += 1
            countsLock.unlock()
            outbox.recordEnqueueFailure()
            sdk.logMessage("Secondary: package not queued (\(kept.count) records, \(packageDeletions.count) deletions)")
            return
        }
        countsLock.lock()
        enqueuedCount += 1
        countsLock.unlock()
        markSentSecondary(own: own, backlog: backlog, sdk: sdk)
    }

    /// Die eigenen Löschungen stehen noch nicht in der Warteschlange (der Kern schreibt sie erst nach
    /// `completion`): sie entstehen hier mit `sentSecondaryAt`, ihr `sentAt` setzt danach der Kern.
    /// Scheitert das, liegt das Paket trotzdem in der Outbox; die Einträge gehen dann ein zweites Mal
    /// mit, der Server nimmt Löschungen idempotent an.
    private func markSentSecondary(own: [DeletedRef], backlog: [DeletedRef], sdk: OpenWearablesHealthSDK) {
        guard !own.isEmpty || !backlog.isEmpty else { return }
        let now = clock.now()
        do {
            try deletions.enqueue(own, sentAt: nil, sentSecondaryAt: now)
            try deletions.markSentSecondary(ids: backlog.map { $0.id }, at: now)
        } catch {
            sdk.logMessage("Löschwarteschlange: \(own.count + backlog.count) Einträge ließen sich fürs Zweitziel nicht als gesendet markieren")
        }
    }

    // MARK: Löschungen

    /// Ältere, noch ungesendete Einträge der Warteschlange, ohne die eigenen des Pakets (die kämen
    /// sonst doppelt in `data.deleted`).
    private func olderUnsentDeletions(besides own: [DeletedRef]) -> [DeletedRef] {
        Self.fill(besides: own) { deletions.unsent(limit: $0) }
    }

    /// Dasselbe fürs Zweitziel, nach dessen eigenem Kennzeichen.
    private func olderUnsentSecondaryDeletions(besides own: [DeletedRef]) -> [DeletedRef] {
        Self.fill(besides: own) { deletions.unsentSecondary(limit: $0) }
    }

    /// Füllt bis `maxDeletionsPerPackage` auf, ohne die eigenen Kennungen zu wiederholen.
    private static func fill(besides own: [DeletedRef], unsent: (Int) -> [DeletedRef]) -> [DeletedRef] {
        let room = maxDeletionsPerPackage - own.count
        guard room > 0 else { return [] }
        let ownIds = Set(own.map { $0.id })
        // Mehr anfordern, damit nach dem Herausfiltern der eigenen noch `room` übrig sind.
        let candidates = unsent(room + ownIds.count)
        return Array(candidates.filter { !ownIds.contains($0.id) }.prefix(room))
    }

    /// Nach der Annahme: die mitgeschickten Altlasten sind gesendet. Scheitert das Markieren, ist
    /// das Paket trotzdem angekommen: die Einträge gehen beim nächsten Paket noch einmal mit, der
    /// Server nimmt Wiederholungen idempotent an.
    private func markSent(_ refs: [DeletedRef], sdk: OpenWearablesHealthSDK) {
        guard !refs.isEmpty else { return }
        do {
            try deletions.markSent(ids: refs.map { $0.id }, at: clock.now())
        } catch {
            sdk.logMessage("Löschwarteschlange: \(refs.count) Einträge ließen sich nicht als gesendet markieren")
        }
    }
}
