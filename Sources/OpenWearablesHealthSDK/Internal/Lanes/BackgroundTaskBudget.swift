import Foundation
import BackgroundTasks

// Fork-Zusatz (roboe93), Plan 05-09 (vom Orchestrator verlangt), bewusst in einer eigenen Datei,
// damit `Background.swift` nah am Original bleibt.
//
// Warum es das gibt: Die SDK-eigenen BGTasks riefen den Zyklus mit `deadline: nil`. Im Original-
// Ablauf war das harmlos, weil jeder Lauf ohnehin über die Hintergrundzeit wacht
// (`backgroundTimeRemaining`). Der Zwei-Spuren-Zyklus tut das nicht: ohne Frist kann er länger
// laufen als die Zeit, die iOS dem Task gibt, und iOS beendet die App. Das ist ein stiller
// Ausfall, genau das, was die Phase verhindern soll. Im Modus lanes bekommt der Zyklus deshalb
// eine Frist aus dem Zeitrahmen seines Tasks, die der Kern an jeder Prüfstelle (vor dem nächsten
// Abruf, der nächsten Lieferung, dem nächsten Chunk) beachtet.

/// Welcher SDK-eigene BGTask läuft.
enum BackgroundTaskKind {
    case refresh
    case processing

    var trigger: SyncTrigger {
        switch self {
        case .refresh: return .sdkRefresh
        case .processing: return .sdkProcessing
        }
    }

    /// Wie die Logzeilen im Original heißen (`BGAppRefresh sync timed out` ...).
    var label: String {
        switch self {
        case .refresh: return "BGAppRefresh"
        case .processing: return "BGProcessing"
        }
    }
}

/// Der Zeitrahmen eines Tasks: Frist für den Zyklus, Wartegrenze des Handlers und die Gnadenfrist
/// nach dem Ablauf der Zeit.
struct BackgroundTaskBudget: Equatable {

    /// Frist für den Zyklus. `nil`: keine, wie im Original-Ablauf.
    let deadline: Date?
    /// So lange wartet der Handler höchstens auf das Ende des Zyklus, danach gibt er den Task zurück.
    let waitCap: TimeInterval
    /// Nur im Modus lanes: so lange darf der Zyklus nach dem Ablauf der Zeit (`expirationHandler`)
    /// noch von selbst enden, danach wird der Task zurückgegeben, auch wenn er hängt. `nil`: der
    /// Task endet erst, wenn der Lauf zurück ist oder die Wartegrenze greift, wie im Original.
    let expirationGrace: TimeInterval?

    // Modus lanes.
    //
    // `BGAppRefreshTask` bekommt rund 30 s. Die Frist wird vor dem nächsten Abruf oder Upload
    // geprüft; der gerade laufende (im Hintergrund ein Chunk von 100 Datensätzen) endet danach
    // noch von selbst oder wird vom Ablauf-Handler abgebrochen. 25 s lassen dafür Luft, die
    // Wartegrenze 28 s liegt unter dem Ende der Zeit. Das ist eine Annahme, am Gerät mit dem
    // Journal (`run` mit `partial:budget`) nachzumessen.
    //
    // `BGProcessingTask` bekommt Minuten, aber ohne Zusage: 5 Minuten sind der vorsichtige Wert,
    // der Ablauf-Handler bleibt die Sicherung, wenn iOS früher abbricht.
    static let lanesRefreshDeadline: TimeInterval = 25
    static let lanesRefreshWaitCap: TimeInterval = 28
    static let lanesProcessingDeadline: TimeInterval = 300
    static let lanesProcessingWaitCap: TimeInterval = 310
    static let lanesExpirationGrace: TimeInterval = 2

    // Original-Ablauf (0.15): keine Frist, Wartegrenzen wie im Original.
    static let upstreamRefreshWaitCap: TimeInterval = 20
    static let upstreamProcessingWaitCap: TimeInterval = 25

    static func make(
        kind: BackgroundTaskKind, orchestration: SyncOrchestration, started: Date
    ) -> BackgroundTaskBudget {
        switch (orchestration, kind) {
        case (.upstream, .refresh):
            return BackgroundTaskBudget(deadline: nil, waitCap: upstreamRefreshWaitCap, expirationGrace: nil)
        case (.upstream, .processing):
            return BackgroundTaskBudget(deadline: nil, waitCap: upstreamProcessingWaitCap, expirationGrace: nil)
        case (.lanes, .refresh):
            return BackgroundTaskBudget(
                deadline: started.addingTimeInterval(lanesRefreshDeadline),
                waitCap: lanesRefreshWaitCap, expirationGrace: lanesExpirationGrace
            )
        case (.lanes, .processing):
            return BackgroundTaskBudget(
                deadline: started.addingTimeInterval(lanesProcessingDeadline),
                waitCap: lanesProcessingWaitCap, expirationGrace: lanesExpirationGrace
            )
        }
    }
}

/// Das, was der Handler vom BGTask braucht. Der echte `BGTask` lässt sich im Test nicht erzeugen.
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

@available(iOS 13.0, *)
extension BGTask: BackgroundTaskHandle {}

/// Startet einen Zyklus für einen Auslöser mit einer Frist. Testnaht für `runSDKBackgroundTask`.
typealias BackgroundCollect = (
    _ trigger: SyncTrigger, _ deadline: Date?, _ completion: @escaping (SyncOutcome) -> Void
) -> Void

extension OpenWearablesHealthSDK {

    /// Der gemeinsame Rumpf von `handleAppRefresh` und `handleProcessing`.
    ///
    /// Modus upstream: wie im Original. Keine Frist, der Handler wartet 20 s (Refresh) beziehungsweise
    /// 25 s (Processing) und gibt den Task zurück, sobald der Lauf zurück ist oder die Wartegrenze
    /// greift; läuft die Zeit ab, werden die Uploads abgebrochen, und der Task endet, wenn der
    /// Lauf zurückkommt.
    ///
    /// Modus lanes: der Zyklus bekommt eine Frist aus dem Zeitrahmen des Tasks. Läuft die Zeit ab,
    /// werden die Uploads abgebrochen und der Zyklus hat noch einen Moment (`expirationGrace`), von
    /// selbst zu enden und sein Ergebnis ins Journal zu schreiben; hängt er in einer HealthKit-
    /// Abfrage, die kein Abbruch erreicht, wird der Task trotzdem zurückgegeben. Sonst hielte ein
    /// Handler, der bis zu 5 Minuten wartet, den Task über das Ende der Zeit hinaus, und iOS
    /// beendete die App.
    ///
    /// In beiden Modi ruft der Handler `setTaskCompleted` genau einmal auf (über das Ende der
    /// Operation) und beendet das Warten genau einmal (`OneShot`), egal ob der Zyklus doppelt
    /// zurückmeldet oder zu spät.
    ///
    /// - Parameters:
    ///   - budget: Testnaht. Vorgabe ist `BackgroundTaskBudget.make` für den Modus zum Zeitpunkt des Aufrufs.
    ///   - collect: Testnaht. Vorgabe ist `collectAllData` als Hintergrundlauf.
    internal func runSDKBackgroundTask(
        _ task: BackgroundTaskHandle,
        kind: BackgroundTaskKind,
        budget: BackgroundTaskBudget? = nil,
        collect: BackgroundCollect? = nil
    ) {
        let budget = budget ?? BackgroundTaskBudget.make(
            kind: kind, orchestration: orchestration, started: Date()
        )
        let collect: BackgroundCollect = collect ?? { [self] trigger, deadline, completion in
            collectAllData(
                fullExport: false, isBackground: true, trigger: trigger,
                deadline: deadline, completion: completion
            )
        }

        let group = DispatchGroup()
        group.enter()
        // Genau ein `leave`: das Ende des Zyklus oder, im Modus lanes, die Gnadenfrist nach dem
        // Ablauf der Zeit, wer zuerst kommt.
        let finished = OneShot { group.leave() }

        let opQueue = OperationQueue()
        let op = BlockOperation { [weak self] in
            // Der Processing-Task leert zuerst die Reste des Outbox-Pfads, wie im Original.
            if kind == .processing {
                self?.retryOutboxIfPossible()
            }
            collect(kind.trigger, budget.deadline) { _ in finished.fire() }

            let result = group.wait(timeout: .now() + budget.waitCap)
            if result == .timedOut {
                self?.logMessage("\(kind.label) sync timed out")
            }
        }

        task.expirationHandler = { [self] in
            logMessage("\(kind.label) task expired - cancelling in-flight uploads")
            cancelInFlightSyncUploads(reason: "backgroundExpiration")
            op.cancel()
            if let grace = budget.expirationGrace {
                finished.fireAfter(grace)
            }
        }
        op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
        opQueue.addOperation(op)
    }
}
