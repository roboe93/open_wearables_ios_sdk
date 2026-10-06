import XCTest
@testable import OpenWearablesHealthSDK

/// Die dauerhafte Löschwarteschlange (D-12, SYNC-12, Plan 05-07).
final class DeletionQueueTests: XCTestCase {

    private let weight = "HKQuantityTypeIdentifierBodyMass"
    private let steps = "HKQuantityTypeIdentifierStepCount"
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 24 * 3600

    private var directory: URL!
    private var clock: ManualClock!
    private var journal: RunJournal!
    private var logged: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-deletion-tests-\(UUID().uuidString)", isDirectory: true)
        clock = ManualClock(epoch)
        journal = RunJournal(directory: directory.appendingPathComponent("journal", isDirectory: true))
        logged = []
    }

    override func tearDown() {
        // Der Test-Ordner liegt im temporären Verzeichnis der Simulator-Instanz. Aufgeräumt wird
        // der gesamte Ordner dieses Tests, nie etwas ausserhalb davon.
        if let directory = directory, directory.path.contains("ow-deletion-tests-") {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private func makeQueue(
        maxEntries: Int = 50_000, maxAge: TimeInterval = 90 * 24 * 3600, tracksSecondary: Bool = false
    ) -> DeletionQueue {
        DeletionQueue(
            directory: directory.appendingPathComponent("health_deletions", isDirectory: true),
            clock: clock, journal: journal,
            log: { [unowned self] in self.logged.append($0) },
            maxEntries: maxEntries, maxAge: maxAge, tracksSecondary: tracksSecondary
        )
    }

    private var queueFile: URL {
        directory.appendingPathComponent("health_deletions/queue.json")
    }

    private func ref(_ id: String, type: String? = nil) -> DeletedRef {
        DeletedRef(id: id, type: type ?? weight)
    }

    private func fileJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: queueFile)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Dauerhaftigkeit

    func testEnqueueSurvivesANewInstanceOnTheSameDirectory() throws {
        try makeQueue().enqueue([ref("a"), ref("b", type: steps)], sentAt: nil)

        let reopened = makeQueue()
        XCTAssertEqual(reopened.stats().total, 2)
        XCTAssertEqual(reopened.stats().unsent, 2)
        XCTAssertEqual(reopened.unsent(limit: 10), [ref("a"), ref("b", type: steps)])
    }

    func testTheFileHoldsOnlyIdsTypesAndTimes() throws {
        try makeQueue().enqueue([ref("abc-1")], sentAt: nil)
        try makeQueue().markSent(ids: ["abc-1"], at: epoch.addingTimeInterval(60))

        let json = try fileJSON()
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        guard entries.count == 1 else { return }
        XCTAssertEqual(Set(entries[0].keys), ["id", "type", "queuedAt", "sentAt"])
        XCTAssertEqual(entries[0]["id"] as? String, "abc-1")
        XCTAssertEqual(entries[0]["type"] as? String, weight)
        XCTAssertNotNil(json["version"])
    }

    func testAnUnsentEntryHasNoSentAtKey() throws {
        try makeQueue().enqueue([ref("only")], sentAt: nil)
        let entries = try XCTUnwrap(try fileJSON()["entries"] as? [[String: Any]])
        guard !entries.isEmpty else { return XCTFail("keine Einträge in der Datei") }
        XCTAssertNil(entries[0]["sentAt"], "Der Auswerter aus 05-02 zählt ein fehlendes sentAt als ungesendet")
    }

    func testEnqueueingNothingWritesNothing() throws {
        try makeQueue().enqueue([], sentAt: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path))
    }

    // MARK: Doppelte Kennungen

    func testTheSameIdTwiceIsOneEntryAndKeepsTheEarliestQueuedAt() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("dup")], sentAt: nil)
        clock.advance(3600)
        try queue.enqueue([ref("dup")], sentAt: nil)

        XCTAssertEqual(queue.stats().total, 1)
        let entries = try XCTUnwrap(try fileJSON()["entries"] as? [[String: Any]])
        guard !entries.isEmpty else { return XCTFail("keine Einträge in der Datei") }
        let queuedAt = try XCTUnwrap(entries[0]["queuedAt"] as? String)
        XCTAssertEqual(LaneTime.date(from: queuedAt), epoch)
    }

    func testAnEntryIsMarkedSentWhenTheSecondEnqueueBringsASentAt() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("dup")], sentAt: nil)
        XCTAssertEqual(queue.stats().unsent, 1)

        clock.advance(60)
        try queue.enqueue([ref("dup")], sentAt: clock.now())
        XCTAssertEqual(queue.stats().total, 1)
        XCTAssertEqual(queue.stats().unsent, 0)
    }

    func testAnAlreadySentEntryNeverBecomesUnsentAgain() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("dup")], sentAt: epoch)
        try queue.enqueue([ref("dup")], sentAt: nil)
        XCTAssertEqual(queue.stats().unsent, 0)
    }

    func testANewEntryWithASentAtIsStoredAsSent() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("done")], sentAt: epoch)
        XCTAssertEqual(queue.stats().total, 1)
        XCTAssertEqual(queue.stats().unsent, 0)
        XCTAssertTrue(queue.unsent(limit: 10).isEmpty)
    }

    // MARK: Ungesendete

    func testUnsentReturnsTheOldestFirstAndHonoursTheLimit() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("1")], sentAt: nil)
        clock.advance(10)
        try queue.enqueue([ref("2"), ref("3")], sentAt: nil)
        clock.advance(10)
        try queue.enqueue([ref("4")], sentAt: nil)

        XCTAssertEqual(queue.unsent(limit: 3).map(\.id), ["1", "2", "3"])
        XCTAssertEqual(queue.unsent(limit: 100).map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(queue.unsent(limit: 0), [])
    }

    func testMarkSentRemovesEntriesFromTheUnsentListButKeepsThem() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("1"), ref("2"), ref("3")], sentAt: nil)

        clock.advance(5)
        try queue.markSent(ids: ["1", "3", "unbekannt"], at: clock.now())

        XCTAssertEqual(queue.unsent(limit: 10).map(\.id), ["2"])
        XCTAssertEqual(queue.stats().total, 3)
        XCTAssertEqual(queue.stats().unsent, 1)
    }

    func testMarkSentDoesNotMoveAnEarlierSentAt() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("1")], sentAt: nil)
        try queue.markSent(ids: ["1"], at: epoch.addingTimeInterval(100))
        try queue.markSent(ids: ["1"], at: epoch.addingTimeInterval(900))

        let entries = try XCTUnwrap(try fileJSON()["entries"] as? [[String: Any]])
        guard !entries.isEmpty else { return XCTFail("keine Einträge in der Datei") }
        let sentAt = try XCTUnwrap(entries[0]["sentAt"] as? String)
        XCTAssertEqual(LaneTime.date(from: sentAt), epoch.addingTimeInterval(100))
    }

    // MARK: Deckel

    func testTheCountCapKeepsTheYoungestAndReportsWhatItDropped() throws {
        let queue = makeQueue(maxEntries: 5)
        for index in 1...7 {
            try queue.enqueue([ref("id-\(index)")], sentAt: nil)
            clock.advance(10)
        }

        XCTAssertEqual(queue.stats().total, 5)
        XCTAssertEqual(queue.unsent(limit: 10).map(\.id), ["id-3", "id-4", "id-5", "id-6", "id-7"])

        let capLines = logged.filter { $0.contains("Löschwarteschlange gekappt") }
        XCTAssertEqual(capLines.count, 2, "jedes Kappen steht im Log, einmal je Schreiben")
        XCTAssertTrue(capLines.allSatisfy { $0.contains("1 Einträge") && $0.contains("Anzahl") })

        let entries = journal.entries().filter { $0.kind == "deletions" }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.deletions), [1, 1])
    }

    func testOneWriteThatCapsSeveralEntriesReportsTheirNumber() throws {
        let queue = makeQueue(maxEntries: 5)
        try queue.enqueue((1...7).map { ref("id-\($0)") }, sentAt: nil)

        XCTAssertEqual(queue.stats().total, 5)
        XCTAssertEqual(queue.unsent(limit: 10).map(\.id), ["id-3", "id-4", "id-5", "id-6", "id-7"])
        let entry = try XCTUnwrap(journal.entries().first { $0.kind == "deletions" })
        XCTAssertEqual(entry.deletions, 2)
        XCTAssertTrue(logged.contains { $0.contains("Löschwarteschlange gekappt: 2 Einträge") })
    }

    func testTheAgeCapDropsEntriesOlderThanNinetyDays() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("alt")], sentAt: nil)

        clock.advance(91 * day)
        try queue.enqueue([ref("neu")], sentAt: nil)

        XCTAssertEqual(queue.unsent(limit: 10).map(\.id), ["neu"])
        XCTAssertEqual(queue.stats().total, 1)
        XCTAssertTrue(logged.contains { $0.contains("Löschwarteschlange gekappt: 1 Einträge") && $0.contains("Alter") })
        let entry = try XCTUnwrap(journal.entries().first { $0.kind == "deletions" })
        XCTAssertEqual(entry.deletions, 1)
    }

    func testAnEntryYoungerThanNinetyDaysStays() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("a")], sentAt: nil)
        clock.advance(89 * day)
        try queue.enqueue([ref("b")], sentAt: nil)

        XCTAssertEqual(queue.stats().total, 2)
        XCTAssertTrue(logged.filter { $0.contains("gekappt") }.isEmpty)
        XCTAssertTrue(journal.entries().filter { $0.kind == "deletions" }.isEmpty)
    }

    func testTheCapAlsoAppliesWhenMarkingSent() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("alt")], sentAt: nil)
        clock.advance(50 * day)
        try queue.enqueue([ref("mitte")], sentAt: nil)
        clock.advance(41 * day)
        XCTAssertEqual(queue.stats().total, 2, "gekappt wird beim Schreiben, nicht beim Lesen")

        try queue.markSent(ids: ["mitte"], at: clock.now())

        XCTAssertEqual(queue.stats().total, 1)
        XCTAssertTrue(queue.unsent(limit: 10).isEmpty)
        XCTAssertTrue(logged.contains { $0.contains("Löschwarteschlange gekappt: 1 Einträge") })
    }

    func testMarkingNothingSentWritesNothingAndSoCapsNothing() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("alt")], sentAt: nil)
        clock.advance(91 * day)

        try queue.markSent(ids: ["gibt-es-nicht"], at: clock.now())
        XCTAssertEqual(queue.stats().total, 1)
        XCTAssertTrue(logged.filter { $0.contains("gekappt") }.isEmpty)
    }

    func testTheCapReportsHowManyOfTheDroppedWereStillUnsent() throws {
        let queue = makeQueue(maxEntries: 2)
        try queue.enqueue([ref("1")], sentAt: epoch)      // gesendet
        try queue.enqueue([ref("2")], sentAt: nil)
        try queue.enqueue([ref("3")], sentAt: nil)        // kappt "1" (gesendet, kein Verlust)
        try queue.enqueue([ref("4")], sentAt: nil)        // kappt "2" (ungesendet)

        let notes = journal.entries().filter { $0.kind == "deletions" }.compactMap(\.note)
        XCTAssertEqual(notes.count, 2)
        guard notes.count == 2 else { return }
        XCTAssertTrue(notes[0].contains("unsent=0"), notes[0])
        XCTAssertTrue(notes[1].contains("unsent=1"), notes[1])
    }

    func testTheDefaultCapsAreFiftyThousandEntriesAndNinetyDays() {
        let queue = DeletionQueue(
            directory: directory, clock: clock, journal: nil, log: { _ in }
        )
        XCTAssertEqual(queue.maxEntries, 50_000)
        XCTAssertEqual(queue.maxAge, 90 * 24 * 3600)
    }

    // MARK: Beschädigte und nicht lesbare Datei

    func testACorruptFileIsMovedAsideNotDeletedAndTheQueueStartsEmpty() throws {
        let folder = queueFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let garbage = Data("das ist kein json {{{".utf8)
        try garbage.write(to: queueFile)

        let queue = makeQueue()
        XCTAssertEqual(queue.stats().total, 0)
        try queue.enqueue([ref("neu")], sentAt: nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let asides = names.filter { $0.hasPrefix("queue.json.corrupt-") }
        XCTAssertEqual(asides.count, 1, "genau eine beiseitegelegte Datei, gefunden: \(names)")
        guard let aside = asides.first else { return }
        let asideData = try Data(contentsOf: folder.appendingPathComponent(aside))
        XCTAssertEqual(asideData, garbage, "der Inhalt bleibt unverändert erhalten")
        XCTAssertEqual(queue.unsent(limit: 10).map(\.id), ["neu"])
        XCTAssertTrue(logged.contains { $0.contains("beschädigt") })
    }

    func testTwoCorruptionsInTheSameSecondKeepBothFiles() throws {
        let folder = queueFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try Data("eins".utf8).write(to: queueFile)
        _ = makeQueue().stats()
        try Data("zwei".utf8).write(to: queueFile)
        _ = makeQueue().stats()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("queue.json.corrupt-") }.count, 2, "\(names)")
    }

    /// Eine Datei, die da ist, sich aber nicht lesen lässt (Schutzklasse vor dem ersten Entsperren),
    /// ist nicht beschädigt: sie wird weder umbenannt noch überschrieben, und `enqueue` meldet den
    /// Fehler, damit der Kern den Anchor festhält.
    func testAnUnreadableFileIsNeitherMovedNorOverwrittenAndEnqueueThrows() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("echt")], sentAt: nil)
        let before = try Data(contentsOf: queueFile)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: queueFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: queueFile.path) }

        XCTAssertThrowsError(try makeQueue().enqueue([ref("neu")], sentAt: nil))
        XCTAssertThrowsError(try makeQueue().markSent(ids: ["echt"], at: epoch))
        XCTAssertEqual(makeQueue().unsent(limit: 10), [], "unlesbar heisst: nichts zu senden, nie raten")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: queueFile.path)
        XCTAssertEqual(try Data(contentsOf: queueFile), before, "die Datei blieb unverändert")
        let names = try FileManager.default.contentsOfDirectory(atPath: queueFile.deletingLastPathComponent().path)
        XCTAssertTrue(names.filter { $0.contains("corrupt") }.isEmpty, "\(names)")
    }

    func testAFileFromAFutureWriterWithExtraKeysStillLoads() throws {
        let folder = queueFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        {"version": 1, "extra": true, "entries": [
          {"id": "x1", "type": "\(weight)", "queuedAt": "2026-10-04T08:00:00.000Z", "zukunft": 1}
        ]}
        """
        try Data(json.utf8).write(to: queueFile)

        let queue = makeQueue()
        XCTAssertEqual(queue.unsent(limit: 5).map(\.id), ["x1"])
    }

    /// Review LO-07: Zyklus, abgelöster Zyklus und `getSyncStatus` haben je eine eigene Instanz.
    /// Die Sperre gilt für die Datei im ganzen Prozess, nicht je Instanz: nichts geht verloren.
    func testTwoQueueInstancesWritingAtOnceLoseNothing() {
        withIsolatedSDK { sdk, _ in
            let queues = [sdk.makeDeletionQueue(), sdk.makeDeletionQueue()]
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                try? queues[index % 2].enqueue([DeletedRef(id: "d-\(index)", type: self.weight)], sentAt: nil)
            }
            XCTAssertEqual(sdk.makeDeletionQueue().stats().total, 40)
        }
    }

    // MARK: Zweitziel (Plan 09-04): ein Gesendet-Kennzeichen je Ziel

    private func entry(_ queue: DeletionQueue, _ id: String) -> DeletionQueue.Entry? {
        queue.entries().first { $0.id == id }
    }

    /// Eine Datei von 0.15.0-ow.3 (ohne `sentSecondaryAt`) dekodiert. Für das Zweitziel gilt dann
    /// jeder Eintrag als ungesendet, für das Primärziel bleibt `sentAt` maßgeblich.
    func testAFileWithoutTheSecondaryMarkStillDecodes() throws {
        let folder = queueFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        {"version": 1, "entries": [
          {"id": "x1", "type": "\(weight)", "queuedAt": "2026-10-04T08:00:00.000Z", "sentAt": "2026-10-04T08:01:00.000Z"},
          {"id": "x2", "type": "\(steps)", "queuedAt": "2026-10-04T08:02:00.000Z"}
        ]}
        """
        try Data(json.utf8).write(to: queueFile)

        let queue = makeQueue()
        XCTAssertEqual(queue.unsentSecondary(limit: 10).map(\.id), ["x1", "x2"])
        XCTAssertEqual(queue.unsent(limit: 10).map(\.id), ["x2"])
        XCTAssertEqual(queue.entries().count, 2)
        XCTAssertNil(entry(queue, "x1")?.sentSecondaryAt)
    }

    /// `markSentSecondary` setzt nur das Kennzeichen des Zweitziels. Ein schon gesetztes bleibt bei
    /// seinem Zeitpunkt, unbekannte Kennungen werden übergangen.
    func testMarkSentSecondarySetsOnlyTheSecondaryMark() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("a"), ref("b")], sentAt: nil)
        try queue.markSent(ids: ["a"], at: epoch.addingTimeInterval(10))

        try queue.markSentSecondary(ids: ["a", "b", "gibt-es-nicht"], at: epoch.addingTimeInterval(20))
        try queue.markSentSecondary(ids: ["a"], at: epoch.addingTimeInterval(99))

        XCTAssertEqual(entry(queue, "a")?.sentAt, epoch.addingTimeInterval(10))
        XCTAssertEqual(entry(queue, "a")?.sentSecondaryAt, epoch.addingTimeInterval(20))
        XCTAssertNil(entry(queue, "b")?.sentAt, "das Primärziel bleibt ungesendet")
        XCTAssertEqual(entry(queue, "b")?.sentSecondaryAt, epoch.addingTimeInterval(20))
        XCTAssertTrue(queue.unsentSecondary(limit: 10).isEmpty)
        XCTAssertEqual(queue.unsent(limit: 10).map(\.id), ["b"])
        XCTAssertEqual(queue.entries().count, 2)
    }

    /// Die ältesten fürs Zweitziel ungesendeten zuerst, höchstens `limit`. Das Primär-Kennzeichen
    /// spielt dafür keine Rolle.
    func testUnsentSecondaryReturnsTheOldestFirstAndHonoursTheLimit() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("1")], sentAt: epoch)
        try queue.enqueue([ref("2")], sentAt: nil, sentSecondaryAt: epoch)
        try queue.enqueue([ref("3", type: steps)], sentAt: nil)
        try queue.enqueue([ref("4")], sentAt: nil)

        XCTAssertEqual(queue.unsentSecondary(limit: 2), [ref("1"), ref("3", type: steps)])
        XCTAssertEqual(queue.unsentSecondary(limit: 10).map(\.id), ["1", "3", "4"])
        XCTAssertTrue(queue.unsentSecondary(limit: 0).isEmpty)
    }

    /// Einreihen mit dem Kennzeichen des Zweitziels: neue Einträge entstehen damit, vorhandene
    /// bekommen es, wenn sie es noch nicht haben. `queuedAt` bleibt das früheste. Ein späteres
    /// Einreihen des Kerns mit `sentAt` lässt das Kennzeichen des Zweitziels stehen.
    func testEnqueueWithTheSecondaryMarkAddsNewEntriesAndMarksExistingOnes() throws {
        let queue = makeQueue()
        try queue.enqueue([ref("a")], sentAt: nil)
        clock.advance(30)
        try queue.enqueue([ref("a"), ref("b")], sentAt: nil, sentSecondaryAt: epoch.addingTimeInterval(30))

        XCTAssertEqual(entry(queue, "a")?.queuedAt, epoch)
        XCTAssertEqual(entry(queue, "a")?.sentSecondaryAt, epoch.addingTimeInterval(30))
        XCTAssertEqual(entry(queue, "b")?.sentSecondaryAt, epoch.addingTimeInterval(30))
        XCTAssertNil(entry(queue, "b")?.sentAt)

        let entries = try XCTUnwrap(try fileJSON()["entries"] as? [[String: Any]])
        let fileB = try XCTUnwrap(entries.first { $0["id"] as? String == "b" })
        XCTAssertEqual(Set(fileB.keys), ["id", "type", "queuedAt", "sentSecondaryAt"])

        try queue.enqueue([ref("b")], sentAt: epoch.addingTimeInterval(40))
        XCTAssertEqual(entry(queue, "b")?.sentAt, epoch.addingTimeInterval(40))
        XCTAssertEqual(entry(queue, "b")?.sentSecondaryAt, epoch.addingTimeInterval(30))
    }

    /// Ist das Zweitziel aktiv, nennt ein Kappen auch die dort ungesendeten Einträge. Ohne Zweitziel
    /// bleiben Log und Journal wie vor 09-04.
    func testTheCapCountsTheSecondaryOnlyWhenTheQueueTracksIt() throws {
        let tracked = makeQueue(maxEntries: 1, tracksSecondary: true)
        try tracked.enqueue([ref("1")], sentAt: epoch)          // Primär gesendet, Zweitziel nicht
        try tracked.enqueue([ref("2")], sentAt: nil)            // kappt "1"

        let trackedNote = try XCTUnwrap(journal.entries().last { $0.kind == "deletions" }?.note)
        XCTAssertTrue(trackedNote.contains("unsent=0"), trackedNote)
        XCTAssertTrue(trackedNote.contains("unsentSecondary=1"), trackedNote)
        XCTAssertTrue(logged.contains { $0.contains("Zweitziel") }, "\(logged)")

        logged = []
        let plain = makeQueue(maxEntries: 1)
        try plain.enqueue([ref("3")], sentAt: nil)              // kappt "2"

        let plainNote = try XCTUnwrap(journal.entries().last { $0.kind == "deletions" }?.note)
        XCTAssertEqual(plainNote, "capped reason=count unsent=1")
        XCTAssertFalse(logged.contains { $0.contains("Zweitziel") }, "\(logged)")
    }
}
