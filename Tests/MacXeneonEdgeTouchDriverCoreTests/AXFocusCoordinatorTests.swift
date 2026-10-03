import ApplicationServices
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class AXFocusCoordinatorTests: XCTestCase {
    func testPreparationUsesFreshReadsThenDeliversOnCallbackQueue() {
        let f = FocusCoordinatorFixture()
        var completed = false
        f.restorer.prepareFocusedWindow { completed = true }
        f.pump(includeCallbacks: false)
        XCTAssertFalse(completed)
        XCTAssertEqual(f.backend.resolveCount, 2)
        XCTAssertEqual(f.backend.observers.count, 1)
        f.callbacks.runAll()
        XCTAssertTrue(completed)
    }

    func testBusyPreparationsNeverAccumulateAXJobs() {
        let f = FocusCoordinatorFixture()
        f.restorer.prepareFocusedWindow {}
        f.main.runAll()
        XCTAssertEqual(f.worker.jobs.count, 1)
        for _ in 0..<100 { f.restorer.prepareFocusedWindow {} }
        XCTAssertEqual(f.worker.jobs.count, 1)
        XCTAssertEqual(f.main.jobs.count, 0)
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 0, "The admitted but superseded job is invalid before AX begins.")
        f.prepare()
        XCTAssertEqual(f.backend.resolveCount, 2)
    }

    func testLateCaptureCannotAuthorizeObservationOrRestoration() {
        let f = FocusCoordinatorFixture()
        f.backend.onResolve = { f.clock.nanoseconds = 40_000_000 }
        f.prepare()
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 1)
        XCTAssertTrue(f.backend.observers.isEmpty)
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testCaptureObserverFailureStillCompletesTouchPreparation() {
        let f = FocusCoordinatorFixture()
        f.backend.observationSucceeds = false
        var completed = false
        f.restorer.prepareFocusedWindow { completed = true }
        f.pump()
        XCTAssertTrue(completed)
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testBaselineObserverFailureNeverMutates() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.backend.observationSucceeds = false
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
    }

    func testChangedFocusDuringTouchCanRestoreOnceAfterRelease() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.backend.onAttempt = {
            f.backend.focused = f.captured
            f.workspace.frontmost = f.captured.workspaceApplication
        }
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 1)
        XCTAssertEqual(f.backend.resolveCount, 4)
        XCTAssertEqual(f.backend.observers.count, 2)
        XCTAssertTrue(f.backend.observers.allSatisfy { $0.invalidations == 1 })
    }

    func testAlreadyFocusedWindowSkipsMutation() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.count, 1)
    }

    func testFocusChangeWhileCallbackQueuedRevokesCaptureButDeliversTouch() {
        let f = FocusCoordinatorFixture()
        var completed = false
        f.restorer.prepareFocusedWindow { completed = true }
        f.pump(includeCallbacks: false)
        f.backend.observers.first?.emit(.focusChanged)
        f.callbacks.runAll()
        XCTAssertTrue(completed)
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
    }

    func testPostReleaseFocusChangeBeforeCursorReturnRevokesRestoration() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.restorer.inputDidEnd()
        f.backend.observers.first?.emit(.focusChanged)
        f.clock.nanoseconds += 100_000_000
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testLifecycleChangeDuringTouchRevokesRestoration() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.workspace.emit(.lifecycleChanged)
        f.changeFocusDuringTouch()
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testFreshBaselineChangeBeforeMutationRevokesRestoration() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.main.runAll()
        f.worker.runAll()
        XCTAssertEqual(f.backend.observers.count, 2)
        f.backend.observers.last?.emit(.focusChanged)
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testTimedOutMutationIsNeverRetriedOrFollowedByVerification() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.backend.onAttempt = {
            f.clock.nanoseconds += 160_000_000
            f.restorer.prepareFocusedWindow {}
            f.backend.focused = f.captured // An issued operation can still take effect late.
        }
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 1)
        XCTAssertEqual(f.backend.resolveCount, 3)
        XCTAssertTrue(f.backend.observers.allSatisfy { $0.invalidations == 1 })
    }

    func testShutdownSuppressesAlreadyQueuedPreparationCompletion() {
        let f = FocusCoordinatorFixture()
        var completions = 0
        f.restorer.prepareFocusedWindow { completions += 1 }
        f.pump(includeCallbacks: false)
        f.restorer.shutdown()
        f.restorer.prepareFocusedWindow { completions += 1 }
        f.pump()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
        XCTAssertGreaterThan(f.workspace.stopCount, 0)
    }

    func testDiscardBeforeMainStageDoesNotStartWorkspaceOrAX() {
        let f = FocusCoordinatorFixture()
        f.restorer.prepareFocusedWindow {}
        f.restorer.discardCapturedWindow()
        f.pump()
        XCTAssertEqual(f.workspace.startCount, 0)
        XCTAssertEqual(f.backend.resolveCount, 0)
    }

    func testLegacyCaptureNeverStartsPostInputAXRead() {
        let f = FocusCoordinatorFixture()
        f.restorer.captureFocusedWindow()
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 0)
        XCTAssertEqual(f.workspace.startCount, 0)
    }

    func testDroppingPreparedRestorerRetainsObserversUntilOrderedCleanup() {
        let main = FocusManualExecutor()
        let worker = FocusManualExecutor()
        let callbacks = FocusManualExecutor()
        let target = coordinatorTarget(pid: 10, window: "first")
        let backend = CoordinatorBackendFake(focused: target)
        var sourceContext = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext)!
        backend.observationSource = source
        defer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        let workspace = CoordinatorWorkspaceFake(application: target.workspaceApplication)
        var restorer: AXFocusRestorer? = AXFocusRestorer(
            backend: backend, workspace: workspace, onMain: main.enqueue, onWorker: worker.enqueue,
            onCallback: callbacks.enqueue, now: { 0 })
        restorer?.prepareFocusedWindow {}
        for _ in 0..<5 { main.runAll(); worker.runAll(); callbacks.runAll() }
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode))
        let weakRestorer = FocusWeakReference(restorer)
        let weakObserver = FocusWeakReference(backend.observers.first)
        var invalidated = false
        backend.observers.first?.onInvalidate = {
            XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode),
                           "Main must detach the source before worker-side observer invalidation.")
            invalidated = true
        }
        backend.observers.removeAll()
        XCTAssertNotNil(weakObserver.value, "The session must own the observer independently of the backend fake.")
        restorer = nil
        XCTAssertNil(weakRestorer.value)
        XCTAssertNotNil(weakObserver.value, "Pending main detach must retain the observer and its callback context.")
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode))
        main.runAll()
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode))
        XCTAssertNotNil(weakObserver.value, "The detached observer must survive until worker invalidation.")
        XCTAssertFalse(invalidated)
        worker.runAll()
        XCTAssertTrue(invalidated)
        XCTAssertNil(weakObserver.value, "Completed cleanup must release the observer.")
    }

    func testMainShutdownReturnsWhileRealWorkerIsBlocked() {
        let entered = expectation(description: "fake AX entered")
        let exited = expectation(description: "fake AX exited")
        let workerExited = FocusLockedFlag()
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.focus.blocked-worker")
        let target = coordinatorTarget(pid: 10, window: "first")
        let backend = CoordinatorBackendFake(focused: target)
        backend.onResolve = {
            entered.fulfill()
            if gate.wait(timeout: .now() + 2) != .success {
                XCTFail("Shutdown must return while fake AX is still blocked; only the test may release it.")
            }
            workerExited.set()
            exited.fulfill()
        }
        let workspace = CoordinatorWorkspaceFake(application: target.workspaceApplication)
        let restorer = AXFocusRestorer(backend: backend, workspace: workspace,
            onMain: { DispatchQueue.main.async(execute: $0) },
            onWorker: { queue.async(execute: $0) },
            onCallback: { DispatchQueue.main.async(execute: $0) },
            now: { DispatchTime.now().uptimeNanoseconds })
        var completed = false
        let preparationStart = DispatchTime.now().uptimeNanoseconds
        restorer.prepareFocusedWindow { completed = true }
        let preparationMs = Double(DispatchTime.now().uptimeNanoseconds - preparationStart) / 1_000_000
        wait(for: [entered], timeout: 1)
        let shutdownStart = DispatchTime.now().uptimeNanoseconds
        restorer.shutdown()
        let shutdownMs = Double(DispatchTime.now().uptimeNanoseconds - shutdownStart) / 1_000_000
        XCTAssertFalse(workerExited.isSet, "Shutdown must finish before the in-flight AX operation returns.")
        XCTAssertFalse(completed)
        print("Fake-blocked AX: prepare returned in \(preparationMs) ms; main shutdown returned in \(shutdownMs) ms")
        gate.signal()
        wait(for: [exited], timeout: 1)
        let returned = expectation(description: "actual worker returned")
        queue.async { returned.fulfill() }
        wait(for: [returned], timeout: 1)
        XCTAssertFalse(completed)
        XCTAssertEqual(backend.resolveCount, 1)
        XCTAssertEqual(backend.attemptCount, 0)
        XCTAssertTrue(backend.observers.isEmpty)
    }
}

private final class FocusManualExecutor {
    var jobs: [() -> Void] = []
    func enqueue(_ action: @escaping () -> Void) { jobs.append(action) }
    @discardableResult func runAll() -> Bool {
        let pending = jobs
        jobs.removeAll()
        pending.forEach { $0() }
        return !pending.isEmpty
    }
}

private final class CoordinatorClock { var nanoseconds: UInt64 = 0 }

private final class FocusWeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

private final class FocusLockedFlag {
    private let lock = NSLock()
    private var storage = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class FocusCoordinatorFixture {
    let main = FocusManualExecutor()
    let worker = FocusManualExecutor()
    let callbacks = FocusManualExecutor()
    let clock = CoordinatorClock()
    let captured = coordinatorTarget(pid: 10, window: "first")
    let other = coordinatorTarget(pid: 20, window: "other")
    let backend: CoordinatorBackendFake
    let workspace: CoordinatorWorkspaceFake
    let restorer: AXFocusRestorer

    init() {
        backend = CoordinatorBackendFake(focused: captured)
        workspace = CoordinatorWorkspaceFake(application: captured.workspaceApplication)
        let clock = self.clock
        restorer = AXFocusRestorer(backend: backend, workspace: workspace,
            onMain: main.enqueue, onWorker: worker.enqueue, onCallback: callbacks.enqueue, now: { clock.nanoseconds })
    }

    func prepare() {
        restorer.prepareFocusedWindow {}
        pump()
    }

    func changeFocusDuringTouch() {
        backend.focused = other
        workspace.frontmost = other.workspaceApplication
        workspace.emit(.focusChanged)
        backend.observers.first?.emit(.focusChanged)
    }

    func releaseAndRestore() {
        restorer.inputDidEnd()
        restorer.restoreCapturedWindow()
        pump()
    }

    func pump(includeCallbacks: Bool = true) {
        for _ in 0..<30 {
            let didMain = main.runAll()
            let didWorker = worker.runAll()
            let didCallbacks = includeCallbacks && callbacks.runAll()
            if !didMain && !didWorker && !didCallbacks { return }
        }
        XCTFail("Focus pipeline did not quiesce within its bounded stages")
    }
}

private func coordinatorTarget(pid: pid_t, window: String) -> AXFocusTarget {
    AXFocusTarget(application: AXFocusElement(rawValue: "app-\(pid)" as NSString),
        window: AXFocusElement(rawValue: window as NSString),
        workspaceApplication: AXFocusWorkspaceApplication(processIdentifier: pid,
            identity: "process-\(pid)" as NSString, isTerminated: false, isHidden: false))
}

private final class CoordinatorObservationFake: AXFocusObservationProtocol {
    let source: CFRunLoopSource?
    var invalidations = 0
    var onInvalidate: (() -> Void)?
    let change: (FocusObservationEvent) -> Void
    init(change: @escaping (FocusObservationEvent) -> Void, source: CFRunLoopSource? = nil) {
        self.change = change
        self.source = source
    }
    func emit(_ event: FocusObservationEvent) { change(event) }
    func invalidate() { onInvalidate?(); invalidations += 1 }
}

private final class CoordinatorBackendFake: AXFocusBackendProtocol {
    var focused: AXFocusTarget
    var observationSucceeds = true
    var observationSource: CFRunLoopSource?
    var resolveCount = 0
    var attemptCount = 0
    var observers: [CoordinatorObservationFake] = []
    var onResolve: (() -> Void)?
    var onAttempt: (() -> Void)?
    init(focused: AXFocusTarget) { self.focused = focused }

    func resolve(workspace: AXFocusWorkspaceApplication?, permit: () -> Bool) -> AXFocusResolution {
        resolveCount += 1
        onResolve?()
        return .known(focused) // Deliberately can return a stale answer after its permit expires.
    }

    func relationship(_ lhs: AXFocusTarget, _ rhs: AXFocusTarget) -> AXFocusRelationship {
        CFEqual(lhs.application.rawValue, rhs.application.rawValue)
            && CFEqual(lhs.window.rawValue, rhs.window.rawValue) ? .same : .different
    }

    func attemptRestore(captured: AXFocusTarget, baseline: AXFocusTarget,
        workspace: AXFocusWorkspaceApplication?, capturedApplication: AXFocusWorkspaceApplication?,
        permit: () -> Bool) -> AXFocusAttemptResult {
        guard permit() else { return .skipped }
        attemptCount += 1
        onAttempt?()
        return .attempted(.success)
    }

    func prepareObservation(target: AXFocusTarget, permit: () -> Bool,
        onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol? {
        guard observationSucceeds, permit() else { return nil }
        let observer = CoordinatorObservationFake(change: onChange, source: observationSource)
        observers.append(observer)
        return observer
    }
}

private final class CoordinatorWorkspaceFake: WorkspaceFocusMonitoring {
    var frontmost: AXFocusWorkspaceApplication
    let original: AXFocusWorkspaceApplication
    var revision: UInt64 = 0
    var active = true
    var startCount = 0
    var stopCount = 0
    var observer: ((FocusObservationEvent) -> Void)?
    init(application: AXFocusWorkspaceApplication) { frontmost = application; original = application }
    func start(observation: @escaping (FocusObservationEvent) -> Void) { startCount += 1; observer = observation }
    func snapshot() -> WorkspaceFocusSnapshot {
        WorkspaceFocusSnapshot(application: frontmost, revision: revision, sessionActive: active)
    }
    func application(processIdentifier: pid_t) -> AXFocusWorkspaceApplication? {
        processIdentifier == original.processIdentifier ? original : frontmost
    }
    func emit(_ event: FocusObservationEvent) { revision += 1; observer?(event) }
    func stop() { stopCount += 1; observer = nil }
}
