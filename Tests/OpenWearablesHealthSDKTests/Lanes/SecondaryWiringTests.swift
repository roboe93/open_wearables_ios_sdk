import XCTest
@testable import OpenWearablesHealthSDK

/// Das Zweitziel von außen (Plan 09-04, D-08): öffentliche Konfiguration, Schalter, Status, Journal,
/// die Auslöser Vordergrund und Netz, `clearSecondarySink` und `signOut`.
///
/// Jeder Test läuft in eigener Defaults-Suite (Schalter, Typauswahl), mit Zugangsdaten im Speicher
/// (`withIsolatedSDK`) und mit einer `StubURLProtocol`-Session für den Sender des Zweitziels.
final class SecondaryWiringTests: XCTestCase {

    private let secondaryHost = "https://secondary.example.test"
    private let secondaryKey = "secondary-key-123"
    private let heartRate = "HKQuantityTypeIdentifierHeartRate"

    // MARK: - Hilfen

    /// `signOut` setzt den Mirror-Dedupe-Ledger zurück. Ein eigener Ledger je Test hält den echten heraus.
    private final class LedgerStorage: MirrorDedupeStorage {
        var data: Data?
        func loadDedupeState() -> Data? { data }
        func saveDedupeState(_ data: Data?) { self.data = data }
    }

    private func withWiring(
        orchestration: SyncOrchestration = .lanes,
        _ body: (OpenWearablesHealthSDK) throws -> Void
    ) rethrows {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: orchestration) { sdk, _ in
                let previousSession = sdk.secondarySessionOverride
                let previousSyncActive = OpenWearablesHealthSdkKeychain.isSyncActive()
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubURLProtocol.self]
                sdk.secondarySessionOverride = URLSession(configuration: configuration)
                defer {
                    sdk.secondarySessionOverride = previousSession
                    OpenWearablesHealthSdkKeychain.setSyncActive(previousSyncActive)
                }
                try body(sdk)
            }
        }
    }

    /// Pakete, wie sie ein früherer Prozess hinterlassen hätte: eine eigene Outbox-Instanz über
    /// demselben Ordner.
    @discardableResult
    private func leaveFiles(_ sdk: OpenWearablesHealthSDK, _ bodies: [String]) throws -> [URL] {
        let outbox = SecondaryOutbox(baseDirectory: sdk.secondaryDirectory())
        return try bodies.map { try outbox.enqueue(Data($0.utf8)) }
    }

    private func secondaryRequests() -> [StubURLProtocol.Recorded] {
        StubURLProtocol.recorded.filter { $0.request.url?.host == "secondary.example.test" }
    }

    private func status(_ sdk: OpenWearablesHealthSDK) -> [String: Any] {
        sdk.getSyncStatus()
    }

    private func secondaryEntries(_ sdk: OpenWearablesHealthSDK) -> [SyncJournalEntry] {
        sdk.journalEntries().filter { $0.kind == "secondary" }
    }

    /// Wartet auf das Ergebnis eines direkten Anstoßes.
    private func drain(_ sdk: OpenWearablesHealthSDK, trigger: String = "test") -> SecondaryDrainResult?? {
        let lock = NSLock()
        var done = false
        var outcome: SecondaryDrainResult?
        sdk.drainSecondaryIfActive(trigger: trigger) { result in
            lock.lock()
            outcome = result
            done = true
            lock.unlock()
        }
        let finished = waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return done
        }
        guard finished else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return .some(outcome)
    }

    // MARK: - Standard und Konfiguration

    /// Frisches SDK: aus, nicht konfiguriert, nichts in der Warteschlange. Der Status legt nichts an.
    func testAFreshSdkHasTheSecondaryOffUnconfiguredAndEmpty() {
        withWiring { sdk in
            XCTAssertFalse(sdk.secondarySinkEnabled)
            XCTAssertEqual(sdk.secondarySinkTypes, [])

            let status = status(sdk)
            XCTAssertEqual(status["secondaryEnabled"] as? Bool, false)
            XCTAssertEqual(status["secondaryConfigured"] as? Bool, false)
            XCTAssertEqual(status["secondaryQueued"] as? Int, 0)
            XCTAssertEqual(status["secondaryDead"] as? Int, 0)
            XCTAssertEqual(status["secondaryGap"] as? Int, 0)
            XCTAssertTrue(status["secondaryLastSuccessAt"] is NSNull)
            XCTAssertTrue(status["secondaryLastError"] is NSNull)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sdk.secondaryDirectory().path))
        }
    }

    /// `configureSecondarySink` speichert nur die Zugangsdaten, im Keychain und nie in den Defaults.
    /// Eingeschaltet wird nichts. Ein ungültiger Host oder ein leerer Schlüssel ändern nichts.
    func testConfigureStoresTheCredentialsButDoesNotSwitchOn() {
        withWiring { sdk in
            sdk.configureSecondarySink(host: "kein host", apiKey: secondaryKey)
            sdk.configureSecondarySink(host: secondaryHost, apiKey: "   ")
            XCTAssertEqual(status(sdk)["secondaryConfigured"] as? Bool, false)
            XCTAssertNil(OpenWearablesHealthSdkKeychain.getSecondaryHost())

            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)

            let status = status(sdk)
            XCTAssertEqual(status["secondaryConfigured"] as? Bool, true)
            XCTAssertEqual(status["secondaryEnabled"] as? Bool, false, "nur konfiguriert, nicht eingeschaltet")
            XCTAssertFalse(sdk.secondarySinkEnabled)
            XCTAssertEqual(OpenWearablesHealthSdkKeychain.getSecondaryHost(), secondaryHost)
            XCTAssertEqual(OpenWearablesHealthSdkKeychain.getSecondaryApiKey(), secondaryKey)
            let stored = sdk.defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
            XCTAssertFalse(stored.contains(secondaryKey), "der Schlüssel liegt nie in den Defaults")
        }
    }

    /// Schalter und Typauswahl liegen in der Defaults-Suite des SDK unter den Schlüsseln aus dem Plan.
    func testTheSwitchAndTheTypeSelectionLiveUnderTheirKeys() {
        withWiring { sdk in
            sdk.secondarySinkEnabled = true
            sdk.secondarySinkTypes = [heartRate]

            XCTAssertEqual(sdk.defaults.object(forKey: "lanes.secondary.enabled") as? Bool, true)
            XCTAssertEqual(sdk.defaults.stringArray(forKey: "lanes.secondary.types"), [heartRate])
            XCTAssertEqual(status(sdk)["secondaryEnabled"] as? Bool, true)

            sdk.secondarySinkTypes = []
            XCTAssertNil(sdk.defaults.object(forKey: "lanes.secondary.types"), "leer heißt alle")
        }
    }

    // MARK: - Auslöser

    /// Neustart: Zwei Dateien aus einem früheren Prozess liegen in der Outbox. Der Vordergrund stößt
    /// den Sender an, beide gehen in Reihenfolge an den Zweit-Host, danach ist die Warteschlange leer.
    func testAfterARestartTheForegroundTriggerDeliversQueuedFilesInOrder() throws {
        try withWiring { sdk in
            try leaveFiles(sdk, [#"{"n":1}"#, #"{"n":2}"#])
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            sdk.secondarySinkEnabled = true
            OpenWearablesHealthSdkKeychain.setSyncActive(true)
            StubURLProtocol.install { _ in .status(202) }

            sdk.tryResumeAfterForeground()

            XCTAssertTrue(waitUntil { (self.status(sdk)["secondaryQueued"] as? Int) == 0 })
            let sent = secondaryRequests()
            XCTAssertEqual(sent.map { String(decoding: $0.body, as: UTF8.self) }, [#"{"n":1}"#, #"{"n":2}"#])
            XCTAssertEqual(sent.first?.request.url?.path, "/api/v1/sdk/users/test-user/sync")
            XCTAssertEqual(sent.first?.request.value(forHTTPHeaderField: "X-Open-Wearables-API-Key"), secondaryKey)
            XCTAssertNil(sent.first?.request.value(forHTTPHeaderField: "Authorization"), "kein Token des Primärziels")
            XCTAssertFalse(status(sdk)["secondaryLastSuccessAt"] is NSNull)
            XCTAssertTrue(status(sdk)["secondaryLastError"] is NSNull)
            XCTAssertTrue(waitUntil { self.secondaryEntries(sdk).last?.trigger == "foreground" })
        }
    }

    /// „Netz wieder da“ stößt den Sender ebenso an.
    func testTheNetworkTriggerAlsoDrains() throws {
        try withWiring { sdk in
            try leaveFiles(sdk, [#"{"n":1}"#])
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            sdk.secondarySinkEnabled = true
            StubURLProtocol.install { _ in .status(202) }

            sdk.tryResumeAfterNetworkRestored()

            XCTAssertTrue(waitUntil { (self.status(sdk)["secondaryQueued"] as? Int) == 0 })
            XCTAssertEqual(secondaryRequests().count, 1)
            XCTAssertTrue(waitUntil { self.secondaryEntries(sdk).last?.trigger == "network" })
        }
    }

    /// 401 vom Zweitziel: Der Status nennt den Code, die Datei bleibt. Anmeldung, Token und
    /// `onAuthError` des Primärziels bleiben unberührt, es gibt keinen Token-Refresh.
    func testA401FromTheSecondaryLeavesTheOutboxAndThePrimaryAuthAlone() throws {
        try withWiring { sdk in
            try leaveFiles(sdk, [#"{"n":1}"#])
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            sdk.secondarySinkEnabled = true
            var authErrors = 0
            sdk.onAuthError = { _, _ in authErrors += 1 }
            StubURLProtocol.install { _ in .status(401) }

            let result = drain(sdk)

            XCTAssertEqual(result??.paused, true)
            let status = status(sdk)
            XCTAssertTrue((status["secondaryLastError"] as? String)?.contains("401") == true, "\(status)")
            XCTAssertEqual(status["secondaryQueued"] as? Int, 1, "die Datei bleibt")
            XCTAssertEqual(OpenWearablesHealthSdkKeychain.getAccessToken(), "access-1")
            XCTAssertTrue(sdk.isSessionValid)
            XCTAssertEqual(authErrors, 0)
            XCTAssertEqual(StubURLProtocol.recorded.count, secondaryRequests().count, "kein Aufruf ans Primärziel")
        }
    }

    // MARK: - Journal

    /// Ein Durchlauf hinterlässt einen Eintrag der Art `secondary` mit Zahlen, ohne Host, Schlüssel,
    /// Nutzer oder Ladung.
    func testTheJournalHoldsASecondaryEntryWithNumbersOnly() throws {
        try withWiring { sdk in
            try leaveFiles(sdk, [#"{"marker":"NUTZLAST-XYZ"}"#, #"{"marker":"NUTZLAST-ABC"}"#])
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            sdk.secondarySinkEnabled = true
            let lock = NSLock()
            var calls = 0
            StubURLProtocol.install { _ in
                lock.lock()
                calls += 1
                let first = calls == 1
                lock.unlock()
                return first ? .status(202) : .status(503)
            }

            _ = drain(sdk, trigger: "cycle")

            let entry = try XCTUnwrap(secondaryEntries(sdk).last)
            XCTAssertEqual(entry.trigger, "cycle")
            let note = try XCTUnwrap(entry.note)
            XCTAssertTrue(note.contains("delivered=1"), note)
            XCTAssertTrue(note.contains("retried=1"), note)
            XCTAssertTrue(note.contains("queued=1"), note)
            XCTAssertTrue(note.contains("dead=0"), note)
            XCTAssertTrue(note.contains("paused=0"), note)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let text = String(decoding: try encoder.encode(entry), as: UTF8.self)
            for secret in ["secondary.example.test", secondaryKey, "test-user", "NUTZLAST"] {
                XCTAssertFalse(text.contains(secret), "\(secret) im Journal: \(text)")
            }
        }
    }

    /// Ein Anstoß ohne jede Wirkung (leere Outbox, nichts eingereiht) schreibt keinen Eintrag, damit
    /// der Ring (200) nicht mit leeren Durchläufen vollläuft.
    func testADrainWithNothingToDoWritesNoJournalEntry() {
        withWiring { sdk in
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            sdk.secondarySinkEnabled = true
            StubURLProtocol.install { _ in .status(202) }

            let result = drain(sdk)

            XCTAssertNotNil(result ?? nil)
            XCTAssertTrue(secondaryEntries(sdk).isEmpty)
            XCTAssertTrue(secondaryRequests().isEmpty)
        }
    }

    // MARK: - Ruhe

    /// Schalter aus: kein Anstoß, kein Zugriff auf den Ordner, auch mit konfiguriertem Ziel.
    func testWithTheSwitchOffADrainDoesNothing() {
        withWiring { sdk in
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            StubURLProtocol.install { _ in .status(202) }

            let result = drain(sdk)

            XCTAssertTrue(result != nil, "der Rückruf kommt")
            XCTAssertNil(result ?? nil, "nichts angestoßen")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sdk.secondaryDirectory().path))
            XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        }
    }

    /// Modus `upstream`: Das Zweitziel ruht, vorhandene Dateien bleiben liegen.
    func testInUpstreamModeTheSecondaryRestsAndKeepsItsFiles() throws {
        try withWiring(orchestration: .upstream) { sdk in
            try leaveFiles(sdk, [#"{"n":1}"#])
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            sdk.secondarySinkEnabled = true
            StubURLProtocol.install { _ in .status(202) }

            let result = drain(sdk)

            XCTAssertNil(result ?? nil, "nichts angestoßen")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty)
            XCTAssertEqual(status(sdk)["secondaryQueued"] as? Int, 1)
        }
    }

    // MARK: - Aufräumen

    /// `clearSecondarySink` schaltet aus und entfernt die Zugangsdaten. Die Dateien bleiben liegen
    /// (nichts still verwerfen) und werden weiter gezählt.
    func testClearSwitchesOffAndForgetsTheCredentialsButKeepsAndCountsTheFiles() throws {
        try withWiring { sdk in
            try leaveFiles(sdk, [#"{"n":1}"#, #"{"n":2}"#])
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            sdk.secondarySinkEnabled = true

            sdk.clearSecondarySink()

            XCTAssertFalse(sdk.secondarySinkEnabled)
            XCTAssertNil(OpenWearablesHealthSdkKeychain.getSecondaryHost())
            XCTAssertNil(OpenWearablesHealthSdkKeychain.getSecondaryApiKey())
            let status = status(sdk)
            XCTAssertEqual(status["secondaryEnabled"] as? Bool, false)
            XCTAssertEqual(status["secondaryConfigured"] as? Bool, false)
            XCTAssertEqual(status["secondaryQueued"] as? Int, 2, "die Dateien bleiben und zählen")
        }
    }

    /// `signOut` entfernt Zugangsdaten und Dateien des Zweitziels: sie gehören dem abgemeldeten Nutzer.
    func testSignOutRemovesTheCredentialsAndFilesOfTheSecondary() throws {
        try withWiring { sdk in
            let files = try leaveFiles(sdk, [#"{"n":1}"#, #"{"n":2}"#])
            let outbox = SecondaryOutbox(baseDirectory: sdk.secondaryDirectory())
            XCTAssertTrue(outbox.markDead(files[0]))
            sdk.configureSecondarySink(host: secondaryHost, apiKey: secondaryKey)
            StubURLProtocol.install { _ in .status(204) }
            let previousLedger = sdk.mirrorDedupe
            sdk.mirrorDedupe = MirrorDedupeLedger(storage: LedgerStorage())
            defer { sdk.mirrorDedupe = previousLedger }

            sdk.signOut()

            XCTAssertNil(OpenWearablesHealthSdkKeychain.getSecondaryHost())
            XCTAssertNil(OpenWearablesHealthSdkKeychain.getSecondaryApiKey())
            XCTAssertFalse(FileManager.default.fileExists(atPath: sdk.secondaryDirectory().path))
            XCTAssertEqual(status(sdk)["secondaryQueued"] as? Int, 0)
            XCTAssertEqual(status(sdk)["secondaryDead"] as? Int, 0)
        }
    }
}
