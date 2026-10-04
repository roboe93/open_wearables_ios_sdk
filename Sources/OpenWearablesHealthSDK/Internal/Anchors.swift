import Foundation
import HealthKit

extension OpenWearablesHealthSDK {

    // MARK: - Keys (per-user)
    internal func userKey() -> String {
        guard let userId = userId, !userId.isEmpty else { return "user.none" }
        return "user.\(userId)"
    }

    internal func anchorKey(for type: HKSampleType) -> String {
        "anchor.\(userKey()).\(type.identifier)"
    }
    
    internal func fullDoneKey() -> String {
        "fullDone.\(userKey())"
    }

    internal func anchorKey(typeIdentifier: String, userKey: String) -> String {
        return "anchor.\(userKey).\(typeIdentifier)"
    }

    internal func saveAnchorData(_ data: Data, typeIdentifier: String, userKey: String) {
        defaults.set(data, forKey: anchorKey(typeIdentifier: typeIdentifier, userKey: userKey))
    }

    // MARK: - Anchors
    internal func loadAnchor(for type: HKSampleType) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: anchorKey(for: type)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    internal func saveAnchor(_ anchor: HKQueryAnchor, for type: HKSampleType) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            defaults.set(data, forKey: anchorKey(for: type))
        }
    }

    internal func resetAllAnchors() {
        for t in trackedTypes {
            defaults.removeObject(forKey: anchorKey(for: t))
        }
        defaults.set(false, forKey: fullDoneKey())
    }

    // MARK: - Initial sync
    internal func initialSyncKickoff(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            logMessage("HealthKit not available")
            completion(false)
            return
        }
        
        guard syncEndpoint != nil, hasAuth else {
            logMessage("No endpoint or auth credential")
            completion(false)
            return
        }
        
        guard !trackedTypes.isEmpty else {
            logMessage("No tracked types")
            completion(false)
            return
        }
        
        // Fork (Plan 05-08): in lanes mode the start is a cycle like any other. Types without an
        // anchor get their anchor for now and a backfill; there is no initial export that
        // would set `isInitialSyncInProgress` and hold new data back.
        if orchestration == .lanes {
            logMessage("Lanes sync kickoff")
            syncAll(fullExport: false, trigger: .kickoff, completion: { _ in completion(true) })
            return
        }
        
        let fullDone = isInitialExportDone()
        if fullDone {
            logMessage("Incremental sync")
            syncAll(fullExport: false, trigger: .kickoff, completion: { _ in completion(true) })
        } else {
            logMessage("Full export")
            isInitialSyncInProgress = true
            syncAll(fullExport: true, trigger: .kickoff, completion: { _ in completion(true) })
        }
    }
}
