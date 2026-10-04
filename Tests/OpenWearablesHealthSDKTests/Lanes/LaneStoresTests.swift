import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Speicher der Spuren (Plan 05-07): Cursor über die vorhandenen Anchor-Schlüssel, Nachholplan,
/// geparkte Datensätze und die Schalter in der Defaults-Suite.
final class LaneStoresTests: XCTestCase {

    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let weight = "HKQuantityTypeIdentifierBodyMass"
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func archived(_ rowId: Int) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: HKQueryAnchor(fromValue: rowId), requiringSecureCoding: true
        )
    }

    // MARK: Cursor-Speicher: dieselben Schlüssel wie 0.15, kein neues Format

    func testACommittedAnchorIsReadableThroughTheExistingLoadAnchor() throws {
        try withIsolatedDefaults { defaults in
            try withIsolatedSDK { sdk, _ in
                let store = sdk.makeCursorStore()
                let data = try archived(77)

                store.commit(data, for: heartRate)

                let loaded = sdk.loadAnchor(for: HKQuantityType(.heartRate))
                XCTAssertNotNil(loaded, "loadAnchor muss den Anchor des Cursor-Speichers lesen")
                let key = sdk.anchorKey(typeIdentifier: heartRate, userKey: sdk.userKey())
                XCTAssertEqual(defaults.data(forKey: key), data, "gleicher Schlüssel, gleiche Bytes")
                XCTAssertEqual(key, "anchor.user.test-user.HKQuantityTypeIdentifierHeartRate")
            }
        }
    }

    func testAnAnchorSavedByTheExistingSaveAnchorIsReadableThroughTheStore() throws {
        try withIsolatedDefaults { _ in
            try withIsolatedSDK { sdk, _ in
                let store = sdk.makeCursorStore()
                XCTAssertNil(store.anchor(for: weight))

                sdk.saveAnchor(HKQueryAnchor(fromValue: 12), for: HKQuantityType(.bodyMass))

                let data = try XCTUnwrap(store.anchor(for: weight))
                let anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
                XCTAssertNotNil(anchor)
                XCTAssertEqual(
                    data,
                    try NSKeyedArchiver.archivedData(
                        withRootObject: HKQueryAnchor(fromValue: 12), requiringSecureCoding: true
                    )
                )
            }
        }
    }

    func testTheCursorStoreWritesNothingElseIntoTheDefaults() throws {
        try withIsolatedDefaults { defaults in
            try withIsolatedSDK { sdk, _ in
                let before = Set(defaults.dictionaryRepresentation().keys)
                sdk.makeCursorStore().commit(try archived(5), for: heartRate)
                let added = Set(defaults.dictionaryRepresentation().keys).subtracting(before)
                XCTAssertEqual(added, ["anchor.user.test-user.HKQuantityTypeIdentifierHeartRate"])
            }
        }
    }

    func testTheCursorStoreKeepsTheUserOfTheCycleItWasBuiltFor() throws {
        try withIsolatedDefaults { defaults in
            try withIsolatedSDK { sdk, _ in
                let store = sdk.makeCursorStore()
                let data = try archived(9)
                store.commit(data, for: heartRate)

                // Das Konto wechselt mitten im Zyklus: der Spurenspeicher schreibt nicht in das neue.
                OpenWearablesHealthSdkKeychain.saveCredentials(
                    userId: "anderer-user", accessToken: "a", refreshToken: "r"
                )
                store.commit(try archived(10), for: heartRate)

                XCTAssertNil(defaults.data(forKey: "anchor.user.anderer-user.\(heartRate)"))
                XCTAssertNotNil(defaults.data(forKey: "anchor.user.test-user.\(heartRate)"))
            }
        }
    }

    // MARK: Nachholplan

    func testTheBackfillStoreRoundTripsAPlanUnchangedIncludingSubMillisecondTimes() throws {
        try withIsolatedSDK { sdk, _ in
            let store = sdk.makeBackfillStore()
            var plan = BackfillPlan.empty()
            let now = Date(timeIntervalSince1970: 1_790_000_000.123_456)
            plan.start(typeId: heartRate, now: now, daysBack: 14, origin: "bootstrap")
            plan.advance(
                typeId: heartRate, to: now.addingTimeInterval(-3600.000_321), boundaryIds: ["u1", "u2"]
            )
            plan.start(typeId: weight, now: now, daysBack: 14, origin: "reload")
            plan.markDone(typeId: weight)
            plan.rejections["\(heartRate)@backfill"] = RejectionState(consecutive: 2, limit: 50, lastStatus: 422)

            try store.save(plan)

            XCTAssertEqual(sdk.makeBackfillStore().load(), plan)
        }
    }

    func testTheBackfillStoreWritesThePlanThroughThePlansOwnEncoder() throws {
        try withIsolatedSDK { sdk, directory in
            var plan = BackfillPlan.empty()
            plan.start(typeId: heartRate, now: epoch.addingTimeInterval(0.000_4), daysBack: 14, origin: "bootstrap")

            try sdk.makeBackfillStore().save(plan)

            let file = directory.appendingPathComponent("health_lanes/backfill.json")
            XCTAssertEqual(try Data(contentsOf: file), try plan.encoded())
        }
    }

    func testAMissingBackfillFileIsAnEmptyPlan() {
        withIsolatedSDK { sdk, _ in
            let plan = sdk.makeBackfillStore().load()
            XCTAssertTrue(plan.entries.isEmpty)
            XCTAssertTrue(plan.rejections.isEmpty)
            XCTAssertEqual(plan.version, BackfillPlan.currentVersion)
        }
    }

    func testTheSessionIdOfTheFileSurvivesALaterLoad() throws {
        try withIsolatedSDK { sdk, _ in
            let plan = BackfillPlan.empty()
            try sdk.makeBackfillStore().save(plan)
            XCTAssertEqual(sdk.makeBackfillStore().load().sessionId, plan.sessionId)
        }
    }

    func testACorruptBackfillFileIsMovedAsideAndTheContentSurvives() throws {
        try withIsolatedSDK { sdk, directory in
            let folder = directory.appendingPathComponent("health_lanes", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let garbage = Data("{\"entries\": kaputt".utf8)
            try garbage.write(to: folder.appendingPathComponent("backfill.json"))

            let plan = sdk.makeBackfillStore().load()
            XCTAssertTrue(plan.entries.isEmpty)

            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            let asides = names.filter { $0.hasPrefix("backfill.json.corrupt-") }
            XCTAssertEqual(asides.count, 1, "\(names)")
            guard let aside = asides.first else { return }
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(aside)), garbage)
            XCTAssertFalse(names.contains("backfill.json"), "die kaputte Datei liegt nicht mehr unter dem Namen")
        }
    }

    /// `save` ohne vorheriges `load`: eine beschädigte Datei wird trotzdem nie unbemerkt ersetzt.
    func testSavingOverACorruptFileKeepsItsContentAsideEvenWithoutAPriorLoad() throws {
        try withIsolatedSDK { sdk, directory in
            let folder = directory.appendingPathComponent("health_lanes", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let garbage = Data("kaputt".utf8)
            try garbage.write(to: folder.appendingPathComponent("backfill.json"))

            var plan = BackfillPlan.empty()
            plan.start(typeId: heartRate, now: epoch, daysBack: 14, origin: "bootstrap")
            try sdk.makeBackfillStore().save(plan)

            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            let asides = names.filter { $0.hasPrefix("backfill.json.corrupt-") }
            XCTAssertEqual(asides.count, 1, "\(names)")
            guard let aside = asides.first else { return }
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(aside)), garbage)
            XCTAssertEqual(sdk.makeBackfillStore().load(), plan)
        }
    }

    /// Eine Datei, die da ist, sich aber nicht lesen lässt, ist nicht beschädigt. Sie bleibt, und
    /// `save` überschreibt sie nicht mit einem Plan, der den echten Stand nicht kennt.
    func testAnUnreadableBackfillFileIsNeverOverwritten() throws {
        try withIsolatedSDK { sdk, directory in
            var plan = BackfillPlan.empty()
            plan.start(typeId: heartRate, now: epoch, daysBack: 14, origin: "bootstrap")
            try sdk.makeBackfillStore().save(plan)

            let file = directory.appendingPathComponent("health_lanes/backfill.json")
            let before = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

            let store = sdk.makeBackfillStore()
            _ = store.load()
            XCTAssertThrowsError(try store.save(BackfillPlan.empty()), "darf den echten Plan nicht ersetzen")

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            XCTAssertEqual(try Data(contentsOf: file), before)
            let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            XCTAssertTrue(names.filter { $0.contains("corrupt") }.isEmpty, "\(names)")
        }
    }

    // MARK: Mehrere Schreiber (Review HI-01, ME-04, LO-07)

    /// Ein Speicher, der seit seinem `load` einen fremden Stand verpasst hat, darf die Datei nicht
    /// mit seinem alten Stand ersetzen: der fremde Eintrag ginge still verloren.
    func testSavingAStalePlanOverAnotherWritersChangeIsRefusedAsAConflict() throws {
        try withIsolatedSDK { sdk, _ in
            let first = sdk.makeBackfillStore()
            var stale = first.load()

            let second = sdk.makeBackfillStore()
            var other = second.load()
            other.start(typeId: weight, now: epoch, daysBack: 14, origin: "request")
            try second.save(other)

            stale.start(typeId: heartRate, now: epoch, daysBack: 14, origin: "bootstrap")
            XCTAssertThrowsError(try first.save(stale)) { error in
                XCTAssertEqual(error as? FileBackfillStore.StoreError, .conflict)
            }
            XCTAssertNotNil(sdk.makeBackfillStore().load().entries[weight], "der fremde Eintrag bleibt")
        }
    }

    /// `update` setzt die eigene Änderung auf den Stand, den ein anderer Schreiber inzwischen
    /// gespeichert hat, und liefert den geschriebenen Plan.
    func testUpdateAppliesTheChangeOnTopOfWhatAnotherWriterSaved() throws {
        try withIsolatedSDK { sdk, _ in
            let first = sdk.makeBackfillStore()
            _ = first.load()

            try sdk.makeBackfillStore().update {
                $0.start(typeId: weight, now: epoch, daysBack: 14, origin: "request")
            }
            let written = try first.update {
                $0.start(typeId: heartRate, now: epoch, daysBack: 14, origin: "bootstrap")
            }

            XCTAssertEqual(Set(written.entries.keys), [heartRate, weight])
            XCTAssertEqual(sdk.makeBackfillStore().load(), written)
            // Nach dem eigenen Schreiben ist der Stand bekannt: ein `save` darauf ist kein Konflikt.
            var next = written
            next.markDone(typeId: weight)
            XCTAssertNoThrow(try first.save(next))
        }
    }

    /// Je Datei eine Sperre für den ganzen Prozess, nicht je Instanz: zwei Instanzen, die
    /// gleichzeitig schreiben, verlieren keinen Eintrag.
    func testConcurrentUpdatesFromSeparateInstancesLoseNothing() throws {
        try withIsolatedSDK { sdk, _ in
            let stores = [sdk.makeBackfillStore(), sdk.makeBackfillStore()]
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                _ = try? stores[index % 2].update {
                    $0.start(typeId: "Type\(index)", now: self.epoch, daysBack: 14, origin: "request")
                }
            }
            XCTAssertEqual(sdk.makeBackfillStore().load().entries.count, 40)
        }
    }

    // MARK: Geparkte Datensätze

    func testParkingWritesOneFileWithTheFieldsAndTheRecord() throws {
        try withIsolatedSDK { sdk, directory in
            let record = Data(#"{"data":{"records":[{"id":"u-1","value":7.5}]}}"#.utf8)

            try sdk.makeRejectionParking().park(typeId: weight, itemId: "u-1", httpStatus: 422, record: record)

            let folder = directory.appendingPathComponent("health_rejected", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertEqual(names, ["\(weight)-u-1.json"])
            guard let name = names.first else { return }
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["typeId"] as? String, weight)
            XCTAssertEqual(json["itemId"] as? String, "u-1")
            XCTAssertEqual(json["httpStatus"] as? Int, 422)
            XCTAssertNotNil(json["parkedAt"] as? String)
            let parsed = try XCTUnwrap(json["record"] as? [String: Any])
            XCTAssertNotNil(parsed["data"])
        }
    }

    func testParkingWithoutARecordStillLeavesAFile() throws {
        try withIsolatedSDK { sdk, directory in
            try sdk.makeRejectionParking().park(typeId: weight, itemId: "u-2", httpStatus: 400, record: nil)
            let folder = directory.appendingPathComponent("health_rejected", isDirectory: true)
            let data = try Data(contentsOf: folder.appendingPathComponent("\(weight)-u-2.json"))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["httpStatus"] as? Int, 400)
            XCTAssertTrue(json["record"] is NSNull)
        }
    }

    func testParkingTheSameItemTwiceKeepsBothFiles() throws {
        try withIsolatedSDK { sdk, directory in
            let parking = sdk.makeRejectionParking()
            try parking.park(typeId: weight, itemId: "u-3", httpStatus: 422, record: nil)
            try parking.park(typeId: weight, itemId: "u-3", httpStatus: 400, record: nil)

            let folder = directory.appendingPathComponent("health_rejected", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            XCTAssertEqual(names.count, 2, "\(names)")
            let statuses = try names.map { name -> Int in
                let data = try Data(contentsOf: folder.appendingPathComponent(name))
                let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                return try XCTUnwrap(json["httpStatus"] as? Int)
            }
            XCTAssertEqual(Set(statuses), [422, 400])
        }
    }

    func testParkingNeverLetsAnIdLeaveTheFolder() throws {
        try withIsolatedSDK { sdk, directory in
            try sdk.makeRejectionParking().park(typeId: "../../x", itemId: "../evil/id", httpStatus: 422, record: nil)

            let folder = directory.appendingPathComponent("health_rejected", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertEqual(names.count, 1, "\(names)")
            // Ein Pfad, der aus dem Ordner herausführt, landet im Elternordner des Test-Verzeichnisses.
            let outside = directory.deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("x-..").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("evil").path))
            guard names.count == 1 else { return }
            XCTAssertFalse(names[0].contains("/"))
        }
    }

    // MARK: Uhr

    func testTheSystemClockTellsTheTime() {
        let before = Date()
        let now = SystemLaneClock().now()
        XCTAssertGreaterThanOrEqual(now, before)
        XCTAssertLessThan(now.timeIntervalSince(before), 5)
    }

    // MARK: Schalter

    func testTheSwitchesDefaultToOff() {
        withIsolatedDefaults { _ in
            let sdk = OpenWearablesHealthSDK.shared
            XCTAssertFalse(sdk.lanesSendDeletions, "Railway bekommt deleted nur, wenn der Schalter an ist")
            XCTAssertFalse(sdk.lanesAnchorProbe)
            XCTAssertFalse(sdk.lanesNeedsCatchUp)
        }
    }

    func testTheSwitchesUseTheDocumentedKeys() {
        withIsolatedDefaults { defaults in
            let sdk = OpenWearablesHealthSDK.shared

            sdk.lanesSendDeletions = true
            sdk.lanesAnchorProbe = true
            sdk.lanesNeedsCatchUp = true

            XCTAssertEqual(defaults.object(forKey: "lanes.sendDeletions") as? Bool, true)
            XCTAssertEqual(defaults.object(forKey: "lanes.anchorProbe") as? Bool, true)
            XCTAssertEqual(defaults.object(forKey: "lanes.needsCatchUp") as? Bool, true)

            sdk.lanesSendDeletions = false
            XCTAssertFalse(sdk.lanesSendDeletions)
            XCTAssertEqual(defaults.object(forKey: "lanes.sendDeletions") as? Bool, false)
        }
    }

    func testTheSwitchIsReadOnEveryAccessNotCached() {
        withIsolatedDefaults { defaults in
            let sdk = OpenWearablesHealthSDK.shared
            XCTAssertFalse(sdk.lanesSendDeletions)
            defaults.set(true, forKey: "lanes.sendDeletions")
            XCTAssertTrue(sdk.lanesSendDeletions)
        }
    }

    // MARK: Fabriken

    func testTheFactoriesPointAtTheFoldersOfTheContainerContract() throws {
        try withIsolatedSDK { sdk, directory in
            try sdk.makeDeletionQueue().enqueue([DeletedRef(id: "d-1", type: weight)], sentAt: nil)
            try sdk.makeBackfillStore().save(BackfillPlan.empty())
            try sdk.makeRejectionParking().park(typeId: weight, itemId: "p-1", httpStatus: 422, record: nil)

            let fm = FileManager.default
            XCTAssertTrue(fm.fileExists(atPath: directory.appendingPathComponent("health_deletions/queue.json").path))
            XCTAssertTrue(fm.fileExists(atPath: directory.appendingPathComponent("health_lanes/backfill.json").path))
            XCTAssertTrue(fm.fileExists(atPath: directory.appendingPathComponent("health_rejected").path))
        }
    }

    func testTheFactoryQueueUsesTheDecidedCaps() throws {
        try withIsolatedSDK { sdk, _ in
            let queue = sdk.makeDeletionQueue()
            XCTAssertEqual(queue.maxEntries, 50_000)
            XCTAssertEqual(queue.maxAge, 90 * 24 * 3600)
        }
    }
}
