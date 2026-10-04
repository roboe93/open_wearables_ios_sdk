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

        // Ohne Schalter geht nichts von den Löschungen auf die Leitung. Der Kern schreibt sie
        // trotzdem in die Warteschlange.
        let ownDeletions = sendDeletions ? deleted : []

        guard !samples.isEmpty || !ownDeletions.isEmpty else {
            // Nichts, was ein Paket wert wäre (alles gespiegelt, oder nur Löschungen ohne Schalter).
            completion(.accepted(sentDeleted: false))
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
            // Wie im Upstream-Pfad der frische Token: ein Refresh mitten im Zyklus gilt sofort.
            let credential = sdk.authCredential ?? self.credential

            sdk.uploadCombinedPayloadReportingStatus(
                payload: payload, endpoint: self.endpoint, credential: credential, generation: self.generation
            ) { [self] result in
                switch result {
                case .accepted:
                    sdk.mirrorDedupe.commit(deduped.newKeys)
                    self.markSent(backlog, sdk: sdk)
                    completion(.accepted(sentDeleted: !packageDeletions.isEmpty))
                case .rejected(let status):
                    completion(.rejected(httpStatus: status))
                case .failed(let text):
                    completion(.failed(text))
                case .cancelled:
                    completion(.cancelled)
                }
            }
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

    // MARK: Löschungen

    /// Ältere, noch ungesendete Einträge der Warteschlange, ohne die eigenen des Pakets (die kämen
    /// sonst doppelt in `data.deleted`).
    private func olderUnsentDeletions(besides own: [DeletedRef]) -> [DeletedRef] {
        let room = Self.maxDeletionsPerPackage - own.count
        guard room > 0 else { return [] }
        let ownIds = Set(own.map { $0.id })
        // Mehr anfordern, damit nach dem Herausfiltern der eigenen noch `room` übrig sind.
        let candidates = deletions.unsent(limit: room + ownIds.count)
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
