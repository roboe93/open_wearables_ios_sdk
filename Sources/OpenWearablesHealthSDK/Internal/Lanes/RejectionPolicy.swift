import Foundation

// Fork-Zusatz (roboe93), Plan 05-06. Was geschieht, wenn der Server ein Paket abweist.
//
// Das Original (0.15) bewegt bei 4xx den Cursor nicht (CHANGELOG "HTTP 4xx no longer
// advances"). Ein dauerhaft abgewiesener Chunk blockiert den Typ dann ohne Spur: die
// "Giftpille" (Recherche, Pitfall 3). Hier wird daraus eine begrenzte Reihe von Schritten:
//
//   1. Chunk halbieren, bis der Verursacher einzeln dasteht. Das zählt nicht als Ablehnung.
//   2. Einzeln abgewiesen: bis zum nächsten Zyklus warten (`holdUntilNextCycle`).
//   3. Die dritte Ablehnung in getrennten Zyklen: parken (`park`).
//
// Warum nicht sofort parken: Ein produktiver `ClientDisconnect` liefert vorübergehend 400,
// obwohl der Datensatz in Ordnung ist. Erst drei Ablehnungen in getrennten Zyklen, also
// über Stunden, machen daraus ein dauerhaftes Urteil. Geparkte Datensätze liegen in
// `health_rejected/` und werden nie still verworfen. Der Typ blockiert dabei keinen anderen.

enum RejectionAction: Equatable {
    /// Mit dem halben Limit erneut von derselben Stelle lesen.
    case halve(to: Int)
    /// Einzeln abgewiesen: dieser Typ ruht bis zum nächsten Zyklus, alle anderen laufen weiter.
    case holdUntilNextCycle
    /// Zum dritten Mal in getrennten Zyklen abgewiesen: ablegen, der Cursor rückt darüber hinaus.
    case park
}

enum RejectionPolicy {

    /// Ablehnungen eines einzelnen Datensatzes in getrennten Zyklen, bevor er geparkt wird.
    static let parkAfter = 3

    /// - Parameters:
    ///   - state: der gespeicherte Zustand des Typs und der Spur (`nil`: noch nie abgewiesen).
    ///   - httpStatus: Status der Antwort.
    ///   - attemptedLimit: so viele Datensätze enthielt das abgewiesene Paket dieses Typs.
    /// - Returns: der neue Zustand zum Speichern und die nächste Handlung. Nach einer Annahme
    ///   wird der Zustand gelöscht (`BackfillPlan.clearRejection`).
    static func decide(
        state: RejectionState?, httpStatus: Int, attemptedLimit: Int
    ) -> (RejectionState, RejectionAction) {
        let previous = state?.consecutive ?? 0

        if attemptedLimit > 1 {
            // Halbieren ist Eingrenzen, keine Ablehnung des Einzeldatensatzes: der Zähler
            // bleibt, wie er war.
            let half = attemptedLimit / 2
            return (RejectionState(consecutive: previous, limit: half, lastStatus: httpStatus), .halve(to: half))
        }

        let consecutive = previous + 1
        let next = RejectionState(consecutive: consecutive, limit: 1, lastStatus: httpStatus)
        return (next, consecutive >= parkAfter ? .park : .holdUntilNextCycle)
    }
}
