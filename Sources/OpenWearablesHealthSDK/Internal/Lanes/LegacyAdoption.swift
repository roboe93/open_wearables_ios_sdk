import Foundation

// Fork-Zusatz (roboe93), bewusst in einer eigenen Datei, damit künftige Upstream-Merges
// möglichst wenig Reibung haben.
//
// Warum es das gibt (Messung am iPhone 18 Pro, 04.10.2026): 0.14 und 0.15 werten
// `fullDone.<userKey>` aus, 0.13.2 las es in `collectAllData` nie. Am Gerät steht
// `fullDone.user.none = false` und **kein** `fullDone.user.<id>`, weil `signIn()` die
// Anchors zurücksetzt, bevor die Zugangsdaten gespeichert sind. Ohne Adoption begänne der
// erste Lauf nach dem Update einen Export über das ganze Fenster und alle Typen, mit neuer
// Sitzung, und die Hintergrundzustellung würde währenddessen verworfen.
//
// Die Adoption schreibt genau einen Boolean. Anchors, Ledger und Sitzungsdatei bleiben
// unberührt (Arbeitsregel "Bestehende Daten respektieren").

extension OpenWearablesHealthSDK {

    /// Macht aus Check-dann-Schreiben einen Schritt. Der Lock gilt nur für die
    /// Entscheidung, nicht für den Log: ein Log-Handler der App darf den Status lesen,
    /// ohne in diese Funktion zurückzukehren und sich selbst zu blockieren.
    private static let adoptionLock = NSLock()

    /// Entscheidung aus `collectAllData`, herausgezogen, damit sie ohne HealthKit prüfbar ist.
    ///
    /// - Ein offener Export bleibt Export.
    /// - Ein nie abgeschlossener Erst-Export erzwingt Export.
    /// - Sonst gilt, was der Aufrufer angefordert hat.
    internal static func effectiveFullExport(
        existingFullExport: Bool?,
        fullDone: Bool,
        requested: Bool
    ) -> Bool {
        if existingFullExport == true { return true }
        if !fullDone { return true }
        return requested
    }

    /// Einzige Lesestelle für "ist der Erst-Export abgeschlossen". Adoptiert zuerst einen
    /// Altzustand, damit auch ein Hintergrundstart ohne vorheriges `configure()` richtig liegt.
    internal func isInitialExportDone() -> Bool {
        adoptLegacyStateIfNeeded()
        return defaults.bool(forKey: fullDoneKey())
    }

    /// Markiert den Erst-Export als erledigt, wenn der Zustand eindeutig von einer Version
    /// stammt, die `fullDone` nicht auswertete. Idempotent.
    ///
    /// Bedingungen, in dieser Reihenfolge:
    /// 1. `fullDone.<userKey>` ist **nicht gesetzt**. Ein ausdrückliches `false` stammt aus
    ///    `signOut` und heißt: Neu-Export ist gewollt, es bleibt unangetastet.
    /// 2. Für diesen Nutzer gibt es mindestens einen Anchor. Ohne Anchors ist es eine
    ///    Neuinstallation, und dort ist der Erst-Export richtig.
    /// 3. Keine offene Sitzung mit `fullExport == true`. Ein laufender Export wird nicht
    ///    abgebrochen und nicht für beendet erklärt.
    /// 4. Es ist ein Nutzer angemeldet (`user.none` wird nie adoptiert).
    ///
    /// - Returns: `true`, wenn in diesem Aufruf adoptiert wurde.
    @discardableResult
    internal func adoptLegacyStateIfNeeded() -> Bool {
        let adoptedAnchorCount: Int? = {
            Self.adoptionLock.lock()
            defer { Self.adoptionLock.unlock() }

            let key = fullDoneKey()
            guard defaults.object(forKey: key) == nil else { return nil }

            let user = userKey()
            let anchors = anchorCount(forUserKey: user)
            guard anchors > 0 else { return nil }
            guard !hasOpenFullExport(forUserKey: user) else { return nil }
            guard user != "user.none" else { return nil }

            defaults.set(true, forKey: key)
            return anchors
        }()

        guard let count = adoptedAnchorCount else { return false }
        logMessage("Adopted legacy state: initial export marked done (\(count) anchors, no open export)")
        // Außerhalb des Locks: das Journal schreibt eine Datei und hat einen eigenen.
        runJournal.record(SyncJournalEntry(at: Date(), kind: JournalKind.adoption, note: "anchors=\(count)"))
        return true
    }

    /// Zahl der gespeicherten Anchors eines Nutzers. Der Punkt am Ende des Präfixes hält
    /// `user.1` und `user.10` auseinander.
    internal func anchorCount(forUserKey userKey: String) -> Int {
        let prefix = "anchor.\(userKey)."
        return defaults.dictionaryRepresentation().keys.reduce(0) { $1.hasPrefix(prefix) ? $0 + 1 : $0 }
    }

    /// Liest die Sitzungsdatei **ohne Nebenwirkung**. `loadSyncState()` räumt die Sitzung
    /// eines anderen Nutzers ab; die Adoption soll aber nichts außer einem Boolean
    /// verändern. Eine Datei, die sich nicht lesen lässt, zählt nicht als offener Export,
    /// wie bei `loadSyncState()`.
    private func hasOpenFullExport(forUserKey userKey: String) -> Bool {
        guard let data = try? Data(contentsOf: syncStateFilePath()),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return false
        }
        return state.userKey == userKey && state.fullExport
    }
}
