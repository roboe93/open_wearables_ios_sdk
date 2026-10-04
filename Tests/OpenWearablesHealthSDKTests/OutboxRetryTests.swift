import XCTest
@testable import OpenWearablesHealthSDK

/// Covers the outbox drain that carries leftovers from pre-0.14 installs: which items
/// are replayed, which are dropped, and the guard that stops two overlapping passes from
/// sending the same item twice. See issue #34.
final class OutboxRetryTests: XCTestCase {

    private struct Leftover {
        let item: URL
        let payload: URL

        var itemExists: Bool { FileManager.default.fileExists(atPath: item.path) }
        var payloadExists: Bool { FileManager.default.fileExists(atPath: payload.path) }
    }

    /// Writes an outbox item the way a pre-0.14 SDK would have left it. `age` is applied
    /// to the item file, which is what the drain reads to decide an item's fate.
    private func writeLeftover(in stateDirectory: URL, withPayload: Bool, age: TimeInterval) -> Leftover {
        let id = UUID().uuidString
        let directory = stateDirectory.appendingPathComponent("health_outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let payloadURL = directory.appendingPathComponent("combined_payload_\(id).json")
        if withPayload {
            try? Data(#"{"provider":"apple","data":{}}"#.utf8).write(to: payloadURL)
        }

        let item = OpenWearablesHealthSDK.OutboxItem(
            typeIdentifier: "combined",
            userKey: "user.test-user",
            payloadPath: payloadURL.path,
            anchorPath: nil,
            wasFullExport: false
        )
        let itemURL = directory.appendingPathComponent("combined_item_\(id).json")
        try? JSONEncoder().encode(item).write(to: itemURL)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: itemURL.path
        )

        return Leftover(item: itemURL, payload: payloadURL)
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
}
