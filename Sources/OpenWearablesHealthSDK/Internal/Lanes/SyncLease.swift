import Foundation

// Fork-Zusatz (roboe93), Plan 05-06. Die Sperre mit Frist (D-07, SYNC-09).
//
// Warum es das gibt: 0.15 kennt Run-Generationen und eine Übernahme, aber nur 60 Sekunden nach
// `cancelSync()`. Ein Lauf, der nie zurückkehrt (ein HealthKit-Rückruf, der nie kommt) und den
// niemand abbricht, hielt den Slot bis zum Prozessende, und neue Daten warteten dahinter. Hier
// bekommt die Sperre eine Frist: wer innerhalb von `leaseDuration` kein Lebenszeichen gibt,
// verliert den Slot an den nächsten Aufrufer. Der alte Lauf ist danach über den vorhandenen
// Generationsvergleich ausgesperrt (`isSyncCancelled`) und schreibt nichts mehr fest.
//
// Lazy geprüft: kein Timer, sondern bei jedem `beginSyncRun()`. Das wirkt auch, wenn der Prozess
// dazwischen angehalten war.

enum SyncLease {

    /// Frist ohne Lebenszeichen. 150 Sekunden liegen über dem Request-Timeout der Vordergrund-Session
    /// (120 Sekunden), das aber ein Leerlauf-Timeout ist: ein Upload, der Daten bewegt, darf bis zum
    /// Resource-Timeout (600 Sekunden) laufen. Deshalb gibt ein laufender Upload selbst Lebenszeichen,
    /// solange Bytes fließen (`UploadProgressHeartbeat`, Review ME-02); ein hängender Upload tut es
    /// nicht. Im Hintergrund begrenzt ohnehin die Hintergrundzeit den Lauf. Der Wert ist eine Annahme
    /// und gehört am Gerät nachgemessen (Szenario "hängende Sperre").
    static let leaseDuration: TimeInterval = 150

    /// Wie lange ein abgebrochener Lauf den Slot noch halten darf, bevor der nächste ihn übernimmt.
    /// Die Regel von 0.15 (`cancelledSyncTakeoverDelay`), unverändert.
    static let cancelledTakeoverDelay: TimeInterval = 60

    enum Decision: Equatable {
        /// Der Slot ist frei.
        case grant
        /// Ein lebender Lauf hält ihn.
        case busy
        /// Der Slot gehörte einem Lauf, der ihn verloren hat. Der Grund steht im Journal:
        /// `leaseExpired` (Frist ohne Lebenszeichen) oder `cancelled` (abgebrochen, nie zurückgekehrt).
        case takeOver(String)
    }

    static func decide(isSyncing: Bool, cancelRequestedAt: Date?, leaseDeadline: Date?, now: Date) -> Decision {
        guard isSyncing else { return .grant }

        if let deadline = leaseDeadline, now > deadline {
            return .takeOver("leaseExpired")
        }
        if let requestedAt = cancelRequestedAt, now.timeIntervalSince(requestedAt) > cancelledTakeoverDelay {
            return .takeOver("cancelled")
        }
        return .busy
    }
}
