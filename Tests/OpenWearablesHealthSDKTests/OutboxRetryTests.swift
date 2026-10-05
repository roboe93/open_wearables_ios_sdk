import XCTest
@testable import OpenWearablesHealthSDK

/// Covers the outbox drain that carries leftovers from pre-0.14 installs: which items
/// are replayed, which are dropped, and the guard that stops two overlapping passes from
/// sending the same item twice. See issue #34.
final class OutboxRetryTests: XCTestCase {

    private struct Leftover {
        let item: URL
        let payload: URL
        /// Die Anchor-Datei im heutigen Container, `nil` ohne Anchors.
        let anchor: URL?

        var itemExists: Bool { FileManager.default.fileExists(atPath: item.path) }
        var payloadExists: Bool { FileManager.default.fileExists(atPath: payload.path) }
        var anchorExists: Bool { anchor.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }

    private let userKey = "user.test-user"
    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let steps = "HKQuantityTypeIdentifierStepCount"

    /// Application Support eines früheren App-Containers. Das Gerät vom 05.10.2026 hatte Items von
    /// SDK 0.13.2, deren absolute Pfade in einen Container zeigten, den es nach einer Neuinstallation
    /// nicht mehr gibt. Auf dem Mac, auf dem der Simulator läuft, gibt es `/private/var/mobile` nie.
    private let earlierContainer = URL(
        fileURLWithPath: "/private/var/mobile/Containers/Data/Application/0E1F2A3B-4C5D-4E6F-8A9B-0C1D2E3F4A5B/Library/Application Support",
        isDirectory: true
    )

    private func outbox(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("health_outbox", isDirectory: true)
    }

    /// Writes an outbox item the way a pre-0.14 SDK would have left it. `age` is applied
    /// to the item file, which is what the drain reads to decide an item's fate.
    ///
    /// Fork (Plan 09-03): `recordedContainer` legt die Dateien in den heutigen Container, trägt im
    /// Item aber die Pfade unter dem früheren Container ein. `anchors` schreibt eine Anchor-Datei
    /// im Format des kombinierten Uploads (Typ → Anchor-Bytes, `NSKeyedArchiver`), oder, mit
    /// `typeIdentifier` eines einzelnen Typs, die rohen Bytes des einen Anchors.
    private func writeLeftover(
        in stateDirectory: URL,
        withPayload: Bool,
        age: TimeInterval,
        recordedContainer: URL? = nil,
        typeIdentifier: String = "combined",
        anchors: [String: Data]? = nil
    ) -> Leftover {
        let id = UUID().uuidString
        let directory = outbox(in: stateDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let recordedDirectory = recordedContainer?.appendingPathComponent("health_outbox", isDirectory: true) ?? directory

        let payloadName = "combined_payload_\(id).json"
        let payloadURL = directory.appendingPathComponent(payloadName)
        if withPayload {
            try? Data(#"{"provider":"apple","data":{}}"#.utf8).write(to: payloadURL)
        }

        var anchorURL: URL?
        var recordedAnchorPath: String?
        if let anchors = anchors {
            let anchorName = "combined_anchors_\(id).bin"
            let url = directory.appendingPathComponent(anchorName)
            let bytes: Data?
            if typeIdentifier == "combined" {
                bytes = try? NSKeyedArchiver.archivedData(
                    withRootObject: anchors as NSDictionary, requiringSecureCoding: true
                )
            } else {
                bytes = anchors[typeIdentifier]
            }
            try? bytes?.write(to: url)
            anchorURL = url
            recordedAnchorPath = recordedDirectory.appendingPathComponent(anchorName).path
        }

        let itemURL = writeItem(
            in: directory,
            name: "combined_item_\(id).json",
            typeIdentifier: typeIdentifier,
            payloadPath: recordedDirectory.appendingPathComponent(payloadName).path,
            anchorPath: recordedAnchorPath,
            age: age
        )

        return Leftover(item: itemURL, payload: payloadURL, anchor: anchorURL)
    }

    private func writeItem(
        in directory: URL,
        name: String,
        typeIdentifier: String = "combined",
        payloadPath: String,
        anchorPath: String?,
        age: TimeInterval
    ) -> URL {
        let item = OpenWearablesHealthSDK.OutboxItem(
            typeIdentifier: typeIdentifier,
            userKey: userKey,
            payloadPath: payloadPath,
            anchorPath: anchorPath,
            wasFullExport: false
        )
        let itemURL = directory.appendingPathComponent(name)
        try? JSONEncoder().encode(item).write(to: itemURL)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: itemURL.path
        )
        return itemURL
    }

    /// Ersetzt die Hintergrund-Session des SDK durch eine Session mit `StubURLProtocol` und dem SDK
    /// als Delegate. So läuft der ganze Weg: Item lesen, Upload, `urlSession(_:task:didCompleteWithError:)`,
    /// Anchors speichern, Dateien entfernen. Eine echte Hintergrund-Session ließe sich im Test nicht
    /// beantworten.
    private func withStubbedOutboxSession(_ sdk: OpenWearablesHealthSDK, _ body: (URLSession) throws -> Void) rethrows {
        let previous: URLSession? = sdk.session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let stubSession = URLSession(configuration: configuration, delegate: sdk, delegateQueue: nil)
        sdk.session = stubSession
        defer {
            sdk.session = previous
            stubSession.invalidateAndCancel()
        }
        try body(stubSession)
    }

    private func anchor(_ sdk: OpenWearablesHealthSDK, _ typeIdentifier: String) -> Data? {
        sdk.defaults.data(forKey: sdk.anchorKey(typeIdentifier: typeIdentifier, userKey: userKey))
    }

    /// Pfade ohne `/private`-Präfix und ohne `..`, damit `/var/…` und `/private/var/…` gleich sind.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func taskDescriptions(of session: URLSession) -> [String] {
        let lock = NSLock()
        var descriptions: [String]?
        session.getAllTasks { tasks in
            lock.lock()
            descriptions = tasks.compactMap(\.taskDescription)
            lock.unlock()
        }
        waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return descriptions != nil
        }
        lock.lock()
        defer { lock.unlock() }
        return descriptions ?? []
    }

    /// A week-old batch is not worth replaying: the regular sync re-fetches that window
    /// from HealthKit anyway, so the item and its payload are deleted.
    func testDropsItemsPastTheMaximumAge() {
        withIsolatedSDK { sdk, stateDirectory in
            let leftover = writeLeftover(in: stateDirectory, withPayload: true, age: 8 * 24 * 3600)

            sdk.retryOutboxIfPossible()

            XCTAssertTrue(waitUntil { !leftover.itemExists })
            XCTAssertFalse(leftover.payloadExists, "the payload should go with the item")
        }
    }

    /// Metadata whose payload is gone can never be replayed, so it must not linger on
    /// disk forever.
    func testCleansUpItemWhosePayloadIsMissing() {
        withIsolatedSDK { sdk, stateDirectory in
            let leftover = writeLeftover(in: stateDirectory, withPayload: false, age: 120)

            sdk.retryOutboxIfPossible()

            XCTAssertTrue(waitUntil { !leftover.itemExists })
        }
    }

    /// A just-written item may still have its original upload in flight, so the drain
    /// leaves it alone rather than sending a duplicate.
    func testLeavesItemsYoungerThanTheMinimumAgeUntouched() {
        withIsolatedSDK { sdk, stateDirectory in
            let leftover = writeLeftover(in: stateDirectory, withPayload: true, age: 5)

            sdk.retryOutboxIfPossible()

            XCTAssertFalse(waitUntil(timeout: 1) { !leftover.itemExists })
            XCTAssertTrue(leftover.payloadExists)
        }
    }

    /// A refresh completing and a background task firing can both reach the drain. Only
    /// one pass may run, otherwise the same item goes out twice.
    func testSkipsPassWhileAnotherIsAlreadyRunning() {
        withIsolatedSDK { sdk, stateDirectory in
            let leftover = writeLeftover(in: stateDirectory, withPayload: true, age: 8 * 24 * 3600)

            sdk.outboxRetryLock.lock()
            sdk.isRetryingOutbox = true
            sdk.outboxRetryLock.unlock()
            defer {
                sdk.outboxRetryLock.lock()
                sdk.isRetryingOutbox = false
                sdk.outboxRetryLock.unlock()
            }

            sdk.retryOutboxIfPossible()

            XCTAssertFalse(
                waitUntil(timeout: 1) { !leftover.itemExists },
                "the stale item would have been dropped had the pass not been skipped"
            )
        }
    }

    /// A drain pass while a sync round is live would compete with it for the same
    /// connection budget, so it is deferred.
    func testSkipsPassWhileASyncRunIsLive() {
        withIsolatedSDK { sdk, stateDirectory in
            let leftover = writeLeftover(in: stateDirectory, withPayload: true, age: 8 * 24 * 3600)
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            defer { sdk.finishSync(generation: generation) }

            sdk.retryOutboxIfPossible()

            XCTAssertFalse(waitUntil(timeout: 1) { !leftover.itemExists })
        }
    }

    // MARK: - Altlast aus einem früheren App-Container (Plan 09-03, Gerätebefund 05.10.2026)

    /// Der Pfad im Item zeigt in einen Container, den es nicht mehr gibt, die Ladung liegt unter
    /// gleichem Namen in der heutigen Outbox. Sie geht hinaus, statt als verwaist liegen zu bleiben.
    func testUploadsLeftoverWhosePathsPointAtAnEarlierContainer() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                withStubbedOutboxSession(sdk) { _ in
                    StubURLProtocol.install { _ in .status(202) }
                    let leftover = writeLeftover(
                        in: stateDirectory, withPayload: true, age: 120, recordedContainer: earlierContainer
                    )

                    sdk.retryOutboxIfPossible()

                    XCTAssertTrue(
                        waitUntil { !leftover.itemExists && !leftover.payloadExists },
                        "Item und Ladung sind nach der Annahme erledigt"
                    )
                    XCTAssertEqual(StubURLProtocol.requests.count, 1, "die Ladung ging genau einmal hinaus")
                }
            }
        }
    }

    /// Der Hintergrund-Delegate kennt nur die Pfade aus `taskDescription`. Dort müssen die Dateien
    /// im heutigen Container stehen, sonst räumt er nach der Antwort ins Leere.
    func testTaskDescriptionCarriesThePathsInTheCurrentContainer() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                withStubbedOutboxSession(sdk) { session in
                    StubURLProtocol.install { _ in .hang }
                    let leftover = writeLeftover(
                        in: stateDirectory, withPayload: true, age: 120,
                        recordedContainer: earlierContainer, anchors: [steps: Data("leftover-steps".utf8)]
                    )

                    sdk.retryOutboxIfPossible()

                    XCTAssertTrue(waitUntil { StubURLProtocol.requests.count == 1 })
                    let descriptions = taskDescriptions(of: session)
                    XCTAssertEqual(descriptions.count, 1)
                    let parts = (descriptions.first ?? "")
                        .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    XCTAssertEqual(parts.count, 4)
                    guard parts.count == 4, let anchorURL = leftover.anchor else { return }
                    XCTAssertEqual(canonical(parts[0]), canonical(leftover.item.path))
                    XCTAssertEqual(canonical(parts[1]), canonical(leftover.payload.path))
                    XCTAssertEqual(canonical(parts[2]), canonical(anchorURL.path))
                    XCTAssertFalse(parts[1].hasPrefix("/private/var/mobile"), parts[1])
                    XCTAssertFalse(parts[2].hasPrefix("/private/var/mobile"), parts[2])
                }
            }
        }
    }

    /// Nach der Annahme sind Item, Ladung und Anchor-Datei im heutigen Container entfernt, und ein
    /// Typ ohne Anchor bekommt den Anchor der Altlast wie bisher.
    func testAcceptedLeftoverClearsItsFilesInTheCurrentContainer() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                withStubbedOutboxSession(sdk) { _ in
                    StubURLProtocol.install { _ in .status(202) }
                    let leftover = writeLeftover(
                        in: stateDirectory, withPayload: true, age: 120,
                        recordedContainer: earlierContainer, anchors: [steps: Data("leftover-steps".utf8)]
                    )

                    sdk.retryOutboxIfPossible()

                    XCTAssertTrue(waitUntil {
                        !leftover.itemExists && !leftover.payloadExists && !leftover.anchorExists
                    })
                    XCTAssertEqual(anchor(sdk, steps), Data("leftover-steps".utf8))
                }
            }
        }
    }

    /// Seit 0.14 schreibt nichts mehr in die Outbox: jede Datei dort ist älter als der heutige
    /// Anchor. Ein vorhandener Anchor bleibt bytegleich, ein Typ ohne Anchor bekommt ihn. Die Zahl
    /// der übergangenen Anchors steht im Log, ohne Typen oder Werte.
    func testLeftoverAnchorNeverOverwritesAnExistingAnchor() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                withStubbedOutboxSession(sdk) { _ in
                    let current = Data("current-heart-rate-anchor".utf8)
                    sdk.saveAnchorData(current, typeIdentifier: heartRate, userKey: userKey)

                    let previousLog = sdk.onLog
                    let lock = NSLock()
                    var lines: [String] = []
                    sdk.onLog = { line in
                        lock.lock()
                        lines.append(line)
                        lock.unlock()
                    }
                    defer { sdk.onLog = previousLog }

                    StubURLProtocol.install { _ in .status(202) }
                    let leftover = writeLeftover(
                        in: stateDirectory, withPayload: true, age: 120,
                        anchors: [heartRate: Data("old-heart-rate".utf8), steps: Data("leftover-steps".utf8)]
                    )

                    sdk.retryOutboxIfPossible()

                    XCTAssertTrue(waitUntil {
                        !leftover.itemExists && !leftover.payloadExists && !leftover.anchorExists
                    })
                    XCTAssertEqual(anchor(sdk, heartRate), current, "ein vorhandener Anchor wird nie zurückgesetzt")
                    XCTAssertEqual(anchor(sdk, steps), Data("leftover-steps".utf8))

                    lock.lock()
                    let logged = lines.joined(separator: "\n")
                    lock.unlock()
                    XCTAssertTrue(logged.contains("kept 1 existing"), logged)
                    XCTAssertFalse(logged.contains(heartRate), "keine Typen im Log: \(logged)")
                }
            }
        }
    }

    /// Dasselbe für ein Item eines einzelnen Typs (`item_*.json` aus der Zeit vor dem kombinierten
    /// Upload): die Anchor-Datei trägt die rohen Bytes.
    func testPerTypeLeftoverAnchorNeverOverwritesAnExistingAnchor() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                withStubbedOutboxSession(sdk) { _ in
                    let current = Data("current-heart-rate-anchor".utf8)
                    sdk.saveAnchorData(current, typeIdentifier: heartRate, userKey: userKey)

                    StubURLProtocol.install { _ in .status(202) }
                    let leftover = writeLeftover(
                        in: stateDirectory, withPayload: true, age: 120,
                        typeIdentifier: heartRate, anchors: [heartRate: Data("old-heart-rate".utf8)]
                    )

                    sdk.retryOutboxIfPossible()

                    XCTAssertTrue(waitUntil {
                        !leftover.itemExists && !leftover.payloadExists && !leftover.anchorExists
                    })
                    XCTAssertEqual(anchor(sdk, heartRate), current)
                }
            }
        }
    }

    /// Eine Woche alt: Item, Ladung und Anchor werden im heutigen Container gelöscht, nicht nur das
    /// Item.
    func testDropsStaleLeftoverFromAnEarlierContainerWithItsFiles() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                let leftover = writeLeftover(
                    in: stateDirectory, withPayload: true, age: 8 * 24 * 3600,
                    recordedContainer: earlierContainer, anchors: [steps: Data("leftover-steps".utf8)]
                )

                sdk.retryOutboxIfPossible()

                XCTAssertTrue(waitUntil { !leftover.itemExists })
                XCTAssertTrue(waitUntil { !leftover.payloadExists && !leftover.anchorExists },
                              "Ladung und Anchor gehen mit dem Item")
                XCTAssertNil(anchor(sdk, steps), "ein verworfenes Item setzt keinen Anchor")
            }
        }
    }

    /// Bei einer Abweisung löscht der Delegate über die Pfade aus `taskDescription`, also die im
    /// heutigen Container. Ein Anchor wird nicht gesetzt.
    func testRejectedLeftoverFromAnEarlierContainerRemovesItsFiles() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                withStubbedOutboxSession(sdk) { _ in
                    StubURLProtocol.install { _ in .status(422) }
                    let leftover = writeLeftover(
                        in: stateDirectory, withPayload: true, age: 120,
                        recordedContainer: earlierContainer, anchors: [steps: Data("leftover-steps".utf8)]
                    )

                    sdk.retryOutboxIfPossible()

                    XCTAssertTrue(waitUntil {
                        !leftover.itemExists && !leftover.payloadExists && !leftover.anchorExists
                    })
                    XCTAssertEqual(StubURLProtocol.requests.count, 1)
                    XCTAssertNil(anchor(sdk, steps))
                }
            }
        }
    }

    /// Fehlt die Ladung auch in der heutigen Outbox, bleibt es beim bisherigen Aufräumen: das Item
    /// ist verwaist und geht, nichts wird gesendet.
    func testLeftoverWhosePayloadIsMissingEverywhereIsCleanedUp() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                withStubbedOutboxSession(sdk) { _ in
                    StubURLProtocol.install { _ in .status(202) }
                    let leftover = writeLeftover(
                        in: stateDirectory, withPayload: false, age: 120, recordedContainer: earlierContainer
                    )

                    sdk.retryOutboxIfPossible()

                    XCTAssertTrue(waitUntil { !leftover.itemExists })
                    XCTAssertEqual(StubURLProtocol.requests.count, 0)
                }
            }
        }
    }

    /// Ein Pfad im Item führt nie aus der Outbox heraus (T-09-07). `..` als letzter Bestandteil
    /// bezeichnete sonst den Zustandsordner selbst, und das Verwerfen einer alten Altlast löschte
    /// ihn. Eine Datei neben der Outbox wird über `../` nicht gefunden.
    func testRecordedPathsNeverReachOutsideTheOutbox() {
        withIsolatedDefaults { _ in
            withIsolatedSDK { sdk, stateDirectory in
                let directory = outbox(in: stateDirectory)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let sentinel = stateDirectory.appendingPathComponent("escape.json")
                try? Data("{}".utf8).write(to: sentinel)
                let recorded = earlierContainer.appendingPathComponent("health_outbox", isDirectory: true)

                let item = writeItem(
                    in: directory,
                    name: "combined_item_\(UUID().uuidString).json",
                    payloadPath: recorded.path + "/..",
                    anchorPath: recorded.path + "/../escape.json",
                    age: 8 * 24 * 3600
                )

                sdk.retryOutboxIfPossible()

                XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: item.path) })
                XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "die Outbox bleibt")
                XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "nichts außerhalb der Outbox wird gelöscht")
            }
        }
    }

    /// Die Auflösung selbst: ein vorhandener Pfad bleibt, sonst zählt nur der Dateiname, und nur
    /// eine reguläre Datei in der Outbox wird gefunden.
    func testResolveOutboxPathUsesOnlyTheFileNameInsideTheOutbox() {
        withIsolatedSDK { sdk, stateDirectory in
            let directory = outbox(in: stateDirectory)
            try? FileManager.default.createDirectory(
                at: directory.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true
            )
            let payload = directory.appendingPathComponent("combined_payload_X.json")
            try? Data("{}".utf8).write(to: payload)
            try? Data("{}".utf8).write(to: stateDirectory.appendingPathComponent("escape.json"))
            let recorded = earlierContainer.appendingPathComponent("health_outbox", isDirectory: true).path

            XCTAssertEqual(sdk.resolveOutboxPath(payload.path), payload.path, "ein vorhandener Pfad bleibt unverändert")
            XCTAssertEqual(
                sdk.resolveOutboxPath(recorded + "/combined_payload_X.json").map(canonical),
                canonical(payload.path)
            )
            XCTAssertNil(sdk.resolveOutboxPath(recorded + "/combined_payload_Y.json"), "fehlt auch in der Outbox")
            XCTAssertNil(sdk.resolveOutboxPath("../escape.json"))
            XCTAssertNil(sdk.resolveOutboxPath(recorded + "/../escape.json"), "die Datei neben der Outbox bleibt unerreichbar")
            XCTAssertNil(sdk.resolveOutboxPath(recorded + "/.."))
            XCTAssertNil(sdk.resolveOutboxPath(recorded + "/."))
            XCTAssertNil(sdk.resolveOutboxPath(recorded + "/nested"), "ein Ordner ist keine Ladung")
            XCTAssertNil(sdk.resolveOutboxPath(""))
        }
    }
}
