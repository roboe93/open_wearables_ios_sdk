import XCTest
@testable import OpenWearablesHealthSDK

/// Das Zweitziel (Plan 09-03, D-08): eigene Datei-Outbox, Wiederholungspolitik und Sender. In den
/// Upload-Pfad eingehängt wird es erst in 09-04; hier läuft alles gegen einen temporären Ordner,
/// eine Hand-Uhr und `StubURLProtocol` in einer eigenen Session.
final class SecondarySinkTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let target = SecondaryTarget(
        host: URL(string: "https://secondary.example.test")!, apiKey: "secondary-key", userId: "user-2"
    )

    private var root: URL!
    private var base: URL { root.appendingPathComponent("health_secondary", isDirectory: true) }

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-secondary-\(UUID().uuidString)", isDirectory: true)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Hilfen

    private func makeOutbox(
        clock: LaneClock,
        maxBytes: Int = SecondaryOutbox.defaultMaxBytes,
        maxAge: TimeInterval = SecondaryOutbox.defaultMaxAge,
        log: @escaping (String) -> Void = { _ in }
    ) -> SecondaryOutbox {
        SecondaryOutbox(baseDirectory: base, clock: clock, log: log, maxBytes: maxBytes, maxAge: maxAge)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeUploader(
        _ outbox: SecondaryOutbox, clock: LaneClock, log: @escaping (String) -> Void = { _ in }
    ) -> SecondaryUploader {
        SecondaryUploader(outbox: outbox, session: stubSession(), clock: clock, log: log)
    }

    private func body(_ text: String) -> Data { Data(text.utf8) }

    private func contents(_ urls: [URL]) -> [String] {
        urls.map { String(decoding: (try? Data(contentsOf: $0)) ?? Data(), as: UTF8.self) }
    }

    /// Wartet auf das Ergebnis eines Durchlaufs. Der Sender antwortet auf der Queue der Session.
    private func drain(_ uploader: SecondaryUploader) -> SecondaryDrainResult? {
        let lock = NSLock()
        var outcome: SecondaryDrainResult?
        uploader.drain(target: target) { result in
            lock.lock()
            outcome = result
            lock.unlock()
        }
        waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return outcome != nil
        }
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    private func sentBodies() -> [String] {
        StubURLProtocol.recorded.map { String(decoding: $0.body, as: UTF8.self) }
    }

    // MARK: - Outbox

    /// Ein Paket liegt danach als eigene Datei in `health_secondary/outbox/`, ohne Reste eines
    /// halb geschriebenen Zwischenstands.
    func testEnqueueWritesTheFileIntoTheOutboxFolder() throws {
        let outbox = makeOutbox(clock: ManualClock(start))

        let url = try outbox.enqueue(body("eins"))

        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL.path,
            base.appendingPathComponent("outbox", isDirectory: true).standardizedFileURL.path
        )
        XCTAssertEqual(contents([url]), ["eins"])
        let names = try FileManager.default.contentsOfDirectory(atPath: outbox.outboxDirectory.path)
        XCTAssertEqual(names, [url.lastPathComponent], "kein Zwischenstand bleibt liegen")
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".json"))
    }

    /// Die Reihenfolge ist die des Einreihens, auch wenn die Uhr zwischen zwei Paketen stillsteht.
    func testPendingIsFirstInFirstOutEvenWithinTheSameMillisecond() throws {
        let outbox = makeOutbox(clock: ManualClock(start))

        for text in ["1", "2", "3", "4", "5"] {
            try outbox.enqueue(body(text))
        }

        XCTAssertEqual(contents(outbox.pending()), ["1", "2", "3", "4", "5"])
    }

    /// Ein Neustart (neue Instanz über demselben Ordner) findet die Dateien und ihre Reihenfolge
    /// wieder, und ein neues Paket reiht sich hinten ein.
    func testFilesSurviveARestart() throws {
        let clock = ManualClock(start)
        let before = makeOutbox(clock: clock)
        try before.enqueue(body("1"))
        try before.enqueue(body("2"))

        let after = makeOutbox(clock: ManualClock(start))
        try after.enqueue(body("3"))

        XCTAssertEqual(contents(after.pending()), ["1", "2", "3"])
        XCTAssertEqual(after.counts().queued, 3)
        XCTAssertEqual(after.counts().bytes, 3)
    }

    /// Älter als der Deckel: nach `dead/`, gezählt, nichts gelöscht.
    func testFilesPastTheMaximumAgeMoveToDeadAndCountAsGap() throws {
        let clock = ManualClock(start)
        let outbox = makeOutbox(clock: clock)
        try outbox.enqueue(body("alt"))

        clock.advance(31 * 24 * 3600)
        try outbox.enqueue(body("neu"))

        XCTAssertEqual(contents(outbox.pending()), ["neu"])
        XCTAssertEqual(outbox.counts().dead, 1)
        XCTAssertEqual(contents(outbox.deadFiles()), ["alt"], "das Paket liegt in dead/, nicht gelöscht")
        XCTAssertEqual(outbox.gapCount, 1)
        XCTAssertEqual(outbox.lastGapAt, clock.now())
    }

    /// Über dem Größendeckel wandern die ältesten nach `dead/`, bis die Outbox wieder darunter ist.
    /// Der Zähler übersteht einen Neustart.
    func testOverflowBySizeMovesTheOldestToDeadAndNeverDeletes() throws {
        let clock = ManualClock(start)
        let outbox = makeOutbox(clock: clock, maxBytes: 10)

        try outbox.enqueue(body("aaaa"))
        try outbox.enqueue(body("bbbb"))
        XCTAssertEqual(outbox.gapCount, 0)
        try outbox.enqueue(body("cccc"))

        XCTAssertEqual(contents(outbox.pending()), ["bbbb", "cccc"])
        XCTAssertEqual(contents(outbox.deadFiles()), ["aaaa"])
        XCTAssertEqual(outbox.counts().bytes, 8)

        let restarted = makeOutbox(clock: clock, maxBytes: 10)
        XCTAssertEqual(restarted.gapCount, 1)
        XCTAssertEqual(restarted.lastGapAt, clock.now())
    }

    // MARK: - Wiederholungspolitik

    func testPolicyDeliversOnSuccess() {
        var policy = SecondaryPolicy()
        XCTAssertEqual(policy.decide(status: 202, error: false, now: start), .delivered)
        XCTAssertEqual(policy.state, SecondaryFileState())
    }

    /// 5xx, 429 und Netzfehler: 1, 2, 4 … Minuten, höchstens eine Stunde.
    func testPolicyBacksOffExponentiallyUpToOneHour() {
        var policy = SecondaryPolicy()
        let answers: [(Int?, Bool)] = [(500, false), (503, false), (429, false), (nil, true), (502, false), (500, false), (500, false), (500, false)]
        let delays = answers.map { status, error -> TimeInterval? in
            if case .retry(let after) = policy.decide(status: status, error: error, now: start) { return after }
            return nil
        }
        XCTAssertEqual(delays, [60, 120, 240, 480, 960, 1920, 3600, 3600])
        XCTAssertEqual(policy.state.nextAttemptAt, start.addingTimeInterval(3600))
        XCTAssertTrue(policy.state.rejections.isEmpty, "Serverfehler sind kein Urteil über das Paket")
    }

    /// 401 und 403 halten das Zweitziel an. Nichts wird gezählt, niemand wird abgemeldet.
    func testPolicyPausesOnAuthErrorsWithoutCounting() {
        var policy = SecondaryPolicy()
        XCTAssertEqual(policy.decide(status: 401, error: false, now: start), .pause(authStatus: 401))
        XCTAssertEqual(policy.decide(status: 403, error: false, now: start), .pause(authStatus: 403))
        XCTAssertTrue(policy.state.rejections.isEmpty)
        XCTAssertEqual(policy.state.failures, 0)
    }

    /// 400/413/422 dreimal im Abstand von je mindestens einer Stunde: beim dritten Mal `dead`.
    func testPolicyMovesARecordSpecificRejectionToDeadAfterThreeSpacedRejections() {
        var policy = SecondaryPolicy()
        XCTAssertEqual(policy.decide(status: 422, error: false, now: start), .retry(after: 3600))
        XCTAssertEqual(policy.decide(status: 400, error: false, now: start.addingTimeInterval(3600)), .retry(after: 3600))
        XCTAssertEqual(policy.decide(status: 413, error: false, now: start.addingTimeInterval(7200)), .dead)
    }

    /// Drei Ablehnungen innerhalb einer Stunde zählen einmal; gewartet wird bis zum Ende des Abstands.
    func testPolicyCountsRejectionsWithinAnHourOnlyOnce() {
        var policy = SecondaryPolicy()
        XCTAssertEqual(policy.decide(status: 422, error: false, now: start), .retry(after: 3600))
        XCTAssertEqual(policy.decide(status: 422, error: false, now: start.addingTimeInterval(600)), .retry(after: 3000))
        XCTAssertEqual(policy.decide(status: 422, error: false, now: start.addingTimeInterval(1200)), .retry(after: 2400))
        XCTAssertEqual(policy.state.rejections, [start])
        XCTAssertNotEqual(policy.decide(status: 422, error: false, now: start.addingTimeInterval(3600)), .dead)
        XCTAssertEqual(policy.state.rejections.count, 2)
    }

    /// 404, 405, 409 und Co. sagen nichts über das Paket (wie `RejectionPolicy.isRecordSpecific`).
    func testPolicyTreatsOtherClientErrorsAsTransient() {
        var policy = SecondaryPolicy()
        XCTAssertEqual(policy.decide(status: 404, error: false, now: start), .retry(after: 60))
        XCTAssertEqual(policy.decide(status: 409, error: false, now: start), .retry(after: 120))
        XCTAssertTrue(policy.state.rejections.isEmpty)
    }

    // MARK: - Sender

    /// Drei Pakete, dreimal 202: alle weg, in Reihenfolge, an den Host und mit dem Schlüssel des
    /// Zweitziels.
    func testDrainSendsAllFilesInOrderToTheSecondaryTarget() throws {
        let clock = ManualClock(start)
        let outbox = makeOutbox(clock: clock)
        for text in ["1", "2", "3"] { try outbox.enqueue(body(text)) }
        StubURLProtocol.install { _ in .status(202) }

        let result = drain(makeUploader(outbox, clock: clock))

        XCTAssertEqual(result?.delivered, 3)
        XCTAssertEqual(result?.retried, 0)
        XCTAssertEqual(result?.paused, false)
        XCTAssertTrue(outbox.pending().isEmpty)
        XCTAssertEqual(sentBodies(), ["1", "2", "3"])
        for request in StubURLProtocol.requests {
            XCTAssertEqual(request.url?.absoluteString, "https://secondary.example.test/api/v1/sdk/users/user-2/sync")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Open-Wearables-API-Key"), "secondary-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertFalse((request.value(forHTTPHeaderField: "X-Request-Id") ?? "").isEmpty)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "kein Token des Primärziels")
        }
        XCTAssertEqual(outbox.state().lastSuccessAt, clock.now())
    }

    /// 503 beim zweiten Paket: das erste ist zugestellt, das zweite und dritte bleiben, der
    /// Durchlauf endet. Vor Ablauf des Backoffs geht nichts hinaus, danach in Reihenfolge weiter.
    func testDrainStopsAtTheFirstTransientFailureAndHonoursTheBackoff() throws {
        let clock = ManualClock(start)
        let outbox = makeOutbox(clock: clock)
        for text in ["1", "2", "3"] { try outbox.enqueue(body(text)) }
        let uploader = makeUploader(outbox, clock: clock)
        StubURLProtocol.install { _ in StubURLProtocol.requests.count == 2 ? .status(503) : .status(202) }

        let first = drain(uploader)

        XCTAssertEqual(first?.delivered, 1)
        XCTAssertEqual(first?.retried, 1)
        XCTAssertEqual(first?.lastError, "HTTP 503")
        XCTAssertEqual(contents(outbox.pending()), ["2", "3"])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)

        let early = drain(uploader)
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "vor Ablauf des Backoffs wird nichts gesendet")
        XCTAssertEqual(early?.deferredUntil, start.addingTimeInterval(60))

        clock.advance(60)
        StubURLProtocol.install { _ in .status(202) }
        let later = drain(uploader)
        XCTAssertEqual(later?.delivered, 2)
        XCTAssertEqual(sentBodies(), ["2", "3"])
        XCTAssertTrue(outbox.pending().isEmpty)
    }

    /// 401 am Zweitziel: nichts entfernt, Ergebnis `paused`, kein `onAuthError`, die Sitzung des
    /// Primärziels bleibt.
    func testAuthErrorPausesWithoutTouchingThePrimarySession() throws {
        try withIsolatedSDK { sdk, _ in
            var authErrors = 0
            sdk.onAuthError = { _, _ in authErrors += 1 }
            let clock = ManualClock(start)
            let outbox = makeOutbox(clock: clock)
            for text in ["1", "2", "3"] { try outbox.enqueue(body(text)) }
            StubURLProtocol.install { _ in .status(401) }

            let result = drain(makeUploader(outbox, clock: clock))

            XCTAssertEqual(result?.paused, true)
            XCTAssertEqual(result?.delivered, 0)
            XCTAssertEqual(result?.lastError, "auth 401")
            XCTAssertEqual(contents(outbox.pending()), ["1", "2", "3"])
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "nach der Pause geht nichts weiter hinaus")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(authErrors, 0)
            XCTAssertTrue(OpenWearablesHealthSdkKeychain.hasSession(), "das Primärziel bleibt angemeldet")
        }
    }

    /// Ein dauerhaft abgewiesenes Paket hält die Reihe auf, bis es nach drei Ablehnungen im
    /// Stundenabstand in `dead/` liegt. Danach geht das nächste hinaus.
    func testRecordSpecificRejectionGoesToDeadAndUnblocksTheQueue() throws {
        let clock = ManualClock(start)
        let outbox = makeOutbox(clock: clock)
        try outbox.enqueue(body("kaputt"))
        try outbox.enqueue(body("gut"))
        let uploader = makeUploader(outbox, clock: clock)
        // Der Anbieter läuft, nachdem die aktuelle Anfrage aufgezeichnet ist: sie ist die letzte.
        StubURLProtocol.install { _ in
            let current = StubURLProtocol.recorded.last.map { String(decoding: $0.body, as: UTF8.self) }
            return current == "kaputt" ? .status(422) : .status(202)
        }

        XCTAssertEqual(drain(uploader)?.retried, 1)
        clock.advance(3600)
        XCTAssertEqual(drain(uploader)?.retried, 1)
        clock.advance(3600)
        let last = drain(uploader)

        XCTAssertEqual(last?.dead, 1)
        XCTAssertEqual(last?.delivered, 1)
        XCTAssertTrue(outbox.pending().isEmpty)
        XCTAssertEqual(contents(outbox.deadFiles()), ["kaputt"])
        XCTAssertEqual(outbox.counts().dead, 1)
    }

    /// Zwei Durchläufe zugleich: der zweite sendet nichts, keine Datei geht doppelt hinaus.
    func testConcurrentDrainsNeverSendAFileTwice() throws {
        let clock = ManualClock(start)
        let outbox = makeOutbox(clock: clock)
        for text in ["1", "2", "3"] { try outbox.enqueue(body(text)) }
        StubURLProtocol.install { _ in .trickle(202, chunks: 2, every: 0.05) }
        let first = makeUploader(outbox, clock: clock)
        let second = makeUploader(outbox, clock: clock)

        let lock = NSLock()
        var results: [SecondaryDrainResult] = []
        for uploader in [first, second] {
            uploader.drain(target: target) { result in
                lock.lock()
                results.append(result)
                lock.unlock()
            }
        }
        waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return results.count == 2
        }

        XCTAssertEqual(sentBodies(), ["1", "2", "3"])
        lock.lock()
        let skipped = results.filter(\.skipped).count
        let delivered = results.map(\.delivered).reduce(0, +)
        lock.unlock()
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(delivered, 3)
    }

    /// Ins Log gehen nur Zahlen und Statuscodes, nie die Ladung oder der Antworttext (LO-12).
    func testLogsCarryNoPayloadAndNoResponseBody() throws {
        let clock = ManualClock(start)
        let lock = NSLock()
        var lines: [String] = []
        let log: (String) -> Void = { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        let outbox = makeOutbox(clock: clock, log: log)
        try outbox.enqueue(body(#"{"value":"80.1kg-geheim"}"#))
        StubURLProtocol.install { _ in .status(422, #"{"detail":[{"input":"80.1kg-geheim"}]}"#) }

        _ = drain(makeUploader(outbox, clock: clock, log: log))

        lock.lock()
        let logged = lines.joined(separator: "\n")
        lock.unlock()
        XCTAssertFalse(logged.isEmpty)
        XCTAssertFalse(logged.contains("geheim"), logged)
        XCTAssertFalse(logged.contains("80.1"), logged)
        XCTAssertTrue(logged.contains("422"), logged)
    }
}
