import CoreGraphics
import Darwin
import Foundation
import IOKit
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Uses the application's real routing and teardown with fake startup and monitoring.
/// The virtual clock also delivers cancelled tasks to exercise stale completions.
final class CombinedStartupDisplayLifecycleTests: XCTestCase {
    func testPermissionRetryKeepsFocusReusableAndRejectsOldPreparation() {
        let fixture = CombinedStartupFixture()
        fixture.startup.permissions.currentSnapshot = .axReady
        fixture.startup.useFreshWorker = true
        fixture.startup.permissions.supportsFreshSnapshots = true
        fixture.startup.permissions.currentFreshSnapshot = SyntheticPermissionSnapshot(
            postEventAccess: true, accessibilityTrusted: true, hidInputAccess: .granted,
            requiresAccessibility: true)
        fixture.onStart = {
            if fixture.starts == 1 {
                fixture.onGestureQueue { fixture.send(.down) }
                throw HIDDeviceMonitorError.openFailed(kIOReturnNotPermitted)
            }
            fixture.acquired = true
            fixture.effects.events.append(.hardwareAcquired)
        }
        let result = fixture.run {
            XCTAssertEqual(fixture.starts, 1)
            XCTAssertEqual(fixture.stops, 1)
            XCTAssertEqual(fixture.effects.shutdownCount, 0,
                "A recoverable device-open failure must not permanently close focus")
            fixture.startup.polling.advance(bySeconds: 2)
            fixture.startup.freshWorker.runRequest()
            fixture.startup.freshWorker.completeRequest()
            XCTAssertEqual(fixture.starts, 2)
            fixture.onGestureQueue {
                fixture.effects.completePreparation(0)
                XCTAssertTrue(fixture.effects.input.isEmpty,
                    "Preparation selected before the failed open cannot post input later")
                fixture.send(.down)
                fixture.effects.completePreparation(1)
                fixture.send(.up)
            }
            XCTAssertEqual(fixture.effects.restores, [1])
            XCTAssertEqual(fixture.effects.input, [.down(combinedStartupOrigin), .up(combinedStartupOrigin)])
            XCTAssertEqual(fixture.effects.releases, [true])
            fixture.startup.signals.send(SIGTERM)
            fixture.startup.freshWorker.completeRequest()
            fixture.startup.polling.tasks.forEach { $0.deliverEvenIfCancelled() }
        }
        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(fixture.stops, 2)
        XCTAssertEqual(fixture.effects.shutdownCount, 1)
        fixture.effects.assertBalanced()
    }

    func testPermissionGrantRoutesValidDisplayTouchWhenFocusNeverBecomesReady() {
        let fixture = CombinedStartupFixture()
        let result = fixture.run {
            fixture.startup.worker.runRequest()
            fixture.startup.polling.advance(bySeconds: 600)
            XCTAssertEqual(fixture.starts, 0)
            XCTAssertEqual(fixture.displayReads, 0)
            XCTAssertTrue(fixture.effects.events.isEmpty)

            fixture.grantPermission()
            XCTAssertEqual(fixture.starts, 1)
            XCTAssertFalse(fixture.startup.permissions.currentSnapshot.accessibilityTrusted)
            fixture.onGestureQueue {
                fixture.send(.down)
                XCTAssertEqual(fixture.effects.preparationCount, 1)
                XCTAssertTrue(fixture.effects.input.isEmpty)
                fixture.clock.advance(toMilliseconds: 30)
                fixture.send(.up)
                fixture.effects.completePreparation(0)
            }

            XCTAssertEqual(fixture.effects.input, [.down(combinedStartupOrigin), .up(combinedStartupOrigin)])
            XCTAssertEqual(fixture.effects.releases, [true])
            XCTAssertEqual(fixture.effects.acceptedInputEndCount, 1)
            XCTAssertEqual(fixture.effects.inputEndCallCount, 2)
            XCTAssertTrue(fixture.effects.restores.isEmpty)
            fixture.startup.signals.send(SIGTERM)
            fixture.deliverStaleStartupCallbacks()
        }

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.stops, 1)
        fixture.effects.assertBalanced()
    }

    func testReadinessAndDisplayRoutingPreserveIndependentFocusAndCursorSettings() {
        for restoreFocus in [false, true] {
            for returnCursor in [false, true] {
                let fixture = CombinedStartupFixture(restoreFocus: restoreFocus, returnCursor: returnCursor)
                let result = fixture.run {
                    fixture.grantPermission(.axReady)
                    fixture.onGestureQueue {
                        fixture.send(.down)
                        if restoreFocus { fixture.effects.completePreparation(0) }
                        fixture.send(.up)
                    }
                    XCTAssertEqual(fixture.effects.input, [.down(combinedStartupOrigin), .up(combinedStartupOrigin)])
                    XCTAssertEqual(fixture.effects.releases, [returnCursor])
                    XCTAssertEqual(fixture.effects.preparationCount, restoreFocus ? 1 : 0)
                    XCTAssertEqual(fixture.effects.restores, restoreFocus ? [0] : [])
                    XCTAssertEqual(fixture.effects.inputEndCallCount, restoreFocus ? 2 : 0)
                    fixture.startup.signals.send(SIGTERM)
                    fixture.deliverStaleStartupCallbacks()
                }

                XCTAssertEqual(result, EXIT_SUCCESS)
                XCTAssertEqual(fixture.starts, 1)
                XCTAssertEqual(fixture.stops, 1)
                XCTAssertEqual(fixture.effects.shutdownCount, restoreFocus ? 1 : 0)
                fixture.effects.assertBalanced()
            }
        }
    }

    func testDisplayBeginBeforeReadinessBlocksTouchAndRejectsAnObsoleteQueuedEnd() {
        let fixture = CombinedStartupFixture()
        let result = fixture.run {
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
            fixture.onGestureQueue {}
            XCTAssertEqual(fixture.displayReads, 0)

            fixture.grantPermission()
            fixture.onGestureQueue { fixture.send(.down) }
            XCTAssertEqual(fixture.starts, 1)
            XCTAssertEqual(fixture.displayReads, 0, "Readiness must not resolve geometry during display begin")
            XCTAssertEqual(fixture.effects.preparationCount, 0)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            XCTAssertTrue(fixture.effects.borrows.isEmpty)

            // Queue both notifications before their handlers can run. Recording the
            // newer begin must invalidate the earlier end even though it is first in FIFO order.
            fixture.onGestureQueue {
                fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
                fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
            }
            fixture.onGestureQueue {
                fixture.send(.up)
                fixture.send(.down)
            }
            XCTAssertEqual(fixture.displayReads, 0)
            XCTAssertEqual(fixture.effects.preparationCount, 0)
            XCTAssertTrue(fixture.effects.input.isEmpty)

            fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
            fixture.onGestureQueue {
                fixture.send(.up)
                fixture.send(.down)
                fixture.effects.completePreparation(0)
                fixture.send(.up)
            }
            XCTAssertEqual(fixture.displayReads, 2, "Only the current end and accepted down resolve display state")
            XCTAssertEqual(fixture.effects.input, [.down(combinedStartupOrigin), .up(combinedStartupOrigin)])
            XCTAssertEqual(fixture.effects.releases, [true])
            XCTAssertEqual(fixture.effects.restores, [0])
            XCTAssertEqual(fixture.effects.inputEndCallCount, 2)
            fixture.startup.signals.send(SIGTERM)
            fixture.deliverStaleStartupCallbacks()
        }

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.stops, 1)
        fixture.effects.assertBalanced()
    }

    func testStopDuringPreparationInvalidatesLateFocusDisplayAndPermissionCallbacks() {
        for explicitStop in [false, true] {
            let fixture = CombinedStartupFixture()
            fixture.onStop = {
                fixture.onGestureQueue {
                    fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
                }
            }
            let result = fixture.run {
                fixture.grantPermission()
                fixture.onGestureQueue { fixture.send(.down) }
                XCTAssertEqual(fixture.effects.preparationCount, 1)

                if explicitStop { fixture.application.stop() }
                else { fixture.startup.signals.send(SIGTERM) }

                fixture.effects.assertShutdownPrecedesHardwareStop()
                let stoppedEvents = fixture.effects.events
                fixture.deliverStaleStartupCallbacks()
                fixture.onGestureQueue {
                    fixture.effects.completePreparation(0)
                    fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
                    fixture.clock.advance(toMilliseconds: 2_000)
                    fixture.effects.completePreparation(0)
                }
                XCTAssertEqual(fixture.effects.events, stoppedEvents)
            }

            XCTAssertEqual(result, EXIT_SUCCESS)
            XCTAssertEqual(fixture.starts, 1)
            XCTAssertEqual(fixture.stops, 1)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            XCTAssertTrue(fixture.effects.borrows.isEmpty)
            XCTAssertTrue(fixture.effects.releases.isEmpty)
            XCTAssertTrue(fixture.effects.restores.isEmpty)
            XCTAssertEqual(fixture.effects.inputEndCallCount, 0)
        }
    }

    func testSignalStopWithOrWithoutDisplayBeginReleasesEveryOwnedGesturePhaseOnce() {
        for phase in CombinedStartupPhase.allCases {
            for restoreFocus in [false, true] {
                for returnCursor in [false, true] {
                    for displayBeginDuringStop in [false, true] {
                        let fixture = CombinedStartupFixture(
                            restoreFocus: restoreFocus, returnCursor: returnCursor, phase: phase
                        )
                        if displayBeginDuringStop {
                            fixture.onStop = {
                                fixture.onGestureQueue {
                                    fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
                                }
                            }
                        }
                        let result = fixture.run {
                            fixture.grantPermission()
                            fixture.onGestureQueue {
                                fixture.send(.down)
                                if restoreFocus { fixture.effects.completePreparation(0) }
                                if phase == .waitingForMouseUp || phase == .waitingForCursorReturn {
                                    fixture.send(.up)
                                    XCTAssertEqual(fixture.effects.acceptedInputEndCount, restoreFocus ? 1 : 0)
                                    XCTAssertEqual(fixture.effects.inputEndCallCount, !restoreFocus ? 0 :
                                        (phase == .waitingForMouseUp ? 1 : 2))
                                }
                            }

                            fixture.startup.signals.send(SIGTERM)
                            if restoreFocus { fixture.effects.assertShutdownPrecedesHardwareStop() }
                            let stoppedEvents = fixture.effects.events
                            fixture.deliverStaleStartupCallbacks()
                            fixture.onGestureQueue {
                                if restoreFocus { fixture.effects.completePreparation(0) }
                                fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
                                fixture.clock.advance(toMilliseconds: 2_000)
                            }
                            XCTAssertEqual(fixture.effects.events, stoppedEvents)
                        }

                        XCTAssertEqual(result, EXIT_SUCCESS)
                        XCTAssertEqual(fixture.starts, 1)
                        XCTAssertEqual(fixture.stops, 1)
                        XCTAssertEqual(fixture.effects.borrows, [combinedStartupOrigin])
                        XCTAssertEqual(fixture.effects.releases, [returnCursor])
                        XCTAssertEqual(fixture.effects.input, phase == .waitingForMouseDown ? [] : [
                            .down(combinedStartupOrigin), .up(combinedStartupOrigin)
                        ])
                        XCTAssertEqual(fixture.effects.acceptedInputEndCount,
                                       restoreFocus && phase != .waitingForMouseDown ? 1 : 0)
                        let expectedEndCalls: Int
                        switch phase {
                        case .waitingForMouseDown: expectedEndCalls = 0
                        case .holdingMouseDown: expectedEndCalls = 1
                        case .waitingForMouseUp, .waitingForCursorReturn: expectedEndCalls = 2
                        }
                        XCTAssertEqual(fixture.effects.inputEndCallCount, restoreFocus ? expectedEndCalls : 0)
                        XCTAssertTrue(fixture.effects.restores.isEmpty)
                        fixture.effects.assertBalanced()
                    }
                }
            }
        }
    }

    func testNestedStopDuringAcquisitionDefersCleanupAfterDisplayBeginAndKeepsSuccess() {
        for explicitStop in [false, true] {
            for throwsAfterStop in [false, true] {
                let fixture = CombinedStartupFixture()
                fixture.onStart = {
                    fixture.onGestureQueue {
                        fixture.send(.down)
                        fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
                    }
                    if explicitStop { fixture.application.stop() }
                    else { fixture.startup.signals.send(SIGTERM) }
                    XCTAssertEqual(fixture.stops, 0, "Acquisition must unwind before resource release")
                    fixture.acquired = true
                    fixture.effects.events.append(.hardwareAcquired)
                    if throwsAfterStop { throw CombinedStartupError.acquisition }
                }
                let result = fixture.run {
                    fixture.grantPermission()
                    XCTAssertFalse(fixture.acquired)
                    XCTAssertEqual(fixture.stops, 1)
                    let stoppedEvents = fixture.effects.events
                    fixture.deliverStaleStartupCallbacks()
                    fixture.onGestureQueue {
                        fixture.effects.completePreparation(0)
                        fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
                        fixture.clock.advance(toMilliseconds: 2_000)
                    }
                    XCTAssertEqual(fixture.effects.events, stoppedEvents)
                }

                XCTAssertEqual(result, EXIT_SUCCESS, "Intentional stop wins over the later acquisition error")
                XCTAssertEqual(fixture.starts, 1)
                XCTAssertEqual(fixture.stops, 1)
                XCTAssertFalse(fixture.acquired)
                fixture.effects.assertShutdownPrecedesHardwareStop()
                let acquisition = fixture.effects.events.firstIndex(of: .hardwareAcquired)
                let cleanup = fixture.effects.events.firstIndex(of: .hardwareStopped)
                XCTAssertNotNil(acquisition)
                XCTAssertNotNil(cleanup)
                if let acquisition, let cleanup { XCTAssertLessThan(acquisition, cleanup) }
                XCTAssertTrue(fixture.effects.input.isEmpty)
                XCTAssertTrue(fixture.effects.borrows.isEmpty)
                XCTAssertTrue(fixture.effects.restores.isEmpty)
            }
        }
    }

    func testFailedAcquisitionCancelsPreparedDisplayGestureAndNeverRetriesReadiness() {
        let fixture = CombinedStartupFixture()
        fixture.onStart = {
            fixture.onGestureQueue { fixture.send(.down) }
            fixture.acquired = true
            fixture.effects.events.append(.hardwareAcquired)
            throw CombinedStartupError.acquisition
        }
        let result = fixture.run {
            fixture.grantPermission()
            let stoppedEvents = fixture.effects.events
            fixture.deliverStaleStartupCallbacks()
            fixture.onGestureQueue {
                fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
                fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
                fixture.effects.completePreparation(0)
                fixture.clock.advance(toMilliseconds: 2_000)
            }
            // Display cancellation may repeat idempotent idle cleanup; it cannot acquire input.
            XCTAssertEqual(fixture.effects.input, stoppedEvents.filter(\.isInput))
        }

        XCTAssertEqual(result, EXIT_FAILURE)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertFalse(fixture.acquired)
        fixture.effects.assertShutdownPrecedesHardwareStop()
        XCTAssertTrue(fixture.effects.input.isEmpty)
        XCTAssertTrue(fixture.effects.borrows.isEmpty)
        XCTAssertTrue(fixture.effects.releases.isEmpty)
        XCTAssertTrue(fixture.effects.restores.isEmpty)
    }
}

private enum CombinedStartupPhase: CaseIterable {
    case waitingForMouseDown, holdingMouseDown, waitingForMouseUp, waitingForCursorReturn
}

private enum CombinedStartupError: Error { case acquisition }
private let combinedStartupOrigin = CGPoint(x: -2_560, y: 200)

private final class CombinedStartupFixture {
    let startup = StartupTestHarness()
    let effects = CombinedStartupEffects()
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let gestureQueue = DispatchQueue(label: "combined-startup-display-test")
    let configuration: DriverConfiguration
    var displayReads = 0
    var starts = 0
    var stops = 0
    var acquired = false
    var onStart: (() throws -> Void)?
    var onStop: (() -> Void)?

    lazy var application: MacXeneonEdgeTouchDriverApplication = MacXeneonEdgeTouchDriverApplication(
        configuration: configuration,
        displayResolver: DisplayResolver(activeDisplayProvider: { [unowned self] in
            displayReads += 1
            return [DisplaySnapshot(
                displayID: 42,
                vendorNumber: CapturedXeneonDisplay.vendorNumber,
                modelNumber: CapturedXeneonDisplay.modelNumber,
                serialNumber: CapturedXeneonDisplay.observedSerialNumber,
                bounds: CGRect(origin: combinedStartupOrigin, size: CGSize(width: 2_560, height: 720)),
                pixelsWide: 2_560,
                pixelsHigh: 720
            )]
        }),
        inputSink: effects,
        cursorController: effects,
        focusRestorer: effects,
        startupDependencies: startup.dependencies,
        monitoringOverride: DriverMonitoringHooks(
            start: { [unowned self] in
                starts += 1
                effects.events.append(.hardwareStarted)
                onGestureQueue { application.handleDeviceMatched() }
                try onStart?()
            },
            stop: { [unowned self] in
                stops += 1
                acquired = false
                effects.events.append(.hardwareStopped)
                onStop?()
            }
        ),
        scheduler: clock,
        gestureQueue: gestureQueue
    )

    init(restoreFocus: Bool = true, returnCursor: Bool = true, phase: CombinedStartupPhase? = nil) {
        var configuration = DriverConfiguration.defaults
        configuration.focus.restorePreviousWindow = restoreFocus
        configuration.cursor.returnToPreviousPosition = returnCursor
        configuration.timing.warpToClickDelayMs = phase == .waitingForMouseDown ? 40 : 0
        configuration.timing.downToUpDelayMs = phase == .waitingForMouseUp ? 40 : 0
        configuration.timing.clickToWarpBackDelayMs = phase == .waitingForCursorReturn ? 40 : 0
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = 1_000
        self.configuration = configuration
    }

    func run(_ body: @escaping () -> Void) -> Int32 {
        startup.runLoop.onRun = body
        defer {
            startup.runLoop.onRun = nil
            onStart = nil
            onStop = nil
        }
        return application.run()
    }

    func grantPermission(_ snapshot: SyntheticPermissionSnapshot = .cgReady) {
        startup.permissions.currentSnapshot = snapshot
        startup.polling.advance(bySeconds: 2)
    }

    func deliverStaleStartupCallbacks() {
        let readsAtStop = startup.permissions.snapshotCount
        startup.permissions.currentSnapshot = .cgReady
        startup.worker.runRequest()
        startup.worker.completeRequest()
        startup.polling.tasks.forEach { $0.deliverEvenIfCancelled() }
        XCTAssertEqual(startup.permissions.snapshotCount, readsAtStop)
        XCTAssertTrue(startup.polling.tasks.allSatisfy(\.isCancelled))
    }

    func onGestureQueue(_ body: () -> Void) { gestureQueue.sync(execute: body) }

    /// Called only on the injected gesture queue, like HID callbacks in production.
    func send(_ kind: TouchEvent.Kind) {
        application.handleTouchEvent(TouchEvent(
            kind: kind, contactID: 0,
            rawX: XeneonEdgeDevice.rawXRange.lowerBound,
            rawY: XeneonEdgeDevice.rawYRange.lowerBound,
            timestamp: clock.now
        ))
    }
}

private enum CombinedStartupEvent: Equatable {
    case hardwareStarted, hardwareAcquired, hardwareStopped
    case prepare, discard, inputEnded, shutdown
    case restore(Int)
    case down(CGPoint), up(CGPoint), drag(CGPoint), borrow(CGPoint)
    case release(Bool), show

    var isInput: Bool {
        switch self {
        case .down, .up, .drag: return true
        default: return false
        }
    }
}

/// Records operations in memory; it does not invoke AX, CoreGraphics or HID.
private final class CombinedStartupEffects: SyntheticInputSink, CursorController, FocusRestorer {
    var events: [CombinedStartupEvent] = []
    private var generation = 0
    private var captured: Int?
    private var inputEnded = false
    private var closed = false
    private var completions: [(generation: Int, completion: () -> Void)] = []
    private(set) var acceptedInputEndCount = 0
    private(set) var inputEndCallCount = 0
    var preparationCount: Int { completions.count }
    var input: [CombinedStartupEvent] { events.filter(\.isInput) }
    var borrows: [CGPoint] { events.compactMap { if case .borrow(let point) = $0 { return point }; return nil } }
    var releases: [Bool] { events.compactMap { if case .release(let value) = $0 { return value }; return nil } }
    var restores: [Int] { events.compactMap { if case .restore(let index) = $0 { return index }; return nil } }
    var shutdownCount: Int { events.filter { $0 == .shutdown }.count }

    func prepareFocusedWindow(completion: @escaping () -> Void) {
        XCTAssertFalse(closed, "Stopped focus dependency must not start another capture")
        generation += 1
        captured = nil
        inputEnded = false
        events.append(.prepare)
        completions.append((generation, completion))
    }

    func completePreparation(_ index: Int) {
        guard completions.indices.contains(index) else {
            XCTFail("Missing expected focus preparation")
            return
        }
        let callback = completions[index]
        if !closed, callback.generation == generation { captured = index }
        callback.completion()
    }

    func captureFocusedWindow() { XCTFail("Application should use bounded focus preparation") }
    func inputDidEnd() {
        inputEndCallCount += 1
        events.append(.inputEnded)
        guard !inputEnded else { return }
        inputEnded = true
        acceptedInputEndCount += 1
    }
    func restoreCapturedWindow() {
        if let captured { events.append(.restore(captured)) }
        captured = nil
        generation += 1
    }
    func discardCapturedWindow() {
        captured = nil
        generation += 1
        events.append(.discard)
    }
    func shutdown() {
        closed = true
        captured = nil
        generation += 1
        events.append(.shutdown)
    }
    func postMouseDown(at point: CGPoint) { events.append(.down(point)) }
    func postMouseUp(at point: CGPoint) { events.append(.up(point)) }
    func postMouseDragged(to point: CGPoint) { events.append(.drag(point)) }
    func borrow(warpingTo point: CGPoint) -> Bool { events.append(.borrow(point)); return true }
    func updatePosition(_ point: CGPoint) {}
    func releaseBorrow(returnToPreviousPosition: Bool) { events.append(.release(returnToPreviousPosition)) }
    func returnToOrigin() { XCTFail("Application must use policy-aware cursor release") }
    func forceShow() { events.append(.show) }

    func assertShutdownPrecedesHardwareStop(file: StaticString = #filePath, line: UInt = #line) {
        guard let shutdown = events.firstIndex(of: .shutdown),
              let stop = events.firstIndex(of: .hardwareStopped) else {
            XCTFail("Expected both focus shutdown and hardware stop", file: file, line: line)
            return
        }
        XCTAssertLessThan(shutdown, stop, file: file, line: line)
    }

    func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
        var pressed = false
        for event in input {
            switch event {
            case .down:
                XCTAssertFalse(pressed, "Mouse down overlaps an owned button", file: file, line: line)
                pressed = true
            case .up:
                XCTAssertTrue(pressed, "Mouse up has no owned button", file: file, line: line)
                pressed = false
            case .drag:
                XCTAssertTrue(pressed, "Drag has no owned button", file: file, line: line)
            default: break
            }
        }
        XCTAssertFalse(pressed, "Cleanup left the button held", file: file, line: line)
        XCTAssertEqual(borrows.count, releases.count, "Cleanup left the cursor borrowed", file: file, line: line)
    }
}
