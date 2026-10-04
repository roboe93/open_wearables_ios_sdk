import Foundation

// Fork-Zusatz (roboe93), Plan 05-06. Was geschieht, wenn der Server ein Paket abweist.
//
// Das Original (0.15) bewegt bei 4xx den Cursor nicht (CHANGELOG "HTTP 4xx no longer
// advances"). Ein dauerhaft abgewiesener Chunk blockiert den Typ dann ohne Spur: die
// "Giftpille" (Recherche, Pitfall 3). Hier wird daraus eine begrenzte Reihe von Schritten:
//
//   1. Chunk halbieren, bis der Verursacher einzeln dasteht. Das zählt nicht als Ablehnung.
//   2. Einzeln abgewiesen: bis zum nächsten Zyklus warten (`holdUntilNextCycle`).
//   3. Die dritte gezählte Ablehnung: parken (`park`).
//
// Nur Antworten, die am Inhalt des Pakets hängen, laufen durch diese Schritte (Review HI-02):
// 400, 413 und 422 (`isRecordSpecific`). 403 (Rechte), 404/405 (Route fehlt nach einem Deploy oder
// dem Serverumzug), 408, 409, 429 (Rate-Limit) und alle übrigen sagen nichts über den Datensatz.
// Halbieren grenzte dort nichts ein, und Parken legte gültige Daten ab. Der Kern behandelt sie
// wie einen Serverfehler: der Zyklus endet, der Anchor bleibt, nichts wird gezählt.
//
// Warum nicht sofort parken: Ein produktiver `ClientDisconnect` liefert vorübergehend 400,
// obwohl der Datensatz in Ordnung ist. Erst drei gezählte Ablehnungen machen daraus ein
// dauerhaftes Urteil, und gezählt wird höchstens einmal je `countSpacing` (eine Stunde). Ein
// "Zyklus" ist jede eigene Kern-Instanz, im Vordergrund also Minuten: ohne den Abstand reichten
// drei Observer-Weckrufe für ein Urteil. Geparkte Datensätze liegen in `health_rejected/`, werden
// nie still verworfen und lassen sich erneut senden (`replayParked`). Der Typ blockiert dabei
// keinen anderen.

enum RejectionAction: Equatable {
    /// Mit dem halben Limit erneut von derselben Stelle lesen.
    case halve(to: Int)
    /// Einzeln abgewiesen: dieser Typ ruht bis zum nächsten Zyklus, alle anderen laufen weiter.
    case holdUntilNextCycle
    /// Zum dritten Mal gezählt abgewiesen (mit `countSpacing` Abstand): ablegen, der Cursor rückt
    /// darüber hinaus. Der Datensatz bleibt in `health_rejected/` und lässt sich erneut senden.
    case park
}

enum RejectionPolicy {

    /// Gezählte Ablehnungen eines einzelnen Datensatzes, bevor er geparkt wird.
    static let parkAfter = 3

    /// Mindestabstand zwischen zwei gezählten Ablehnungen eines Einzeldatensatzes. Eine Ablehnung
    /// innerhalb des Abstands hält den Typ bis zum nächsten Zyklus an, zählt aber nicht. Bis zum
    /// Parken vergehen damit mindestens zwei Stunden.
    static let countSpacing: TimeInterval = 3_600

    /// Hängt die Abweisung am Inhalt des Pakets? 400 (ungültig), 413 (zu groß, Halbieren hilft),
    /// 422 (Validierung). Alles andere ist kein Urteil über den Datensatz und wird nie gezählt.
    static func isRecordSpecific(_ httpStatus: Int) -> Bool {
        httpStatus == 400 || httpStatus == 413 || httpStatus == 422
    }

    /// - Parameters:
    ///   - state: der gespeicherte Zustand des Typs und der Spur (`nil`: noch nie abgewiesen).
    ///   - httpStatus: Status der Antwort, `isRecordSpecific`.
    ///   - attemptedLimit: so viele Datensätze enthielt das abgewiesene Paket dieses Typs.
    ///   - now: Zeitpunkt der Ablehnung, für den Abstand zwischen gezählten Ablehnungen.
    /// - Returns: der neue Zustand zum Speichern und die nächste Handlung. Nach einer Annahme
    ///   wird der Zustand gelöscht (`BackfillPlan.clearRejection`).
    static func decide(
        state: RejectionState?, httpStatus: Int, attemptedLimit: Int, now: Date
    ) -> (RejectionState, RejectionAction) {
        // Ein Zähler ohne Zeitpunkt (0.15.0-ow.2) wird nicht übernommen: seine Ablehnungen können
        // Minuten auseinander gelegen haben.
        let counted = state?.lastCountedAt == nil ? nil : state
        let previous = counted?.consecutive ?? 0

        if attemptedLimit > 1 {
            // Halbieren ist Eingrenzen, keine Ablehnung des Einzeldatensatzes: der Zähler
            // bleibt, wie er war.
            let half = attemptedLimit / 2
            return (
                RejectionState(consecutive: previous, limit: half, lastStatus: httpStatus, lastCountedAt: counted?.lastCountedAt),
                .halve(to: half)
            )
        }

        if let last = counted?.lastCountedAt, now.timeIntervalSince(last) < countSpacing {
            // Zu kurz nach der letzten gezählten Ablehnung: anhalten, nicht zählen.
            return (
                RejectionState(consecutive: previous, limit: 1, lastStatus: httpStatus, lastCountedAt: last),
                .holdUntilNextCycle
            )
        }

        let consecutive = previous + 1
        let next = RejectionState(consecutive: consecutive, limit: 1, lastStatus: httpStatus, lastCountedAt: now)
        return (next, consecutive >= parkAfter ? .park : .holdUntilNextCycle)
    }
}
