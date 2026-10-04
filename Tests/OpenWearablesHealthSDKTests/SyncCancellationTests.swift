import XCTest
@testable import OpenWearablesHealthSDK

/// Covers the run-generation rules that keep two sync loops from writing the same
/// `SyncState`, and the upload tracking that keeps cancellation from tearing down
/// unrelated requests on the shared foreground session. See issue #34.
final class SyncCancellationTests: XCTestCase {

    func testSecondRunCannotClaimTheSlotWhileTheFirstIsLive() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("The first run should claim the slot")
            }
            defer { sdk.finishSync(generation: generation) }

            XCTAssertNil(sdk.beginSyncRun(), "a second run must not start on top of a live one")
            XCTAssertTrue(sdk.isSyncInProgress)
        }
    }

    /// Cancelling stops the run logically and immediately, but the slot stays held until
    /// the loop actually unwinds, so nothing else can start mid-teardown.
    func testCancelMarksTheRunCancelledAndKeepsTheSlotUntilItUnwinds() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            XCTAssertFalse(sdk.isSyncCancelled(generation: generation))

            sdk.cancelSync()

            XCTAssertTrue(sdk.isSyncCancelled(generation: generation))
            XCTAssertTrue(sdk.isSyncInProgress, "the slot is released by the loop, not by cancel")
            XCTAssertFalse(sdk.isSyncingVisible, "callers should already see the sync as stopped")

            sdk.finishSync(generation: generation)
            XCTAssertFalse(sdk.isSyncInProgress)
        }
    }

    func testFinishFromASupersededRunDoesNotReleaseTheLiveSlot() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            defer { sdk.finishSync(generation: generation) }

            sdk.finishSync(generation: generation - 1)

            XCTAssertTrue(sdk.isSyncInProgress, "an older run must not release a live run's slot")
        }
    }

    /// Cancellation targets only the uploads the sync owns. A token refresh sharing the
    /// same foreground session has to survive it, otherwise cancelling a round would
    /// also kill the refresh that the next round depends on.
    func testCancellingUploadsLeavesUntrackedRequestsAlone() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .hang }
            guard let endpoint = sdk.syncEndpoint else {
                return XCTFail("No sync endpoint")
            }

            let ownedBySync = sdk.foregroundSession.dataTask(with: endpoint)
            let unrelated = sdk.foregroundSession.dataTask(with: endpoint)
            ownedBySync.resume()
            unrelated.resume()
            sdk.trackSyncUpload(ownedBySync, requestId: "owned")

            sdk.cancelInFlightSyncUploads(reason: "cancelSync")

            XCTAssertTrue(waitUntil { ownedBySync.state != .running })
            XCTAssertEqual(unrelated.state, .running)
            XCTAssertEqual(sdk.cancellationAttribution(), "cancelSync")

            unrelated.cancel()
            _ = sdk.untrackSyncUpload(requestId: "owned")
        }
    }
}
