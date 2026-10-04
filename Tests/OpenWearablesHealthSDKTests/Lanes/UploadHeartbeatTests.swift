import XCTest
@testable import OpenWearablesHealthSDK

/// Lebenszeichen während eines Uploads (Review ME-02).
///
/// Die Sperre verfällt nach 150 Sekunden ohne Lebenszeichen. Ein Upload, der Daten bewegt, darf aber
/// bis zum Resource-Timeout von 600 Sekunden laufen (`timeoutIntervalForRequest` ist ein
/// Leerlauf-Timeout). Ohne Lebenszeichen am Upload übernahm der nächste Auslöser einen lebenden,
/// langsamen Upload, brach ihn ab und schickte dasselbe Paket wieder: ein Kreislauf ohne Fortschritt.
final class UploadHeartbeatTests: XCTestCase {

    private final class Box<Value> {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    func testABeatComesOnlyWhenBytesMoved() {
        let bytes = Box<Int64>(0)
        let running = Box(true)
        let beats = Box(0)
        let heartbeat = UploadProgressHeartbeat(
            interval: 60, progress: { (running.value, bytes.value) }, beat: { beats.value += 1 }
        )

        heartbeat.tick()
        XCTAssertEqual(beats.value, 0, "nichts bewegt, kein Lebenszeichen")

        bytes.value = 4_096
        heartbeat.tick()
        XCTAssertEqual(beats.value, 1)

        heartbeat.tick()
        XCTAssertEqual(beats.value, 1, "ein hängender Upload hält die Sperre nicht")

        bytes.value = 8_192
        heartbeat.tick()
        XCTAssertEqual(beats.value, 2)

        running.value = false
        bytes.value = 9_000
        heartbeat.tick()
        XCTAssertEqual(beats.value, 2, "ein beendeter Upload gibt kein Lebenszeichen mehr")
    }

    func testTheTimerBeatsWhileBytesMoveAndStopsWhenStopped() {
        let bytes = Box<Int64>(0)
        let beats = Box(0)
        let heartbeat = UploadProgressHeartbeat(
            interval: 0.02, progress: { (true, bytes.value) }, beat: { beats.value += 1 }
        )
        heartbeat.start()
        for step in 1...10 {
            bytes.value = Int64(step * 100)
            Thread.sleep(forTimeInterval: 0.03)
        }
        heartbeat.stop()
        let afterStop = beats.value
        XCTAssertGreaterThan(afterStop, 2)

        bytes.value = 99_999
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(beats.value, afterStop, "nach stop kommt nichts mehr")
    }

    /// Der echte Upload: ein langsamer Upload, der Bytes bewegt, verlängert die Sperre seines Laufs.
    func testASlowUploadThatKeepsMovingBytesExtendsTheLeaseOfItsRun() {
        withIsolatedSDK { sdk, _ in
            let previousInterval = OpenWearablesHealthSDK.uploadHeartbeatInterval
            OpenWearablesHealthSDK.uploadHeartbeatInterval = 0.05
            let t0 = Date(timeIntervalSince1970: 1_791_100_800)
            let clock = Box(t0)
            let previousNow = sdk.now
            sdk.now = { clock.value }
            defer {
                sdk.now = previousNow
                OpenWearablesHealthSDK.uploadHeartbeatInterval = previousInterval
            }

            guard let generation = sdk.beginSyncRun(), let endpoint = sdk.syncEndpoint else {
                return XCTFail("Slot oder Endpunkt fehlt")
            }
            defer { sdk.finishSync(generation: generation) }
            XCTAssertEqual(sdk.leaseDeadline, t0.addingTimeInterval(150))

            StubURLProtocol.install { _ in .trickle(202, chunks: 12, every: 0.05) }
            clock.value = t0.addingTimeInterval(140)

            var result: UploadResult?
            sdk.uploadCombinedPayloadReportingStatus(
                payload: ["data": ["records": []]], endpoint: endpoint, credential: "access-1", generation: generation
            ) { result = $0 }
            XCTAssertTrue(waitUntil(timeout: 5) { result != nil })

            XCTAssertEqual(result, .accepted(202))
            XCTAssertEqual(sdk.leaseDeadline, t0.addingTimeInterval(290), "das Lebenszeichen kam während des Uploads")
        }
    }
}
