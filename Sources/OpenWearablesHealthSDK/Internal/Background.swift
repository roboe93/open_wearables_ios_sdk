import Foundation
import UIKit
import HealthKit
import BackgroundTasks

extension OpenWearablesHealthSDK {

    // MARK: - Background delivery
    internal func startBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()

        let observableTypes = getQueryableTypes()
        let deliveryGroup = DispatchGroup()
        let deliveryTally = DeliveryTally()

        for type in observableTypes {
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self = self else {
                    completionHandler()
                    return
                }

                if let error = error {
                    print("Observer error for \(type.identifier): \(error.localizedDescription)")
                    completionHandler()
                    return
                }

                // Fork (Plan 05-08), observer contract: in lanes mode the completion is wrapped in a
                // `OneShot` (LaneControls.swift) and comes after the live round, at the latest after
                // 20 s, exactly once. In upstream mode it comes right away as before. HealthKit
                // throttles the delivery when the completion stays out three times; it used to come
                // before any work was done.
                self.handleObserverWake(typeIdentifier: type.identifier, completionHandler: completionHandler)
            }
            healthStore.execute(observer)
            activeObserverQueries.append(observer)
            // Fork: the answer per type is the proof that background delivery is active at
            // all (Befund 10). One journal line for all types, not 52.
            deliveryGroup.enter()
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { [weak self] success, error in
                let ok = success && error == nil
                deliveryTally.record(shortName: self?.shortTypeName(type.identifier) ?? type.identifier, success: ok)
                deliveryGroup.leave()
            }
        }
        deliveryGroup.notify(queue: .global(qos: .utility)) { [weak self] in
            self?.runJournal.record(SyncJournalEntry(
                at: Date(), kind: JournalKind.delivery, note: deliveryTally.note
            ))
        }
        logMessage("Background observers registered for \(observableTypes.count) types")
    }

    internal func stopBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()
        
        let observableTypes = getQueryableTypes()
        
        for t in observableTypes {
            healthStore.disableBackgroundDelivery(for: t) { _, _ in }
        }
        logMessage("Background observers stopped")
    }

    // MARK: - BGTaskScheduler
    internal func scheduleAppRefresh() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(req)
            logMessage("Scheduled app refresh task")
        }
        catch {
            logMessage("scheduleAppRefresh error: \(error.localizedDescription)")
        }
    }

    internal func scheduleProcessing() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGProcessingTaskRequest(identifier: processTaskId)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(req)
            logMessage("Scheduled processing task")
        }
        catch {
            logMessage("scheduleProcessing error: \(error.localizedDescription)")
        }
    }

    internal func cancelAllBGTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            logMessage("Cancelled all background tasks")
        }
    }

    // Fork (Plan 05-09): the two SDK-owned BGTask handlers share `runSDKBackgroundTask` in
    // `Lanes/BackgroundTaskBudget.swift`. In upstream mode it behaves exactly like the bodies of
    // 0.15 (no deadline, waits of 20 s and 25 s, `setTaskCompleted` when the run is back). In lanes
    // mode the cycle gets a deadline from the task's time budget, so it cannot outlive the
    // background time iOS grants (a terminated app is a silent outage).
    @available(iOS 13.0, *)
    internal func handleAppRefresh(task: BGAppRefreshTask) {
        journalWake(trigger: SyncTrigger.sdkRefresh.journalValue, note: nil)
        scheduleAppRefresh()
        runSDKBackgroundTask(task, kind: .refresh)
    }

    @available(iOS 13.0, *)
    internal func handleProcessing(task: BGProcessingTask) {
        journalWake(trigger: SyncTrigger.sdkProcessing.journalValue, note: nil)
        scheduleProcessing()
        runSDKBackgroundTask(task, kind: .processing)
    }
}
