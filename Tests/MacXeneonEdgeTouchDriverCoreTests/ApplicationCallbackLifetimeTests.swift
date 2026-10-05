import CoreGraphics
import Darwin
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// No production HID, CG registration, permission prompts, or input effects.
final class ApplicationCallbackLifetimeTests: XCTestCase {
    func testNeverRunDestructionStillInvalidatesOwnedFocus() {
        let trace = CallbackLifetimeTrace()
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace)
        let weakApplication = { [weak application] in application }
        application = nil
        XCTAssertNil(weakApplication())
        XCTAssertEqual(trace.count("shutdown-main"), 1)
        XCTAssertEqual(trace.count("start"), 0)
        XCTAssertEqual(trace.count("stop"), 0)
    }

    func testStopBeforeRunAndDestructionInvalidateFocusOnlyOnce() {
        let trace = CallbackLifetimeTrace()
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace)
        application?.stop()
        application?.stop()
        application = nil
        XCTAssertEqual(trace.count("shutdown-main"), 1)
        XCTAssertEqual(trace.count("start"), 0)
        XCTAssertEqual(trace.count("stop"), 0)
    }

    func testWaitingRunFinishesFocusWithoutAcquiringHardware() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness()
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace, startup: startup)
        startup.runLoop.onRun = { [signals = startup.signals] in signals.send(SIGTERM) }
        XCTAssertEqual(application?.run(), EXIT_SUCCESS)
        application = nil
        XCTAssertEqual(trace.count("shutdown-main"), 1)
        XCTAssertEqual(trace.count("start"), 0)
        XCTAssertEqual(trace.count("stop"), 0)
    }

    func testSignalSetupFailureInvalidatesFocusWithoutHardwareTeardown() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        startup.signals.installError = CallbackLifetimeError.start
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace, startup: startup)
        XCTAssertEqual(application?.run(), EXIT_FAILURE)
        application = nil
        XCTAssertEqual(trace.count("shutdown-main"), 1)
        XCTAssertEqual(trace.count("start"), 0)
        XCTAssertEqual(trace.count("stop"), 0)
    }

    func testHardwareStartFailureUnwindsOwnedResourcesExactlyOnce() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        var isOpen = false
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(
            trace: trace, startup: startup,
            monitoring: DriverMonitoringHooks(start: {
                isOpen = true
                trace.record("start")
                throw CallbackLifetimeError.start
            }, stop: { isOpen = false; trace.record("stop") })
        )
        XCTAssertEqual(application?.run(), EXIT_FAILURE)
        XCTAssertFalse(isOpen)
        application?.stop()
        application = nil
        XCTAssertEqual(trace.count("start"), 1)
        XCTAssertEqual(trace.count("stop"), 1)
        XCTAssertEqual(trace.count("shutdown-main"), 1)
    }

    func testReentrantStopDuringStartWaitsForAcquisitionToUnwind() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        var isOpen = false
        var application: MacXeneonEdgeTouchDriverApplication?
        application = makeApplication(trace: trace, startup: startup, monitoring: DriverMonitoringHooks(start: {
            trace.record("start")
            application?.stop()
            isOpen = true
        }, stop: { isOpen = false; trace.record("stop") }))
        XCTAssertEqual(application?.run(), EXIT_SUCCESS)
        XCTAssertFalse(isOpen)
        application?.stop()
        application = nil
        XCTAssertEqual(trace.count("stop"), 1)
        XCTAssertEqual(trace.count("shutdown-main"), 1)
    }

    func testNestedAndRepeatedRunDoNotPrematurelyShutdownFocus() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        let application = makeApplication(trace: trace, startup: startup)
        startup.runLoop.onRun = { [weak application] in
            XCTAssertEqual(application?.run(), EXIT_SUCCESS)
            XCTAssertEqual(trace.count("shutdown-main"), 0)
        }
        XCTAssertEqual(application.run(), EXIT_SUCCESS)
        XCTAssertEqual(application.run(), EXIT_SUCCESS)
        XCTAssertEqual(trace.count("start"), 1)
        XCTAssertEqual(trace.count("stop"), 1)
        XCTAssertEqual(trace.count("shutdown-main"), 1)
    }

    func testRunRetainsApplicationWhenCallerDropsItsOwnerDuringMonitoring() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace, startup: startup)
        let weakApplication = { [weak application] in application }
        startup.runLoop.onRun = { [signals = startup.signals] in
            application = nil
            XCTAssertNotNil(weakApplication())
            signals.send(SIGTERM)
            XCTAssertEqual(trace.count("stop"), 1)
        }
        XCTAssertEqual(application?.run(), EXIT_SUCCESS)
        XCTAssertNil(weakApplication())
        XCTAssertEqual(trace.count("shutdown-main"), 1)
    }

    func testCompletedRunFinalReleaseOnBackgroundQueueDoesNotReenterLifecycle() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace, startup: startup)
        XCTAssertEqual(application?.run(), EXIT_SUCCESS)
        let weakApplication = { [weak application] in application }
        let completedTrace = trace.snapshot()
        // The single unmanaged +1 is transferred, not shared. Only the worker
        // releases it; no application method is invoked through this test bridge.
        let token = UInt(bitPattern: Unmanaged.passRetained(application!).toOpaque())
        application = nil
        let released = expectation(description: "Final application release")
        DispatchQueue(label: "application-lifetime.final-release").async {
            let pointer = UnsafeRawPointer(bitPattern: token)!
            Unmanaged<MacXeneonEdgeTouchDriverApplication>.fromOpaque(pointer).release()
            released.fulfill()
        }
        guard XCTWaiter.wait(for: [released], timeout: 2) == .completed else {
            XCTFail("Final release did not complete; do not read dependent state")
            return
        }
        XCTAssertNil(weakApplication())
        XCTAssertEqual(trace.snapshot(), completedTrace)
        XCTAssertEqual(trace.count("shutdown-main"), 1)
    }

    func testAdmittedWeakApplicationCallbackCanOwnFinalReleaseAfterCompletedRun() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        let queue = DispatchQueue(label: "application-lifetime.weak-callback")
        let entered = DispatchSemaphore(value: 0)
        let allowReturn = DispatchSemaphore(value: 0)
        let effects = CallbackLifetimeEffects(trace: trace)
        var application: MacXeneonEdgeTouchDriverApplication? = MacXeneonEdgeTouchDriverApplication(
            configuration: .defaults,
            displayResolver: DisplayResolver(activeDisplayProvider: {
                trace.record("resolve")
                entered.signal()
                if allowReturn.wait(timeout: .now() + 2) != .success {
                    trace.record("resolver-timeout")
                }
                return []
            }), inputSink: effects, cursorController: effects, focusRestorer: effects,
            startupDependencies: startup.dependencies,
            monitoringOverride: DriverMonitoringHooks(start: {}, stop: {}), gestureQueue: queue
        )
        XCTAssertEqual(application?.run(), EXIT_SUCCESS)
        let weakApplication = { [weak application] in application }
        application?.enqueueDisplayReconfiguration(flags: .movedFlag)
        guard entered.wait(timeout: .now() + 2) == .success else {
            allowReturn.signal()
            XCTFail("Queued weak-self callback did not enter")
            return
        }
        application = nil
        XCTAssertNotNil(weakApplication(), "The admitted callback temporarily owns the application")
        allowReturn.signal()
        let drained = expectation(description: "Weak-self callback released its owner")
        queue.async { drained.fulfill() }
        guard XCTWaiter.wait(for: [drained], timeout: 2) == .completed else {
            XCTFail("Callback did not drain; do not inspect dependent state")
            return
        }
        XCTAssertNil(weakApplication())
        XCTAssertEqual(trace.count("shutdown-main"), 1)
        XCTAssertEqual(trace.count("shutdown-background"), 0)
        XCTAssertEqual(trace.count("resolver-timeout"), 0)
    }

    func testStopInvalidatesDisplayBeforePlatformRemovalAndGestureDrain() {
        let trace = CallbackLifetimeTrace()
        let startup = StartupTestHarness(snapshot: .cgReady)
        let queue = DispatchQueue(label: "application-lifetime.stop-drain")
        var callback: CGDisplayReconfigurationCallBack?
        var context: UnsafeMutableRawPointer?
        let operations = DisplayReconfigurationRegistration.Operations(register: {
            callback = $0; context = $1; return .success
        }, remove: { removeCallback, removeContext in
            // Model platform delivery during removal, even when removal fails.
            removeCallback(0, .movedFlag, removeContext)
            trace.record("removed")
            return .failure
        })
        var application: MacXeneonEdgeTouchDriverApplication?
        application = makeApplication(trace: trace, startup: startup, queue: queue, monitoring: DriverMonitoringHooks(start: {
            application?.registerDisplayReconfigurationCallback(operations: operations)
        }, stop: { trace.record("stop") }))
        startup.runLoop.onRun = {
            callback?(0, .movedFlag, context)
            application?.stop()
            // The earlier admitted decision ran before stop returned; removal's
            // late callback was denied synchronously and cannot add a decision.
            XCTAssertEqual(trace.count("resolve"), 1)
            callback?(0, .movedFlag, context)
            queue.sync {}
            XCTAssertEqual(trace.count("resolve"), 1)
        }
        XCTAssertEqual(application?.run(), EXIT_SUCCESS)
        application = nil
        callback?(0, .movedFlag, context)
        queue.sync {}
        XCTAssertEqual(trace.count("resolve"), 1)
        XCTAssertEqual(trace.count("removed"), 1)
    }

    private func makeApplication(
        trace: CallbackLifetimeTrace,
        startup: StartupTestHarness = StartupTestHarness(snapshot: .cgReady),
        queue: DispatchQueue? = nil,
        monitoring: DriverMonitoringHooks? = nil
    ) -> MacXeneonEdgeTouchDriverApplication {
        let effects = CallbackLifetimeEffects(trace: trace)
        return MacXeneonEdgeTouchDriverApplication(
            configuration: .defaults,
            displayResolver: DisplayResolver(activeDisplayProvider: { trace.record("resolve"); return [] }),
            inputSink: effects, cursorController: effects, focusRestorer: effects,
            startupDependencies: startup.dependencies,
            monitoringOverride: monitoring ?? DriverMonitoringHooks(start: { trace.record("start") }, stop: { trace.record("stop") }),
            gestureQueue: queue
        )
    }
}

private enum CallbackLifetimeError: Error { case start }

/// All mutable state is private and locked; snapshots are value copies. No
/// arbitrary callbacks or reference graphs escape this test-only recorder.
private final class CallbackLifetimeTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
    func count(_ event: String) -> Int { snapshot().filter { $0 == event }.count }
}

private final class CallbackLifetimeEffects: SyntheticInputSink, CursorController, FocusRestorer {
    let trace: CallbackLifetimeTrace
    init(trace: CallbackLifetimeTrace) { self.trace = trace }
    func shutdown() { trace.record(Thread.isMainThread ? "shutdown-main" : "shutdown-background") }
    func captureFocusedWindow() { trace.record("capture") }
    func restoreCapturedWindow() { trace.record("restore") }
    func discardCapturedWindow() { trace.record("discard") }
    func postMouseDown(at point: CGPoint) { trace.record("down") }
    func postMouseUp(at point: CGPoint) { trace.record("up") }
    func postMouseDragged(to point: CGPoint) { trace.record("drag") }
    func borrow(warpingTo point: CGPoint) -> Bool { trace.record("borrow"); return true }
    func updatePosition(_ point: CGPoint) { trace.record("update") }
    func returnToOrigin() { trace.record("return") }
    func forceShow() { trace.record("show") }
}

final class DisplayReconfigurationRegistrationTests: XCTestCase {
    func testSelectedCallbackCannotEnterAfterStopAndCarrierRelease() {
        let trace = CallbackLifetimeTrace()
        let queue = DispatchQueue(label: "display-callback.selected")
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace, queue: queue)
        var sentinel: CallbackOperationSentinel? = CallbackOperationSentinel(trace: trace)
        let weakSentinel = { [weak sentinel] in sentinel }
        var registration: DisplayReconfigurationRegistration? = DisplayReconfigurationRegistration(
            application: application!, operations: .init(
                register: { [sentinel] _, _ in withExtendedLifetime(sentinel) { CGError.success } },
                remove: { _, _ in .success }
            )
        )
        sentinel = nil
        registration?.start()
        let context = registration!.context
        let selected = DisplayReconfigurationRegistration.prepareCallback(context: context, flags: .movedFlag)
        XCTAssertNotNil(selected)
        registration?.stop()
        registration = nil
        XCTAssertNil(weakSentinel(), "An admitted callback must retain ingress only, never platform operations")
        XCTAssertEqual(trace.count("operations-released-main"), 1)
        let weakApplication = { [weak application] in application }
        application = nil
        XCTAssertNil(weakApplication())
        selected?()
        DisplayReconfigurationRegistration.handleCallback(context: context, flags: .movedFlag)
        queue.sync {}
        XCTAssertEqual(trace.count("resolve"), 0)
    }

    func testFailedRemovalRetiresTokenAndDoesNotRetainApplication() {
        let trace = CallbackLifetimeTrace()
        let queue = DispatchQueue(label: "display-callback.remove-failure")
        var application: MacXeneonEdgeTouchDriverApplication? = makeApplication(trace: trace, queue: queue)
        let weakApplication = { [weak application] in application }
        var registration: DisplayReconfigurationRegistration? = DisplayReconfigurationRegistration(
            application: application!, operations: .init(register: { _, _ in .success }, remove: { callback, context in
                callback(0, .movedFlag, context)
                trace.record("remove")
                return .failure
            })
        )
        registration?.start()
        let oldContext = registration!.context
        registration?.stop()
        registration?.stop()
        registration = nil
        application = nil
        XCTAssertNil(weakApplication())
        DisplayReconfigurationRegistration.handleCallback(context: oldContext, flags: .movedFlag)
        let nextApplication = makeApplication(trace: trace, queue: queue)
        let next = DisplayReconfigurationRegistration(application: nextApplication, operations: noOpOperations)
        next.start()
        XCTAssertNotEqual(next.context, oldContext, "Retired contexts must never alias a later registration")
        DisplayReconfigurationRegistration.handleCallback(context: oldContext, flags: .movedFlag)
        queue.sync {}
        XCTAssertEqual(trace.count("resolve"), 0)
        XCTAssertEqual(trace.count("remove"), 1)
        next.stop()
    }

    func testRegisterFailureRejectsLaterCallbacksWithoutRemovingUnacquiredRegistration() {
        let trace = CallbackLifetimeTrace()
        let queue = DispatchQueue(label: "display-callback.register-failure")
        let application = makeApplication(trace: trace, queue: queue)
        let registration = DisplayReconfigurationRegistration(application: application, operations: .init(
            register: { _, _ in .failure }, remove: { _, _ in trace.record("remove"); return .success }
        ))
        registration.start()
        DisplayReconfigurationRegistration.handleCallback(context: registration.context, flags: .movedFlag)
        registration.stop()
        queue.sync {}
        XCTAssertEqual(trace.count("resolve"), 0)
        XCTAssertEqual(trace.count("remove"), 0)
    }

    func testStopDuringRegistrationRemovesAfterAcquisitionReturnsExactlyOnce() {
        let trace = CallbackLifetimeTrace()
        let queue = DispatchQueue(label: "display-callback.reentrant-stop")
        let application = makeApplication(trace: trace, queue: queue)
        var registration: DisplayReconfigurationRegistration!
        registration = DisplayReconfigurationRegistration(application: application, operations: .init(
            register: { _, _ in
                trace.record("register-enter")
                registration.stop()
                trace.record("register-exit")
                return .success
            }, remove: { callback, context in
                trace.record("remove")
                callback(0, .movedFlag, context)
                return .success
            }
        ))
        registration.start()
        registration.stop()
        registration.start()
        queue.sync {}
        XCTAssertEqual(trace.snapshot(), ["register-enter", "register-exit", "remove"])
        registration = nil
    }

    func testStopBeforeStartDoesNotAcquireRegistration() {
        let trace = CallbackLifetimeTrace()
        let application = makeApplication(trace: trace, queue: DispatchQueue(label: "display-callback.stop-before-start"))
        let registration = DisplayReconfigurationRegistration(application: application, operations: .init(
            register: { _, _ in trace.record("register"); return .success },
            remove: { _, _ in trace.record("remove"); return .success }
        ))
        registration.stop()
        registration.start()
        XCTAssertTrue(trace.snapshot().isEmpty)
    }

    func testBeginCallbackSynchronouslyGatesQueuedInputBeforeItsDecisionExecutes() {
        let trace = CallbackLifetimeTrace()
        let queue = DispatchQueue(label: "display-callback.synchronous-gate")
        let application = makeApplication(trace: trace, queue: queue, withDisplay: true)
        let registration = DisplayReconfigurationRegistration(application: application, operations: noOpOperations)
        registration.start()
        queue.sync {
            application.handleDeviceMatched()
            XCTAssertEqual(trace.count("resolve"), 1)
            DisplayReconfigurationRegistration.handleCallback(context: registration.context, flags: .beginConfigurationFlag)
            // Its queued decision cannot run until this block returns, but the
            // mapper ingress gate must already block the touch and fresh resolve.
            application.handleTouchEvent(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
            XCTAssertEqual(trace.count("resolve"), 1)
            XCTAssertEqual(trace.count("down"), 0)
        }
        registration.stop()
        queue.sync { application.cancelActiveGesture() }
        XCTAssertEqual(trace.count("down"), 0)
    }

    /// Stress coverage supplements the deterministic selected-before-stop test;
    /// scheduling may let stop win before the producer's first lookup.
    func testConcurrentCallbacksCannotSubmitPastStopDrain() {
        let trace = CallbackLifetimeTrace()
        let queue = DispatchQueue(label: "display-callback.concurrent-drain")
        let application = makeApplication(trace: trace, queue: queue)
        let registration = DisplayReconfigurationRegistration(application: application, operations: noOpOperations)
        registration.start()
        let token = UInt(bitPattern: registration.context)
        let entered = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Concurrent callbacks return")
        DispatchQueue(label: "display-callback.producer").async {
            entered.signal()
            for _ in 0..<1_000 {
                DisplayReconfigurationRegistration.handleCallback(context: UnsafeMutableRawPointer(bitPattern: token), flags: .movedFlag)
            }
            finished.fulfill()
        }
        guard entered.wait(timeout: .now() + 2) == .success else {
            XCTFail("Callback producer did not start")
            registration.stop()
            return
        }
        registration.stop()
        queue.sync {}
        let afterDrain = trace.count("resolve")
        guard XCTWaiter.wait(for: [finished], timeout: 2) == .completed else {
            XCTFail("Producer did not finish; do not inspect dependent state")
            return
        }
        queue.sync {}
        XCTAssertEqual(trace.count("resolve"), afterDrain)
    }

    private var noOpOperations: DisplayReconfigurationRegistration.Operations {
        .init(register: { _, _ in .success }, remove: { _, _ in .success })
    }

    private func makeApplication(trace: CallbackLifetimeTrace, queue: DispatchQueue, withDisplay: Bool = false) -> MacXeneonEdgeTouchDriverApplication {
        let effects = CallbackLifetimeEffects(trace: trace)
        return MacXeneonEdgeTouchDriverApplication(
            configuration: .defaults,
            displayResolver: DisplayResolver(activeDisplayProvider: {
                trace.record("resolve")
                guard withDisplay else { return [] }
                return [DisplaySnapshot(
                    displayID: 42, vendorNumber: CapturedXeneonDisplay.vendorNumber,
                    modelNumber: CapturedXeneonDisplay.modelNumber,
                    serialNumber: CapturedXeneonDisplay.observedSerialNumber,
                    bounds: CGRect(x: 100, y: 200, width: 2_560, height: 720),
                    pixelsWide: CapturedXeneonDisplay.expectedWidth, pixelsHigh: CapturedXeneonDisplay.expectedHeight
                )]
            }), inputSink: effects, cursorController: effects, focusRestorer: effects,
            scheduler: nil, gestureQueue: queue
        )
    }
}

private final class CallbackOperationSentinel {
    let trace: CallbackLifetimeTrace
    init(trace: CallbackLifetimeTrace) { self.trace = trace }
    deinit { trace.record(Thread.isMainThread ? "operations-released-main" : "operations-released-background") }
}
