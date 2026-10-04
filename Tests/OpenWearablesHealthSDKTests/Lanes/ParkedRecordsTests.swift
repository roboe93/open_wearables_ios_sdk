import XCTest
@testable import OpenWearablesHealthSDK

/// Geparkte Datensätze bleiben sichtbar und lassen sich erneut senden (Review HI-02). Abgelegt ist
/// nie verworfen: was der Server angenommen hat, wandert nach `health_rejected/replayed/`, nichts
/// wird gelöscht.
final class ParkedRecordsTests: XCTestCase {

    private let weight = "HKQuantityTypeIdentifierBodyMass"

    private func record(_ id: String) -> Data {
        Data(#"{"data":{"records":[{"id":"\#(id)","type":"HKQuantityTypeIdentifierBodyMass"}]},"syncType":"live"}"#.utf8)
    }

    private func park(_ sdk: OpenWearablesHealthSDK, _ ids: [String], status: Int = 422) throws {
        for id in ids {
            try sdk.makeRejectionParking().park(typeId: weight, itemId: id, httpStatus: status, record: record(id))
        }
    }

    private func replay(_ sdk: OpenWearablesHealthSDK, file: StaticString = #filePath, line: UInt = #line) -> ParkedReplayResult? {
        var result: ParkedReplayResult?
        sdk.replayParked { result = $0 }
        if !waitUntil(timeout: 5, { result != nil }) { XCTFail("keine Antwort", file: file, line: line) }
        return result
    }

    private func sentIds() -> [String] {
        StubURLProtocol.recorded(matching: "/sync").compactMap { recorded in
            let data = recorded.json?["data"] as? [String: Any]
            return (data?["records"] as? [[String: Any]])?.first?["id"] as? String
        }
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    func testTheSyncStatusCountsParkedRecords() throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                XCTAssertEqual(sdk.parkedRecordCount, 0)
                try park(sdk, ["a", "b"])

                XCTAssertEqual(sdk.parkedRecordCount, 2)
                XCTAssertEqual(sdk.getSyncStatusDict()["parkedRecords"] as? Int, 2)
            }
        }
    }

    func testReplayResendsParkedRecordsAndMovesTheAcceptedOnesAsideWithoutDeleting() throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: .lanes) { sdk, directory in
                try park(sdk, ["a", "b"])
                StubURLProtocol.install { _ in .status(202) }

                let result = replay(sdk)

                XCTAssertEqual(result, ParkedReplayResult(resent: 2, stillRejected: 0, remaining: 0, failure: nil))
                XCTAssertEqual(Set(sentIds()), ["a", "b"], "gesendet wird der abgelegte Datensatz")
                XCTAssertEqual(sdk.parkedRecordCount, 0)
                let folder = directory.appendingPathComponent("health_rejected", isDirectory: true)
                XCTAssertEqual(names(in: folder.appendingPathComponent("replayed", isDirectory: true)).count, 2, "beiseitegelegt, nicht gelöscht")
                XCTAssertFalse(sdk.isSyncInProgress, "der Slot ist wieder frei")
                XCTAssertTrue(sdk.journalEntries().contains { $0.kind == "parked" })
            }
        }
    }

    func testReplayKeepsRecordsTheServerStillRejects() throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                try park(sdk, ["a", "b"])
                StubURLProtocol.install { _ in .status(422) }

                let result = replay(sdk)

                XCTAssertEqual(result, ParkedReplayResult(resent: 0, stillRejected: 2, remaining: 0, failure: nil))
                XCTAssertEqual(sdk.parkedRecordCount, 2, "abgelehnt bleibt abgelegt")
            }
        }
    }

    func testReplayStopsAtAServerErrorAndKeepsTheRest() throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                try park(sdk, ["a", "b"])
                let lock = NSLock()
                var calls = 0
                StubURLProtocol.install { _ in
                    lock.lock()
                    calls += 1
                    let first = calls == 1
                    lock.unlock()
                    return first ? .status(202) : .status(503)
                }

                let result = replay(sdk)

                XCTAssertEqual(result?.resent, 1)
                XCTAssertEqual(result?.remaining, 1)
                XCTAssertEqual(result?.failure, "HTTP 503")
                XCTAssertEqual(sdk.parkedRecordCount, 1)
            }
        }
    }

    func testReplayWhileARunHoldsTheSlotDoesNothing() throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK(orchestration: .lanes) { sdk, _ in
                try park(sdk, ["a"])
                guard let holder = sdk.beginSyncRun() else { return XCTFail("Slot") }
                defer { sdk.finishSync(generation: holder) }
                StubURLProtocol.install { _ in .status(202) }

                let result = replay(sdk)

                XCTAssertEqual(result, ParkedReplayResult(resent: 0, stillRejected: 0, remaining: 1, failure: "busy"))
                XCTAssertTrue(StubURLProtocol.requests.isEmpty)
                XCTAssertEqual(sdk.parkedRecordCount, 1)
            }
        }
    }
}
