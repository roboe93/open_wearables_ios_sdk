import Foundation

// Fork-Zusatz (roboe93), Review 05 HI-02. Geparkte Datensätze bleiben sichtbar und lassen sich
// erneut senden.
//
// Warum es das gibt: Ein Datensatz, den der Server dreimal abweist, wird geparkt
// (`RejectionPolicy`, `health_rejected/`), und der Anchor rückt darüber hinaus. Bis 0.15.0-ow.2
// gab es keinen Rückweg: nichts sendete die Ablage erneut, und nach dem nächsten sauberen Lauf
// zeigte nichts mehr, dass dort Daten liegen. Hat der Server den Fehler behoben (Validierung, neuer
// Endpunkt nach dem Umzug), blieben die Daten trotzdem draußen. Jetzt:
//
//   * `parkedRecordCount` und `getSyncStatus()["parkedRecords"]` zeigen, wie viele noch liegen.
//   * `replayParked` sendet sie erneut, Datei für Datei, im Sync-Slot (kein zweiter Schreiber neben
//     einem Zyklus). Angenommenes wandert nach `health_rejected/replayed/`, nie gelöscht; erneut
//     Abgewiesenes bleibt liegen. Ein Netz- oder Serverfehler beendet den Durchgang, der Rest bleibt.

/// Was `replayParked` getan hat. Nur Zahlen, nie Werte.
public struct ParkedReplayResult: Equatable, Sendable {
    /// Vom Server angenommen und nach `health_rejected/replayed/` verschoben.
    public let resent: Int
    /// Erneut wegen des Inhalts abgewiesen (400, 413, 422). Liegt weiter in der Ablage.
    public let stillRejected: Int
    /// Nicht versucht (Abbruch nach einem Fehler, Slot belegt, kein lesbarer Datensatz). Liegt weiter
    /// in der Ablage.
    public let remaining: Int
    /// Warum der Durchgang früher endete: `busy`, `no auth`, `cancelled`, `HTTP 503`, `network(…)`.
    /// `nil`, wenn alles versucht wurde.
    public let failure: String?

    public init(resent: Int, stillRejected: Int, remaining: Int, failure: String?) {
        self.resent = resent
        self.stillRejected = stillRejected
        self.remaining = remaining
        self.failure = failure
    }
}

extension OpenWearablesHealthSDK {

    /// Wie viele Datensätze geparkt sind und auf eine Annahme warten (ohne `replayed/`). Liest
    /// das Verzeichnis, also nicht in einer engen Schleife aufrufen.
    public var parkedRecordCount: Int {
        makeRejectionParking().parkedCount()
    }

    /// Sendet die geparkten Datensätze erneut. `completion` kommt auf der Hauptschlange.
    ///
    /// Der Durchgang nimmt den Sync-Slot wie ein Lauf: hält ihn ein anderer Lauf, endet er sofort mit
    /// `failure == "busy"` und fasst nichts an. Gesendet wird genau das Paket, das beim Parken
    /// abgewiesen wurde. Ein Eintrag im Journal (`parked`) hält das Ergebnis fest, ohne Werte.
    public func replayParked(completion: @escaping (ParkedReplayResult) -> Void) {
        let parking = makeRejectionParking()
        let files = parking.parkedFiles()

        func report(_ result: ParkedReplayResult) {
            var note = "replay resent=\(result.resent) rejected=\(result.stillRejected) remaining=\(result.remaining)"
            if let failure = result.failure { note += " failure=\(failure)" }
            runJournal.record(SyncJournalEntry(at: Date(), kind: "parked", note: note))
            logMessage("Parked records: \(note)")
            DispatchQueue.main.async { completion(result) }
        }

        guard !files.isEmpty else {
            report(ParkedReplayResult(resent: 0, stillRejected: 0, remaining: 0, failure: nil))
            return
        }
        guard let credential = authCredential, let endpoint = syncEndpoint else {
            report(ParkedReplayResult(resent: 0, stillRejected: 0, remaining: files.count, failure: "no auth"))
            return
        }
        guard let generation = beginSyncRun() else {
            report(ParkedReplayResult(resent: 0, stillRejected: 0, remaining: files.count, failure: "busy"))
            return
        }

        var resent = 0
        var stillRejected = 0
        var unreadable = 0

        func finish(remaining: Int, failure: String?) {
            finishSync(generation: generation)
            report(ParkedReplayResult(
                resent: resent, stillRejected: stillRejected, remaining: remaining + unreadable, failure: failure
            ))
        }

        func next(_ index: Int) {
            guard index < files.count else {
                finish(remaining: 0, failure: nil)
                return
            }
            let file = files[index]
            guard let payload = parking.payload(of: file) else {
                // Ohne lesbaren Datensatz gibt es nichts zu senden. Die Datei bleibt, wie sie ist.
                unreadable += 1
                next(index + 1)
                return
            }
            heartbeat(generation: generation)
            uploadCombinedPayloadReportingStatus(
                payload: payload, endpoint: endpoint, credential: authCredential ?? credential, generation: generation
            ) { [self] result in
                switch result {
                case .accepted:
                    resent += 1
                    do {
                        try parking.markReplayed(file)
                    } catch {
                        // Angekommen ist er trotzdem. Er liegt weiter in der Ablage und ginge beim
                        // nächsten Durchgang noch einmal raus; der Server nimmt das idempotent an.
                        logMessage("Parked record accepted but could not be moved aside")
                    }
                    next(index + 1)
                case .rejected(let status) where RejectionPolicy.isRecordSpecific(status):
                    stillRejected += 1
                    next(index + 1)
                case .rejected(let status):
                    finish(remaining: files.count - index, failure: "HTTP \(status)")
                case .failed(let text):
                    finish(remaining: files.count - index, failure: text)
                case .cancelled:
                    finish(remaining: files.count - index, failure: "cancelled")
                }
            }
        }
        next(0)
    }
}
