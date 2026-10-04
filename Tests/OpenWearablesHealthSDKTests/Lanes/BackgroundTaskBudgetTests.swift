import XCTest
@testable import OpenWearablesHealthSDK

/// Frist und Ende der SDK-eigenen Hintergrund-Tasks (Plan 05-09, vom Orchestrator verlangte
/// Ergänzung).
///
/// Ohne Frist kann ein Zyklus der Zwei-Spuren-Steuerung länger laufen als die Zeit, die iOS dem
/// BGTask gibt, und die App wird beendet: ein stiller Ausfall. Im Modus lanes bekommen
/// `BGAppRefreshTask` (rund 30 s) und `BGProcessingTask` deshalb eine Frist aus ihrem Zeitrahmen.
/// Im Modus upstream bleibt alles wie im Original: keine Frist, Wartegrenzen 20 s und 25 s, und
/// `setTaskCompleted` erst, wenn der Lauf zurück ist.
///
/// Der echte `BGTask` lässt sich im Test nicht erzeugen. Die Handler in `Background.swift` sind
/// deshalb dünn und rufen `runSDKBackgroundTask(_:kind:)`; getestet wird mit einem Handle, der
/// dieselben zwei Aufrufe kennt (`expirationHandler`, `setTaskCompleted`), und einem eingespielten
/// Zyklus, der die übergebene Frist festhält.
final class BackgroundTaskBudgetTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Hilfen

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Ein Task, der nur zählt, wie oft und mit welchem Ergebnis er beendet wurde.
    private final class FakeTask: BackgroundTaskHandle {
        var expirationHandler: (() -> Void)?
        private let lock = NSLock()
        private var results: [Bool] = []
        let completed: XCTestExpectation

        init() {
            completed = XCTestExpectation(description: "setTaskCompleted")
            // Ein zweiter Aufruf soll als Zählung sichtbar werden, nicht als Ausnahme im Testlauf.
            completed.assertForOverFulfill = false
        }

        var successes: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return results
        }

        func setTaskCompleted(success: Bool) {
            lock.lock()
            results.append(success)
            lock.unlock()
            completed.fulfill()
        }
    }

    /// Der eingespielte Zyklus: hält Auslöser und Frist fest und beendet sich sofort, auf Wunsch
    /// nie (dann liefert `completePending()` das späte Ende nach).
    private final class CollectProbe {
        struct Call { let trigger: SyncTrigger; let deadline: Date? }

        private let lock = NSLock()
        private var recorded: [Call] = []
        private var pending: [(SyncOutcome) -> Void] = []
        private let finishImmediately: Bool
        private let completionsPerCall: Int

        init(finishImmediately: Bool, completionsPerCall: Int = 1) {
            self.finishImmediately = finishImmediately
            self.completionsPerCall = completionsPerCall
        }

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        var collect: BackgroundCollect {
            return { [self] trigger, deadline, completion in
                lock.lock()
                recorded.append(Call(trigger: trigger, deadline: deadline))
                pending.append(completion)
                lock.unlock()
                if finishImmediately {
                    for _ in 0..<completionsPerCall { completion(Self.outcome(trigger)) }
                }
            }
        }

        func completePending() {
            lock.lock()
            let all = pending
            pending = []
            lock.unlock()
            for completion in all { completion(Self.outcome(.sdkRefresh)) }
        }

        static func outcome(_ trigger: SyncTrigger) -> SyncOutcome {
            SyncOutcome(
                status: .upToDate, orchestration: .lanes,
                trigger: trigger, started: Date(), finished: Date()
            )
        }
    }

    // MARK: - Das Budget (reine Funktion)

    func testLanesRefreshGetsADeadlineInsideTheTaskTimeAndAMatchingWaitCap() {
        let budget = BackgroundTaskBudget.make(kind: .refresh, orchestration: .lanes, started: t0)

        XCTAssertEqual(budget.deadline, t0.addingTimeInterval(25), "rund 25 s ab Start des Tasks")
        XCTAssertGreaterThan(budget.waitCap, 25, "der Handler wartet über die Frist hinaus, damit der Zyklus selbst endet")
        XCTAssertLessThan(budget.waitCap, 30, "und gibt den Task vor dem Ende der Zeit zurück, die iOS ihm gibt")
        XCTAssertEqual(budget.expirationGrace, BackgroundTaskBudget.lanesExpirationGrace)
    }

    func testLanesProcessingGetsAConservativeFiveMinuteDeadline() {
        let budget = BackgroundTaskBudget.make(kind: .processing, orchestration: .lanes, started: t0)

        XCTAssertEqual(budget.deadline, t0.addingTimeInterval(300))
        XCTAssertGreaterThan(budget.waitCap, 300)
        XCTAssertLessThan(budget.waitCap, 330)
        XCTAssertEqual(budget.expirationGrace, BackgroundTaskBudget.lanesExpirationGrace)
    }

    func testTheExpirationGraceIsShort() {
        // Nach dem Ablauf der Zeit bleibt dem Zyklus nur ein Moment, sich selbst zu beenden.
        XCTAssertGreaterThan(BackgroundTaskBudget.lanesExpirationGrace, 0)
        XCTAssertLessThanOrEqual(BackgroundTaskBudget.lanesExpirationGrace, 3)
    }

    func testUpstreamKeepsTheOriginalWaitsAndHasNoDeadlineAndNoEarlyRelease() {
        let refresh = BackgroundTaskBudget.make(kind: .refresh, orchestration: .upstream, started: t0)
        let processing = BackgroundTaskBudget.make(kind: .processing, orchestration: .upstream, started: t0)

        XCTAssertEqual(refresh, BackgroundTaskBudget(deadline: nil, waitCap: 20, expirationGrace: nil))
        XCTAssertEqual(processing, BackgroundTaskBudget(deadline: nil, waitCap: 25, expirationGrace: nil))
    }

    func testEachKindMapsToItsTriggerAndItsOriginalLogLabel() {
        XCTAssertEqual(BackgroundTaskKind.refresh.trigger, .sdkRefresh)
        XCTAssertEqual(BackgroundTaskKind.processing.trigger, .sdkProcessing)
        XCTAssertEqual(BackgroundTaskKind.refresh.label, "BGAppRefresh")
        XCTAssertEqual(BackgroundTaskKind.processing.label, "BGProcessing")
    }

    // MARK: - Der Ablauf im Task

    func testLanesRefreshPassesANonNilDeadlineAndCompletesTheTaskExactlyOnce() {
        withIsolatedSDK(orchestration: .lanes) { sdk, _ in
            let task = FakeTask()
            let probe = CollectProbe(finishImmediately: true)
            let started = Date()

            sdk.runSDKBackgroundTask(task, kind: .refresh, collect: probe.collect)
            wait(for: [task.completed], timeout: 3)
            spin(0.2)

            XCTAssertEqual(probe.calls.count, 1)
            XCTAssertEqual(probe.calls.first?.trigger, .sdkRefresh)
            let deadline = probe.calls.first?.deadline
            XCTAssertNotNil(deadline, "im Modus lanes ohne Frist kann ein Zyklus die Zeit des Tasks überleben")
            XCTAssertEqual(deadline?.timeIntervalSince(started) ?? 0, 25, accuracy: 1.0)
            XCTAssertEqual(task.successes, [true], "genau einmal, und erfolgreich, weil nichts abgebrochen wurde")
        }
    }

    func testLanesProcessingPassesANonNilDeadlineAndCompletesTheTaskExactlyOnce() {
        withIsolatedSDK(orchestration: .lanes) { sdk, _ in
            let task = FakeTask()
            let probe = CollectProbe(finishImmediately: true)
            let started = Date()

            sdk.runSDKBackgroundTask(task, kind: .processing, collect: probe.collect)
            wait(for: [task.completed], timeout: 3)
            spin(0.2)

            XCTAssertEqual(probe.calls.first?.trigger, .sdkProcessing)
            let deadline = probe.calls.first?.deadline
            XCTAssertNotNil(deadline)
            XCTAssertEqual(deadline?.timeIntervalSince(started) ?? 0, 300, accuracy: 1.0)
            XCTAssertEqual(task.successes, [true])
        }
    }

    func testUpstreamRefreshAndProcessingPassNoDeadlineAsBefore() {
        withIsolatedSDK(orchestration: .upstream) { sdk, _ in
            for kind in [BackgroundTaskKind.refresh, .processing] {
                let task = FakeTask()
                let probe = CollectProbe(finishImmediately: true)

                sdk.runSDKBackgroundTask(task, kind: kind, collect: probe.collect)
                wait(for: [task.completed], timeout: 3)
                spin(0.1)

                XCTAssertEqual(probe.calls.count, 1, "\(kind)")
                XCTAssertEqual(probe.calls.first?.trigger, kind.trigger, "\(kind)")
                XCTAssertNil(probe.calls.first?.deadline, "der Upstream-Pfad bleibt ohne Frist (\(kind))")
                XCTAssertEqual(task.successes, [true], "\(kind)")
            }
        }
    }

    func testALateOrDoubleCompletionOfTheCycleNeverCompletesTheTaskTwice() {
        withIsolatedSDK(orchestration: .lanes) { sdk, _ in
            let task = FakeTask()
            // Der Zyklus meldet sich zweimal; ein unausgeglichenes `leave` wäre ein Absturz.
            let probe = CollectProbe(finishImmediately: true, completionsPerCall: 2)

            sdk.runSDKBackgroundTask(task, kind: .refresh, collect: probe.collect)
            wait(for: [task.completed], timeout: 3)
            spin(0.2)

            XCTAssertEqual(task.successes, [true])
        }
    }

    // MARK: - Ablauf der Zeit

    func testLanesExpirationCancelsUploadsAndCompletesTheTaskOnceAfterTheGraceEvenIfTheCycleHangs() {
        withIsolatedSDK(orchestration: .lanes) { sdk, _ in
            let task = FakeTask()
            let probe = CollectProbe(finishImmediately: false)
            let upload = URLSession(configuration: .ephemeral).dataTask(with: URL(string: "https://sync.example.test/x")!)
            sdk.trackSyncUpload(upload, requestId: "bg-expiry-test")
            defer { sdk.untrackSyncUpload(requestId: "bg-expiry-test") }

            let budget = BackgroundTaskBudget(
                deadline: Date().addingTimeInterval(25), waitCap: 30, expirationGrace: 0.3
            )
            sdk.runSDKBackgroundTask(task, kind: .refresh, budget: budget, collect: probe.collect)
            spin(0.1)
            XCTAssertNotNil(task.expirationHandler, "der Handler setzt den Ablauf-Handler")

            task.expirationHandler?()
            XCTAssertNotEqual(upload.state, .suspended, "der laufende Upload wird abgebrochen")
            spin(0.1)
            XCTAssertEqual(task.successes, [], "der Zyklus bekommt einen kurzen Moment, sich selbst zu beenden")

            wait(for: [task.completed], timeout: 3)
            XCTAssertEqual(task.successes, [false], "nach der Frist genau einmal, als nicht erfolgreich")

            // Das späte Ende des Zyklus ändert nichts mehr.
            probe.completePending()
            spin(0.3)
            XCTAssertEqual(task.successes, [false])
        }
    }

    /// Review ME-01: der Ablauf-Handler bricht nicht nur Uploads ab, er zieht auch die Frist des
    /// laufenden Zyklus auf "jetzt". Sonst startete ein Zyklus, der gerade in HealthKit liest, danach
    /// den nächsten Upload und würde mittendrin suspendiert.
    func testLanesExpirationAlsoEndsTheRunningCycleAtItsNextCheckpoint() {
        withIsolatedSDK(orchestration: .lanes) { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("slot") }
            var tightened: [Date] = []
            sdk.registerActiveLanesCycle(ActiveLanesCycle(
                generation: generation, requestLiveRound: { _ in true }, tighten: { tightened.append($0) }
            ))
            defer {
                _ = sdk.releaseActiveLanesCycle(generation: generation)
                sdk.finishSync(generation: generation)
            }
            let task = FakeTask()
            let probe = CollectProbe(finishImmediately: false)
            let budget = BackgroundTaskBudget(
                deadline: Date().addingTimeInterval(25), waitCap: 30, expirationGrace: 0.3
            )
            sdk.runSDKBackgroundTask(task, kind: .refresh, budget: budget, collect: probe.collect)
            spin(0.1)

            task.expirationHandler?()

            XCTAssertEqual(tightened.count, 1, "die Frist des Zyklus ist jetzt")
            wait(for: [task.completed], timeout: 3)
        }
    }

    func testLanesExpirationCompletesAsSoonAsTheCycleEndsWithinTheGrace() {
        withIsolatedSDK(orchestration: .lanes) { sdk, _ in
            let task = FakeTask()
            let probe = CollectProbe(finishImmediately: false)
            let budget = BackgroundTaskBudget(
                deadline: Date().addingTimeInterval(25), waitCap: 30, expirationGrace: 5
            )
            sdk.runSDKBackgroundTask(task, kind: .processing, budget: budget, collect: probe.collect)
            spin(0.1)

            let expired = Date()
            task.expirationHandler?()
            probe.completePending()
            wait(for: [task.completed], timeout: 3)

            XCTAssertLessThan(Date().timeIntervalSince(expired), 2, "der Zyklus endete selbst, die Frist wird nicht abgewartet")
            spin(0.2)
            XCTAssertEqual(task.successes, [false])
        }
    }

    func testUpstreamExpirationStaysAsItWasTheWaitIsNotReleasedEarly() {
        withIsolatedSDK(orchestration: .upstream) { sdk, _ in
            let task = FakeTask()
            let probe = CollectProbe(finishImmediately: false)
            let upload = URLSession(configuration: .ephemeral).dataTask(with: URL(string: "https://sync.example.test/y")!)
            sdk.trackSyncUpload(upload, requestId: "bg-expiry-upstream-test")
            defer { sdk.untrackSyncUpload(requestId: "bg-expiry-upstream-test") }

            // Wie `make(... .upstream ...)`, nur mit kurzer Wartegrenze, damit der Test nicht 20 s dauert.
            let original = BackgroundTaskBudget.make(kind: .refresh, orchestration: .upstream, started: t0)
            XCTAssertNil(original.expirationGrace)
            let budget = BackgroundTaskBudget(deadline: original.deadline, waitCap: 0.5, expirationGrace: original.expirationGrace)

            sdk.runSDKBackgroundTask(task, kind: .refresh, budget: budget, collect: probe.collect)
            spin(0.1)
            task.expirationHandler?()
            XCTAssertNotEqual(upload.state, .suspended, "die Uploads werden auch im Original-Ablauf abgebrochen")

            spin(0.1)
            XCTAssertEqual(task.successes, [], "im Original-Ablauf endet der Task erst, wenn der Lauf zurück ist oder die Wartegrenze greift")

            wait(for: [task.completed], timeout: 3)
            XCTAssertEqual(task.successes, [false], "der Operation wurde abgebrochen: nicht erfolgreich, genau einmal")
        }
    }

    func testTheWaitCapCompletesTheTaskOnceWhenTheCycleNeverReturnsAndNothingExpired() {
        withIsolatedSDK(orchestration: .lanes) { sdk, _ in
            let task = FakeTask()
            let probe = CollectProbe(finishImmediately: false)
            let budget = BackgroundTaskBudget(
                deadline: Date().addingTimeInterval(0.2), waitCap: 0.4, expirationGrace: 2
            )

            sdk.runSDKBackgroundTask(task, kind: .refresh, budget: budget, collect: probe.collect)
            wait(for: [task.completed], timeout: 3)
            spin(0.2)

            XCTAssertEqual(task.successes, [true], "wie im Original: die Wartegrenze beendet den Task, nichts wurde abgebrochen")
        }
    }

    // MARK: - Ohne eingespielten Zyklus

    func testTheRealCycleRunsThroughTheHandlerInBothModes() {
        // Ohne verfolgte Typen endet der Zyklus sofort als "nichts Neues". Das belegt nur die
        // Verdrahtung des echten Pfads (Budget aus dem Modus, echte Weiche), nicht HealthKit.
        for mode in [SyncOrchestration.lanes, .upstream] {
            withIsolatedSDK(orchestration: mode) { sdk, _ in
                let task = FakeTask()

                sdk.runSDKBackgroundTask(task, kind: .refresh)
                wait(for: [task.completed], timeout: 5)
                spin(0.2)

                XCTAssertEqual(task.successes, [true], "\(mode)")
            }
        }
    }
}
