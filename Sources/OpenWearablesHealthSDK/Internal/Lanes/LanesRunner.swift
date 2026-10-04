import Foundation
import HealthKit

// Fork-Zusatz (roboe93), Plan 05-08. Die Weiche und der Läufer der Zwei-Spuren-Steuerung.
//
// Warum es das gibt (Messung am iPhone 18 Pro, 02./03.10.2026): Der Kern (`SyncCore`, 05-06) und
// seine Adapter (`HealthKitReader`, `PayloadSink`, 05-07) sind mit Fakes belegt, laufen aber nur,
// wenn sie jemand aufruft. Hier hängen sie an dem einen Sammelpunkt aller Auslöser, und ein
// Schalter wählt je Aufruf zwischen ihnen und dem Ablauf des Originals 0.15 (D-13, SYNC-13).
//
// Der Schalter liegt in der Defaults-Suite des SDK (`lanes.orchestration`), nicht in der App:
// ein Kaltstart durch HealthKit liest ihn, bevor die App irgendetwas konfiguriert hat. Gelesen
// wird bei jedem Aufruf, ein Wechsel wirkt also mit dem nächsten Auslöser, ohne neuen Build.
//
// Der Ablauf des Originals bleibt unverändert (`collectAllDataUpstream`). Im Modus lanes wird
// `state.json` nie angelegt: der Rückweg findet "kein offener Export" und läuft inkrementell
// wie zuvor (Pattern 9).

// MARK: - Schalter

extension OpenWearablesHealthSDK {

    /// Welcher Ablauf die Läufe steuert. Standard `lanes` (Entscheidung vom 04.10.2026): der
    /// Nachweis läuft nur damit, `upstream` ist der Rückweg und bleibt per Diagnose wählbar.
    /// Ein fehlender oder unbekannter Wert gilt als `lanes`.
    ///
    /// Das Setzen bricht einen laufenden Lauf ab (`cancelSync()`), damit kein halber Lauf im alten
    /// Modus weiterschreibt: der Generationsvergleich sperrt ihn aus (T-05-29). Der Wechsel steht
    /// im Journal (`switch`). Wird derselbe Wert noch einmal gesetzt, geschieht nichts außer dem
    /// Schreiben des Schlüssels.
    public var orchestration: SyncOrchestration {
        get {
            switch defaults.string(forKey: "lanes.orchestration") {
            case "upstream": return .upstream
            default: return .lanes
            }
        }
        set {
            let previous = orchestration
            defaults.set(newValue.rawValue, forKey: "lanes.orchestration")
            guard previous != newValue else { return }
            logMessage("Orchestration switched: \(previous.rawValue) -> \(newValue.rawValue)")
            cancelSync()
            runJournal.record(SyncJournalEntry(
                at: Date(),
                kind: "switch",
                orchestration: newValue.rawValue,
                note: "\(previous.rawValue)→\(newValue.rawValue)"
            ))
        }
    }

    /// Die einzige Weiche. Jeder Auslöser (App, Observer, SDK-BGTasks, Entsperren, Vordergrund,
    /// Netz, Wiederherstellung, Erst-Start) landet hier und bekommt ein `SyncOutcome`, in
    /// beiden Modi. Die Signatur ist die des Rumpfs aus 0.15, der unverändert in
    /// `collectAllDataUpstream` weiterlebt.
    internal func collectAllData(
        fullExport: Bool,
        isBackground: Bool,
        trigger: SyncTrigger,
        deadline: Date?,
        completion: @escaping (SyncOutcome) -> Void
    ) {
        switch orchestration {
        case .upstream:
            collectAllDataUpstream(
                fullExport: fullExport, isBackground: isBackground,
                trigger: trigger, deadline: deadline, completion: completion
            )
        case .lanes:
            // `fullExport` hat im Modus lanes keine eigene Bedeutung (etwa aus `resetAnchors`):
            // zurückgesetzte Typen haben keinen Anchor und laufen über Bootstrap und Nachholen.
            runLanesCycle(trigger: trigger, isBackground: isBackground, deadline: deadline, completion: completion)
        }
    }
}

// MARK: - Register des laufenden Zyklus

/// Der laufende Zyklus, soweit andere Auslöser ihn brauchen: seine Generation und die Möglichkeit,
/// eine Live-Runde anzufordern. `requestLiveRound` liefert `false`, wenn der Kern nicht mehr läuft
/// (der Zyklus endet gerade).
internal final class ActiveLanesCycle {
    let generation: Int
    let requestLiveRound: (@escaping (CycleResult) -> Void) -> Bool

    init(generation: Int, requestLiveRound: @escaping (@escaping (CycleResult) -> Void) -> Bool) {
        self.generation = generation
        self.requestLiveRound = requestLiveRound
    }
}

/// Ein Auslöser, der eintraf, während der Zyklus endete (Kern fertig, Slot noch belegt). Er wird
/// nach dem Ende als eigener Zyklus gestartet, nie verworfen.
internal struct DeferredLanesTrigger {
    let trigger: SyncTrigger
    let isBackground: Bool
    let deadline: Date?
    let completion: (SyncOutcome) -> Void
}

extension OpenWearablesHealthSDK {

    internal func registerActiveLanesCycle(_ cycle: ActiveLanesCycle) {
        lanesCycleLock.lock()
        activeLanesCycle = cycle
        lanesCycleLock.unlock()
    }

    /// Nimmt den Zyklus aus dem Register, wenn er noch der eingetragene ist, und gibt die
    /// vorgemerkten Auslöser zurück. Ein Zyklus, den ein neuerer ersetzt hat (Frist, Übernahme),
    /// lässt das Register und die Vormerkung des neuen in Ruhe.
    internal func releaseActiveLanesCycle(generation: Int) -> [DeferredLanesTrigger] {
        lanesCycleLock.lock()
        defer { lanesCycleLock.unlock() }
        guard activeLanesCycle?.generation == generation else { return [] }
        activeLanesCycle = nil
        let deferred = deferredLanesTriggers
        deferredLanesTriggers = []
        return deferred
    }

    /// Startet vorgemerkte Auslöser neu, hinter dem Ende des Zyklus auf der Hauptschlange. Der
    /// erste beginnt einen Zyklus, die weiteren fordern eine Live-Runde an.
    internal func runDeferredLanesTriggers(_ deferred: [DeferredLanesTrigger]) {
        for item in deferred {
            DispatchQueue.main.async { [self] in
                runLanesCycle(
                    trigger: item.trigger, isBackground: item.isBackground,
                    deadline: item.deadline, completion: item.completion
                )
            }
        }
    }

    /// Fordert bei einem laufenden, lebenden Zyklus eine Live-Runde an. `true`: der Auslöser ist
    /// versorgt (die Antwort kommt mit der Runde oder die Vormerkung nach dem Ende). `false`:
    /// kein Zyklus läuft, der Aufrufer beginnt einen.
    private func handOverToRunningCycle(
        trigger: SyncTrigger, isBackground: Bool, deadline: Date?,
        started: Date, protectedStart: Bool?,
        completion: @escaping (SyncOutcome) -> Void
    ) -> Bool {
        lanesCycleLock.lock()
        defer { lanesCycleLock.unlock() }
        guard let active = activeLanesCycle,
              !isSyncCancelled(generation: active.generation),
              currentLeaseDecision() == .busy else { return false }

        let accepted = active.requestLiveRound { [self] result in
            // Die Antwort auf diese Runde. Die Ereignisse stehen im Journal des Zyklus, nicht hier.
            updateLanesNeedsCatchUp(with: result)
            let outcome = lanesOutcome(from: result, trigger: trigger, started: started, leaseTakenOver: false)
            deliverRun(outcome, protectedStart: protectedStart, completion: completion)
        }
        if !accepted {
            // Der Kern läuft nicht mehr, der Slot ist aber noch nicht frei: nach dem Ende neu starten.
            deferredLanesTriggers.append(DeferredLanesTrigger(
                trigger: trigger, isBackground: isBackground, deadline: deadline, completion: completion
            ))
        }
        return true
    }
}

// MARK: - Ein Zyklus

extension OpenWearablesHealthSDK {

    /// Ein Zyklus der Zwei-Spuren-Steuerung für einen Auslöser.
    ///
    /// 1. Läuft schon ein Zyklus mit gültiger Generation und lebender Sperre, wartet der Auslöser
    ///    auf dessen nächste Live-Runde (Pattern 1). Er wird weder verworfen noch als
    ///    `skippedBusy` gemeldet.
    /// 2. Sonst wird der Slot genommen. Hält ihn ein anderer Lauf, ist das `skippedBusy`.
    /// 3. Ein offener Zustand des Original-Ablaufs wird übernommen und `state.json` umbenannt.
    /// 4. Der Kern läuft: Bootstrap, Live-Spur, Nachholen.
    /// 5. Ergebnis: persistierter Nachholbedarf, Journal, `onRunCompleted` und Completion auf der
    ///    Hauptschlange.
    internal func runLanesCycle(
        trigger: SyncTrigger,
        isBackground: Bool,
        deadline: Date?,
        completion: @escaping (SyncOutcome) -> Void
    ) {
        let started = Date()
        let protectedStart = protectedDataAvailableCache

        if handOverToRunningCycle(
            trigger: trigger, isBackground: isBackground, deadline: deadline,
            started: started, protectedStart: protectedStart, completion: completion
        ) {
            return
        }

        guard let generation = beginSyncRun() else {
            logMessage("Sync in progress, skipping")
            deliverRun(
                SyncOutcome(
                    status: .skippedBusy, orchestration: .lanes,
                    trigger: trigger, started: started, finished: Date()
                ),
                protectedStart: protectedStart,
                completion: completion
            )
            return
        }
        let leaseTakenOver = { [self] in runStats(for: generation)?.snapshot().leaseTakenOver ?? false }

        /// Ein Lauf, der endet, bevor der Kern beginnt (keine Anmeldung, nichts abzufragen).
        func concludeWithoutCycle(_ status: SyncOutcome.Status) {
            let outcome = SyncOutcome(
                status: status, leaseTakenOver: leaseTakenOver(), orchestration: .lanes,
                trigger: trigger, started: started, finished: Date()
            )
            finishSync(generation: generation)
            deliverRun(outcome, protectedStart: protectedStart, completion: completion)
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            logMessage("HealthKit not available")
            concludeWithoutCycle(.failed("healthkit unavailable"))
            return
        }
        guard let credential = authCredential, let endpoint = syncEndpoint else {
            logMessage("No auth credential or endpoint")
            concludeWithoutCycle(.failed("no auth"))
            return
        }
        let typeIds = getQueryableTypes().map { $0.identifier }
        guard !typeIds.isEmpty else {
            logMessage("No queryable types")
            concludeWithoutCycle(.upToDate)
            return
        }
        logMessage("Lanes cycle (\(typeIds.count) types, trigger \(trigger.journalValue))")

        // Bausteine je Zyklus: der Leser und der Sender tragen die Generation des Laufs, damit
        // ein Lauf, der seinen Slot verloren hat, nichts mehr festschreibt.
        let reader = HealthKitReader(sdk: self, generation: generation)
        let cursors = makeCursorStore()
        let backfill = makeBackfillStore()
        let deletions = makeDeletionQueue()
        let sink = PayloadSink(
            sdk: self, endpoint: endpoint, credential: credential, generation: generation,
            deletions: deletions, backfill: backfill
        )
        let core = SyncCore(
            reader: reader, sink: sink, cursors: cursors, backfill: backfill,
            deletions: deletions, parking: makeRejectionParking(),
            clock: SystemLaneClock(), ordering: LaneOrdering()
        )
        registerActiveLanesCycle(ActiveLanesCycle(generation: generation) { waiter in
            core.requestLiveRound(waiter)
        })

        // Ein gesperrtes iPhone ist nie im Vordergrund: dann gilt das kleine Hintergrund-Chunk,
        // ohne `UIApplication` zu fragen. Bei unbekanntem Zustand entscheidet `currentChunkLimit`.
        let locked = protectedDataAvailableCache == false
        let context = CycleContext(
            typeIds: typeIds,
            daysBack: lanesDaysBack(),
            chunkLimit: currentChunkLimit(declaredBackground: isBackground || locked),
            deadline: deadline,
            isCancelled: { [weak self] in self?.isSyncCancelled(generation: generation) ?? true },
            heartbeat: { [weak self] in self?.heartbeat(generation: generation) },
            // Unbekannt gilt als lesbar: dann entscheidet der Abfragefehler (Pattern 7).
            isProtectedDataAvailable: { [weak self] in self?.protectedDataAvailableCache ?? true }
        )

        let runCore = { [self] in
            core.runCycle(context) { [self] result in
                finishLanesCycle(
                    generation: generation, result: result, trigger: trigger, started: started,
                    protectedStart: protectedStart, leaseTakenOver: leaseTakenOver(), completion: completion
                )
            }
        }

        // Gesperrt wartet die Übernahme: ohne HealthKit gibt es keinen Anchor für jetzt.
        guard !locked else {
            runCore()
            return
        }
        adoptOpenUpstreamStateIfNeeded(
            reader: reader, cursors: cursors, backfill: backfill, typeIds: typeIds
        ) { _ in
            runCore()
        }
    }

    /// Ende eines Zyklus (auf der Queue des Kerns): Nachholbedarf festhalten, Slot freigeben,
    /// Journal, Ergebnis an die App, vorgemerkte Auslöser starten.
    private func finishLanesCycle(
        generation: Int,
        result: CycleResult,
        trigger: SyncTrigger,
        started: Date,
        protectedStart: Bool?,
        leaseTakenOver: Bool,
        completion: @escaping (SyncOutcome) -> Void
    ) {
        updateLanesNeedsCatchUp(with: result)
        finishSync(generation: generation)
        let deferred = releaseActiveLanesCycle(generation: generation)

        let grouped = LaneEventSummary.group(result.events)
        journalLaneEvents(grouped)
        let outcome = lanesOutcome(from: result, trigger: trigger, started: started, leaseTakenOver: leaseTakenOver)
        deliverRun(
            outcome, protectedStart: protectedStart,
            note: LaneEventSummary.note(grouped.other, shorten: { shortTypeName($0) }),
            completion: completion
        )
        runDeferredLanesTriggers(deferred)
    }

    /// Das Ergebnis eines Zyklus (oder einer Live-Runde darin) als `SyncOutcome`.
    internal func lanesOutcome(
        from result: CycleResult, trigger: SyncTrigger, started: Date, leaseTakenOver: Bool
    ) -> SyncOutcome {
        SyncOutcome(
            status: result.status,
            records: result.records,
            perType: result.perType,
            liveRecords: result.liveRecords,
            backfillRecords: result.backfillRecords,
            deletionsQueued: result.deletionsQueued,
            backfillPending: result.backfillPending,
            leaseTakenOver: leaseTakenOver,
            orchestration: .lanes,
            trigger: trigger,
            started: started,
            finished: Date()
        )
    }

    /// Hält fest, ob nach dem Entsperren nachgeholt werden muss. Gesperrt setzt das Flag. Gelöscht
    /// wird es nur von einem Lauf, der sauber endete: ein Fehlschlag oder eine Frist hat nicht
    /// nachgeholt, was die Sperre liegen ließ, und ein übersprungener Lauf hat nichts getan.
    /// Das Flag zu behalten kostet höchstens einen Zyklus ohne Neues.
    internal func updateLanesNeedsCatchUp(with result: CycleResult) {
        if result.needsCatchUp {
            lanesNeedsCatchUp = true
            return
        }
        switch result.status {
        case .transferred, .upToDate:
            lanesNeedsCatchUp = false
        default:
            break
        }
    }

    /// Das gespeicherte Sync-Fenster in Tagen. Nicht gesetzt (0 heißt im Original: ohne Grenze)
    /// gilt 14, wie in `prepareSyncWindow` der App: ein Nachholen ohne Grenze wäre ein Neu-Export.
    internal func lanesDaysBack() -> Int {
        let stored = OpenWearablesHealthSdkKeychain.getSyncDaysBack()
        return stored > 0 ? stored : 14
    }

    /// Ob ein Auslöser (Entsperren, Vordergrund, Netz, Wiederherstellung) einen Zyklus starten soll:
    /// ein Nachholbedarf ist offen, ein Nachholen läuft, oder eine Sitzung des Original-Ablaufs
    /// wartet auf ihre Übernahme.
    internal func lanesHasWorkToResume() -> Bool {
        if lanesNeedsCatchUp { return true }
        if lanesBackfillPendingTypeCount(trackedOnly: true) > 0 { return true }
        return FileManager.default.fileExists(atPath: syncStateFilePath().path)
    }

    /// Anzahl der Typen mit offenem Nachholen. `trackedOnly`: ein Typ, den die Verfolgung nicht mehr
    /// kennt, hält nichts offen (der Kern zählt ihn auch nicht).
    internal func lanesBackfillPendingTypeCount(trackedOnly: Bool = false) -> Int {
        let tracked = Set(getQueryableTypes().map { $0.identifier })
        return makeBackfillStore().load().entries.filter {
            $0.value.state == .pending && (!trackedOnly || tracked.contains($0.key))
        }.count
    }
}

// MARK: - Journal der Kern-Ereignisse

/// Die Ereignisse eines Zyklus, in Gruppen für das Journal.
///
/// Ein Eintrag je Ereignis ließe den Ring (200) volllaufen: ein erster Zyklus bootstrappt über 40
/// Typen. Darum ein Eintrag je Gruppe und Zyklus, mit Kurznamen und Obergrenze. Die Ereignisse
/// enthalten nur HK-Identifier und Zahlen, nie Werte.
enum LaneEventSummary {

    static let nameLimit = 12

    private static let backfillPrefixes = ["bootstrap:", "bootstrapFailed:", "noAnchor:", "backfillReadFailed:", "noProgress:"]
    private static let rejectedPrefixes = ["split:", "halve:", "hold:", "parked:", "parkFailed:"]

    static func group(_ events: [String]) -> (backfill: [String], rejected: [String], other: [String]) {
        var backfill: [String] = []
        var rejected: [String] = []
        var other: [String] = []
        for event in events {
            if backfillPrefixes.contains(where: { event.hasPrefix($0) }) {
                backfill.append(event)
            } else if rejectedPrefixes.contains(where: { event.hasPrefix($0) }) {
                rejected.append(event)
            } else {
                other.append(event)
            }
        }
        return (backfill, rejected, other)
    }

    /// Die ersten `limit` Ereignisse als Kurznamen, durch Leerzeichen getrennt, der Rest als `+n`.
    /// `nil` ohne Ereignisse.
    static func note(_ events: [String], limit: Int = nameLimit, shorten: (String) -> String) -> String? {
        guard !events.isEmpty else { return nil }
        var parts = events.prefix(limit).map(shorten)
        if events.count > limit { parts.append("+\(events.count - limit)") }
        return parts.joined(separator: " ")
    }
}

extension OpenWearablesHealthSDK {

    /// Schreibt die Gruppen `backfill` und `rejected` des Zyklus, je höchstens einen Eintrag.
    internal func journalLaneEvents(_ grouped: (backfill: [String], rejected: [String], other: [String])) {
        let now = Date()
        if let note = LaneEventSummary.note(grouped.backfill, shorten: { shortTypeName($0) }) {
            runJournal.record(SyncJournalEntry(at: now, kind: "backfill", orchestration: "lanes", note: note))
        }
        if let note = LaneEventSummary.note(grouped.rejected, shorten: { shortTypeName($0) }) {
            runJournal.record(SyncJournalEntry(at: now, kind: "rejected", orchestration: "lanes", note: note))
        }
    }
}

// MARK: - Übernahme offener Upstream-Zustände

/// Was die Übernahme getan hat. Nur Typnamen und Zahlen, nie Werte.
internal struct UpstreamAdoption: Equatable {
    /// Es gab eine lesbare `state.json` dieses Nutzers.
    var adopted = false
    var fullExport = false
    /// Neu angelegte Nachhol-Einträge.
    var plannedTypes: [String] = []
    /// Anchors, die aus dem bestätigten Fortschritt einer inkrementellen Sitzung kamen.
    var anchorsFromSession: [String] = []
    /// Anchors "für jetzt", die ein Typ des offenen Exports noch nicht hatte.
    var anchorsForNow: [String] = []
    /// Typen, für die der Anchor nicht zu bekommen war (gesperrt, Lesefehler).
    var anchorFailed: [String] = []
    /// Neuer Name der Sitzungsdatei. `nil`: sie liegt noch da und wird beim nächsten Zyklus erneut
    /// übernommen.
    var renamedTo: String?
}

extension OpenWearablesHealthSDK {

    /// `state.json.adopted-<yyyyMMdd-HHmmss>` in UTC.
    internal static func adoptedStateFileName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "state.json.adopted-" + formatter.string(from: now)
    }

    /// Übernimmt eine offene Sitzung des Original-Ablaufs, wenn der Zyklus im Modus lanes beginnt
    /// (Wechsel `upstream → lanes`, T-05-30). Nichts wird gelöscht, nichts abgebrochen.
    ///
    /// - Offener Export (`fullExport`): jeder nicht fertige Typ wird ein Nachhol-Eintrag mit
    ///   `covered` am Cursor des Exports (`BackfillPlan.adoptOpenExport`). Typen des Exports ohne
    ///   Anchor bekommen den Anchor für jetzt (der Kern bootstrappt sie nicht, siehe 05-06:
    ///   `noAnchor`), sonst bliebe ihre Live-Spur für immer aus.
    /// - Offene inkrementelle Sitzung: der bestätigte Fortschritt (`pendingAnchorData`, nur nach 2xx
    ///   geschrieben) wird der Anchor des Typs, genau wie das Original ihn beim Abschluss des Typs
    ///   festschriebe.
    ///
    /// Die Reihenfolge ist Plan, dann Anchors, zuletzt das Umbenennen von `state.json`: scheitert
    /// ein Schritt (gesperrt, Platte), bleibt die Datei liegen und die nächste Übernahme macht
    /// fertig. Jeder Schritt ist idempotent, ein vorhandener Fortschritt wird nie überschrieben.
    ///
    /// Die Sitzungsdatei wird nicht über `loadSyncState()` gelesen: es räumt die Sitzung eines
    /// anderen Nutzers ab. Hier wird nichts gelöscht. Eine Datei, die sich nicht lesen lässt oder
    /// einem anderen Nutzer gehört, bleibt, wo sie ist.
    internal func adoptOpenUpstreamStateIfNeeded<Reader: HealthReading>(
        reader: Reader,
        cursors: CursorStore,
        backfill: BackfillStoring,
        typeIds: [String],
        now: Date = Date(),
        completion: @escaping (UpstreamAdoption) -> Void
    ) {
        guard case .data(let data) = LaneFiles.read(syncStateFilePath()),
              let state = try? JSONDecoder().decode(SyncState.self, from: data),
              state.userKey == userKey() else {
            completion(UpstreamAdoption())
            return
        }

        var result = UpstreamAdoption(adopted: true, fullExport: state.fullExport)

        /// Letzter Schritt: umbenennen, wenn alles Nötige festgeschrieben ist, dann melden.
        func finalize() {
            if result.anchorFailed.isEmpty {
                result.renamedTo = moveAdoptedStateFile(now: now)
            }
            journalAdoption(result)
            completion(result)
        }

        guard state.fullExport else {
            for (typeId, progress) in state.typeProgress.sorted(by: { $0.key < $1.key }) where !progress.isComplete {
                guard let anchorData = progress.pendingAnchorData else { continue }
                // Wie im Original: ein Anchor, der sich nicht entpacken lässt, wird nicht übernommen.
                guard (try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchorData)) != nil else {
                    logMessage("Adoption: confirmed anchor of \(shortTypeName(typeId)) cannot be read - not taken over")
                    continue
                }
                cursors.commit(anchorData, for: typeId)
                result.anchorsFromSession.append(typeId)
            }
            finalize()
            return
        }

        // Offener Export: Nachholplan zuerst.
        var plan = backfill.load()
        let original = plan
        let completed = state.completedTypes.union(state.typeProgress.values.filter { $0.isComplete }.map { $0.typeIdentifier })
        var olderThan: [String: Date] = [:]
        for (typeId, progress) in state.typeProgress where !progress.isComplete {
            if let cursor = progress.pendingOlderThan { olderThan[typeId] = cursor }
        }
        plan.adoptOpenExport(
            completedTypes: completed,
            olderThanCursors: olderThan,
            floor: syncStartDate() ?? now.addingTimeInterval(-Double(lanesDaysBack()) * 86_400),
            now: now,
            typeIds: typeIds
        )
        result.plannedTypes = Set(plan.entries.keys).subtracting(original.entries.keys).sorted()
        if plan != original {
            do {
                try backfill.save(plan)
            } catch {
                // Ohne Plan kein Anchor: ein Anchor ohne Plan ließe die Historie des Typs ungeholt.
                logMessage("Adoption: backfill plan could not be saved - session stays, nothing taken over")
                result.plannedTypes = []
                journalAdoption(result)
                completion(result)
                return
            }
        }

        let needAnchor = typeIds.filter { typeId in
            guard let entry = plan.entries[typeId], entry.state == .pending, entry.origin == "adoptedExport" else { return false }
            return cursors.anchor(for: typeId) == nil
        }

        func takeAnchors(index: Int) {
            guard index < needAnchor.count else {
                finalize()
                return
            }
            let typeId = needAnchor[index]
            reader.currentAnchor(typeId: typeId) { outcome in
                switch outcome {
                case .success(let anchor):
                    cursors.commit(anchor, for: typeId)
                    result.anchorsForNow.append(typeId)
                    takeAnchors(index: index + 1)
                case .failure:
                    // Gesperrt oder ein Lesefehler: dieser Typ bleibt offen, die Datei liegen. Die
                    // übrigen Typen werden trotzdem versucht (ein gesperrtes iPhone antwortet sofort),
                    // damit die nächste Übernahme nur noch den Rest braucht.
                    result.anchorFailed.append(typeId)
                    takeAnchors(index: index + 1)
                }
            }
        }
        takeAnchors(index: 0)
    }

    /// Benennt `state.json` in `state.json.adopted-<Zeitstempel>` um. Ein vorhandener Name wird nie
    /// überschrieben (zweite Übernahme in derselben Sekunde): es kommt ein Zähler dazu. `nil`, wenn
    /// das Umbenennen scheitert, die Datei bleibt dann liegen.
    private func moveAdoptedStateFile(now: Date) -> String? {
        let source = syncStateFilePath()
        let folder = source.deletingLastPathComponent()
        let base = Self.adoptedStateFileName(now: now)
        var target = folder.appendingPathComponent(base)
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            counter += 1
            target = folder.appendingPathComponent("\(base)-\(counter)")
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
            return target.lastPathComponent
        } catch {
            logMessage("Adoption: state file could not be renamed - it stays and is taken over again next cycle")
            return nil
        }
    }

    private func journalAdoption(_ result: UpstreamAdoption) {
        var note = "upstream fullExport=\(result.fullExport) planned=\(result.plannedTypes.count)"
        note += " anchors=\(result.anchorsFromSession.count + result.anchorsForNow.count)"
        note += " failed=\(result.anchorFailed.count) renamed=\(result.renamedTo != nil ? "yes" : "no")"
        runJournal.record(SyncJournalEntry(at: Date(), kind: JournalKind.adoption, orchestration: "lanes", note: note))
        logMessage("Adopted open upstream session (\(note))")
    }
}
