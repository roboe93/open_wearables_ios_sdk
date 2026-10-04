import XCTest
@testable import OpenWearablesHealthSDK

/// Covers the two fields the backend already consumes to group batches into a SyncRun:
/// `syncSessionId` (logs + sync) and `syncType` (sync only). See issue #41.
final class SyncSessionTrackingTests: XCTestCase {

    /// A state file from before `sessionId` existed must still load, then get an id
    /// on the next attribution so a mid-upgrade resume does not start a second run.
    private struct LegacySyncState: Codable {
        let userKey: String
        let fullExport: Bool
        let createdAt: Date
        let typeProgress: [String: TypeSyncProgress]
        let totalSentCount: Int
        let completedTypes: Set<String>
        let currentTypeIndex: Int
    }

    func testHistoricalSessionIsTaggedHistoricalAndKeepsItsId() {
        withIsolatedSDK { sdk, _ in
            let first = sdk.startNewSyncState(fullExport: true, types: [])
            XCTAssertNotNil(first.sessionId)
            XCTAssertEqual(first.syncType, "historical")

            let again = sdk.currentSyncAttribution()
            XCTAssertEqual(again?.sessionId, first.sessionId)
            XCTAssertEqual(again?.syncType, "historical")
        }
    }

    func testLiveSessionIsTaggedLive() {
        withIsolatedSDK { sdk, _ in
            _ = sdk.startNewSyncState(fullExport: false, types: [])
            XCTAssertEqual(sdk.currentSyncAttribution()?.syncType, "live")
        }
    }

    func testANewSessionGetsANewId() {
        withIsolatedSDK { sdk, _ in
            let first = sdk.startNewSyncState(fullExport: true, types: []).sessionId
            let second = sdk.startNewSyncState(fullExport: true, types: []).sessionId
            XCTAssertNotEqual(first, second)
        }
    }

    func testStateWrittenBeforeSessionIdStillDecodesAndGetsOne() {
        withIsolatedSDK { sdk, _ in
            let legacy = LegacySyncState(
                userKey: "user.test-user",
                fullExport: true,
                createdAt: Date(),
                typeProgress: [:],
                totalSentCount: 0,
                completedTypes: [],
                currentTypeIndex: 0
            )
            sdk.ensureSyncStateDir()
            try? JSONEncoder().encode(legacy).write(to: sdk.syncStateFilePath(), options: .atomic)

            XCTAssertNil(sdk.loadSyncState()?.sessionId)

            let attribution = sdk.currentSyncAttribution()
            XCTAssertNotNil(attribution?.sessionId)
            XCTAssertEqual(attribution?.syncType, "historical")
            XCTAssertEqual(sdk.loadSyncState()?.sessionId, attribution?.sessionId)
        }
    }

    func testSyncPayloadCarriesSessionIdAndType() {
        withIsolatedSDK { sdk, _ in
            let state = sdk.startNewSyncState(fullExport: true, types: [])
            let payload = sdk.buildCombinedPayload(samples: [])

            XCTAssertEqual(payload["syncSessionId"] as? String, state.sessionId)
            XCTAssertEqual(payload["syncType"] as? String, "historical")
        }
    }

    /// Logs open the SyncRun. They get `syncSessionId` because that is on the schema;
    /// `syncType` is not, so it must stay off the body.
    func testLogBodyCarriesSessionIdAndOmitsSyncType() {
        withIsolatedSDK { sdk, _ in
            let state = sdk.startNewSyncState(fullExport: true, types: [])
            StubURLProtocol.install { _ in .status(202) }

            var finished = false
            sdk.sendSyncStartLog(types: [], typeCounts: [:], startDate: nil, endDate: Date()) {
                finished = true
            }
            XCTAssertTrue(waitUntil { finished })

            let logs = StubURLProtocol.recorded(matching: "/logs")
            XCTAssertEqual(logs.count, 1)
            XCTAssertEqual(logs.first?.json?["syncSessionId"] as? String, state.sessionId)
            XCTAssertNil(logs.first?.json?["syncType"])
        }
    }
}
