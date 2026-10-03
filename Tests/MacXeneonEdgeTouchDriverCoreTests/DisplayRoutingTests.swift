import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DisplayRoutingTests: XCTestCase {
    func testPreviouslyRefreshedResolverStillInstallsTheApplicationsMapper() {
        let fixture = RoutingFixture(initiallyResolved: true)

        fixture.send(.down)
        fixture.send(.up)

        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
        XCTAssertEqual(fixture.provider.readCount, 1)
    }

    func testPreviouslyRefreshedResolverIsClearedWhenFirstApplicationMatchIsMissing() {
        let fixture = RoutingFixture(initiallyResolved: true, displaysBeforeFirstMatch: [])

        XCTAssertNil(fixture.resolver.currentSnapshot)
        XCTAssertNil(fixture.resolver.currentBounds)
        XCTAssertNil(fixture.resolver.currentMapper)

        fixture.send(.down)
        fixture.send(.up)

        XCTAssertTrue(fixture.recorder.input.isEmpty)
        XCTAssertEqual(fixture.provider.readCount, 1)
    }

    func testNewDownReadsProviderOnceAndCommitsThatExactSnapshot() {
        let fixture = RoutingFixture()
        let selected = display(at: movedOrigin)
        let later = display(at: CGPoint(x: -800, y: -600))
        fixture.provider.scriptedReads = [[selected], [later]]

        fixture.send(.down)

        XCTAssertEqual(fixture.provider.readCount, 1)
        XCTAssertEqual(fixture.resolver.currentSnapshot, selected)
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin)])
        fixture.send(.up)
        XCTAssertEqual(fixture.provider.readCount, 1, "An up uses the accepted contact's mapping")
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
    }

    func testUnchangedReconfigurationDoesNotCancelHeldDrag() {
        let fixture = RoutingFixture()
        fixture.send(.down)
        fixture.send(.move, far: true)
        let beforeRefresh = fixture.recorder.calls

        fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
        fixture.application.handleDeviceMatched()

        XCTAssertEqual(fixture.recorder.calls, beforeRefresh)
        XCTAssertEqual(fixture.provider.readCount, 3)
        fixture.send(.up, far: true)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .drag(farPoint), .up(farPoint)])
        XCTAssertEqual(fixture.recorder.returnCount, 1)
    }

    func testUnchangedSnapshotPreservesDelayedUpAndCursorReturn() {
        let fixture = RoutingFixture(upDelay: 40, returnDelay: 80)
        fixture.send(.down)
        fixture.send(.up, at: 1)
        fixture.clock.advance(toMilliseconds: 10)
        let beforeRefresh = fixture.recorder.calls

        fixture.application.handleDisplayReconfiguration(flags: .setModeFlag)

        XCTAssertEqual(fixture.recorder.calls, beforeRefresh)
        fixture.clock.advance(toMilliseconds: 41)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
        XCTAssertEqual(fixture.recorder.returnCount, 0)
        fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
        fixture.clock.advance(toMilliseconds: 120)
        XCTAssertEqual(fixture.recorder.returnCount, 0)
        fixture.clock.advance(toMilliseconds: 121)
        XCTAssertEqual(fixture.recorder.returnCount, 1)
        XCTAssertEqual(fixture.recorder.restoreCount, 1)
    }

    func testMissingTargetDropsNewInputAndCanRecoverOnLaterDown() {
        let fixture = RoutingFixture()
        fixture.provider.displays = []

        fixture.send(.down)
        fixture.send(.move, far: true)
        fixture.send(.up, far: true)

        XCTAssertNil(fixture.resolver.currentSnapshot)
        XCTAssertNil(fixture.resolver.currentMapper)
        XCTAssertTrue(fixture.recorder.input.isEmpty)
        XCTAssertEqual(fixture.provider.readCount, 1)

        fixture.provider.displays = [display(at: movedOrigin)]
        fixture.send(.down, at: 1)
        fixture.send(.up, at: 2)

        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
        XCTAssertEqual(fixture.provider.readCount, 2)
    }

    func testInvalidBoundsCannotReuseThePreviousMapping() {
        for bounds in [
            CGRect(x: 100, y: 200, width: 0, height: 720),
            CGRect(x: CGFloat.infinity, y: 200, width: 2_560, height: 720),
            CGRect(x: 100, y: 200, width: 2_560, height: CGFloat.nan),
        ] {
            let fixture = RoutingFixture()
            fixture.provider.displays = [display(bounds: bounds)]

            fixture.send(.down)
            fixture.send(.up)

            XCTAssertNil(fixture.resolver.currentMapper, "Invalid bounds: \(bounds)")
            XCTAssertTrue(fixture.recorder.input.isEmpty, "Invalid bounds: \(bounds)")
            XCTAssertEqual(fixture.provider.readCount, 1)
        }
    }

    func testRepeatedLossDoesNotRepeatGestureCleanup() {
        let fixture = RoutingFixture()
        fixture.send(.down)
        fixture.provider.displays = []
        fixture.application.handleDisplayReconfiguration(flags: .removeFlag)
        let afterLoss = fixture.recorder.calls

        fixture.application.handleDisplayReconfiguration(flags: .removeFlag)
        fixture.application.handleDeviceMatched()
        fixture.send(.up)

        XCTAssertEqual(fixture.recorder.calls, afterLoss)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
        XCTAssertEqual(fixture.recorder.returnCount, 1)
        XCTAssertEqual(fixture.recorder.restoreCount, 1)
    }

    func testLossThenRematchReleasesAndReturnsBeforeRecoveredTouch() {
        let fixture = RoutingFixture(upDelay: 40, returnDelay: 80, timeout: 200)
        fixture.send(.down)
        fixture.send(.up, at: 1)
        fixture.clock.advance(toMilliseconds: 10)
        fixture.provider.displays = []

        fixture.application.handleDisplayReconfiguration(flags: .removeFlag)
        fixture.provider.displays = [display(at: movedOrigin)]
        fixture.application.handleDeviceMatched()
        fixture.send(.down)

        XCTAssertEqual(fixture.recorder.gestureCalls, [
            .capture, .borrow(origin), .down(origin), .up(origin), .returned, .restore,
            .capture, .borrow(movedOrigin), .down(movedOrigin),
        ])

        // The scheduler delivers cancelled work, including the old up and watchdog.
        fixture.clock.advance(toMilliseconds: 201)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin)])
        XCTAssertEqual(fixture.recorder.returnCount, 1)
        fixture.send(.up)
        fixture.clock.advance(toMilliseconds: 321)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin), .up(movedOrigin)])
        XCTAssertEqual(fixture.recorder.returnCount, 2)
        XCTAssertEqual(fixture.recorder.restoreCount, 2)
    }

    func testLossCleanupCannotBeQueuedBehindRematchAndNewDown() {
        let queue = DispatchQueue(label: "display-routing-order-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        queue.sync {
            fixture.send(.down)
            fixture.provider.displays = []
            fixture.application.handleDisplayReconfiguration(flags: .removeFlag)
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
            fixture.provider.displays = [display(at: movedOrigin)]
            fixture.application.handleDeviceMatched()
            fixture.send(.down)
        }
        // Anything appended by loss handling must execute before this next queue block.
        queue.sync {
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin)])
            XCTAssertEqual(fixture.recorder.returnCount, 1)
            fixture.send(.move, far: true)
            fixture.send(.up, far: true)
            let point = CGPoint(x: movedOrigin.x + 2_560, y: movedOrigin.y + 720)
            XCTAssertEqual(fixture.recorder.input.suffix(2), [.drag(point), .up(point)])
        }
    }

    func testBeginArrivalBlocksAnOlderQueuedDownBeforeBeginHandlerRuns() {
        let queue = DispatchQueue(label: "display-routing-queued-down-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        fixture.provider.displays = [display(at: movedOrigin)]

        withBlockedQueue(queue) {
            queue.async { fixture.send(.down) }
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        waitForQueue(queue)

        XCTAssertEqual(fixture.provider.readCount, 0, "Queued down must not read transient geometry")
        XCTAssertTrue(fixture.recorder.input.isEmpty)
        XCTAssertFalse(fixture.recorder.calls.contains(.borrow(movedOrigin)))
        XCTAssertNil(fixture.resolver.currentMapper)

        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.up)
            fixture.send(.down, at: 1)
            fixture.send(.up, at: 2)
        }
        waitForQueue(queue)

        XCTAssertEqual(fixture.provider.readCount, 2)
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
    }

    func testBeginArrivalBlocksPendingMouseDownAheadOfBeginHandler() {
        let queue = DispatchQueue(label: "display-routing-pending-down-test")
        let fixture = RoutingFixture(warpDelay: 40, gestureQueue: queue)
        queue.async { fixture.send(.down) }
        waitForQueue(queue)
        fixture.provider.displays = [display(at: movedOrigin)]

        withBlockedQueue(queue) {
            queue.async { fixture.clock.advance(toMilliseconds: 40) }
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        waitForQueue(queue)

        XCTAssertTrue(fixture.recorder.input.isEmpty, "Due mouse-down must observe the begin arrival immediately")
        XCTAssertEqual(fixture.recorder.returnCount, 1)
        if let discard = fixture.recorder.calls.firstIndex(of: .discard),
           let restore = fixture.recorder.calls.firstIndex(of: .restore) {
            XCTAssertLessThan(discard, restore, "Invalid geometry must discard captured focus before cancellation restores it")
        } else {
            XCTFail("Expected focus invalidation and gesture cleanup")
        }

        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.down, at: 41)
            // Deliver the cancelled old watchdog while the recovered contact remains held.
            fixture.clock.advance(toMilliseconds: 1_000)
        }
        waitForQueue(queue)
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin)])
        XCTAssertEqual(fixture.recorder.returnCount, 1)

        queue.async {
            fixture.send(.up, at: 1_001)
            fixture.clock.advance(toMilliseconds: 2_000)
        }
        waitForQueue(queue)
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
        XCTAssertEqual(fixture.recorder.returnCount, 2)
    }

    func testOlderQueuedEndCannotResolveDuringANewerBegin() {
        let queue = DispatchQueue(label: "display-routing-stale-end-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        queue.async {
            fixture.send(.down)
            fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        waitForQueue(queue)
        let readsBeforeQueuedEnd = fixture.provider.readCount
        fixture.provider.displays = [display(at: CGPoint(x: 900, y: -800))]

        withBlockedQueue(queue) {
            fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
            queue.async { fixture.send(.down) }
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        waitForQueue(queue)

        XCTAssertEqual(fixture.provider.readCount, readsBeforeQueuedEnd)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
        XCTAssertNil(fixture.resolver.currentMapper)

        fixture.provider.displays = [display(at: movedOrigin)]
        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.up)
            fixture.send(.down, at: 1)
            fixture.clock.advance(toMilliseconds: 1_000)
        }
        waitForQueue(queue)

        XCTAssertEqual(fixture.provider.readCount, readsBeforeQueuedEnd + 2)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin)])
        XCTAssertEqual(fixture.recorder.returnCount, 1)
        queue.async { fixture.send(.up) }
        waitForQueue(queue)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin), .up(movedOrigin)])
        XCTAssertEqual(fixture.recorder.returnCount, 2)
    }

    func testBeginArrivalDuringResolutionPreventsCommittingThatSnapshot() {
        let queue = DispatchQueue(label: "display-routing-resolve-race-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        fixture.provider.displays = [display(at: CGPoint(x: 900, y: -800))]
        fixture.provider.onRead = {
            fixture.provider.onRead = nil
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
        }

        queue.async { fixture.send(.down) }
        // The provider enqueues a begin while the down is running; drain that nested work too.
        waitForQueue(queue)
        waitForQueue(queue)

        XCTAssertEqual(fixture.provider.readCount, 1)
        XCTAssertNil(fixture.resolver.currentSnapshot)
        XCTAssertTrue(fixture.recorder.input.isEmpty)

        fixture.provider.displays = [display(at: movedOrigin)]
        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.up)
            fixture.send(.down, at: 1)
            fixture.send(.up, at: 2)
        }
        waitForQueue(queue)

        XCTAssertEqual(fixture.provider.readCount, 3)
        XCTAssertEqual(fixture.resolver.currentBounds?.origin, movedOrigin)
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
    }

    private func withBlockedQueue(_ queue: DispatchQueue, enqueue: () -> Void) {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + .seconds(2)), .success)
        }
        guard entered.wait(timeout: .now() + .seconds(2)) == .success else {
            release.signal()
            XCTFail("Gesture queue did not reach the test barrier")
            return
        }
        defer { release.signal() }
        enqueue()
    }

    private func waitForQueue(_ queue: DispatchQueue) {
        let drained = expectation(description: "Gesture queue drained")
        queue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testDisplayIdentityChangeCancelsDragEvenWhenBoundsAreUnchanged() {
        let fixture = RoutingFixture()
        fixture.send(.down)
        fixture.send(.move, far: true)
        let replacement = display(id: 99)
        fixture.provider.displays = [replacement]

        fixture.application.handleDisplayReconfiguration(flags: .addFlag)

        XCTAssertEqual(fixture.resolver.currentSnapshot, replacement)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .drag(farPoint), .up(farPoint)])
        XCTAssertEqual(fixture.recorder.returnCount, 1)
        fixture.send(.down, at: 1)
        fixture.send(.up, at: 2)
        XCTAssertEqual(fixture.recorder.input.suffix(2), [.down(origin), .up(origin)])
    }

    func testBeginPhaseInvalidatesWithoutReadingTransientGeometry() {
        let fixture = RoutingFixture()
        fixture.send(.down)
        fixture.provider.displays = [display(at: movedOrigin)]
        let readsBeforeBegin = fixture.provider.readCount

        fixture.application.handleDisplayReconfiguration(flags: [.beginConfigurationFlag, .movedFlag])

        XCTAssertEqual(fixture.provider.readCount, readsBeforeBegin)
        XCTAssertNil(fixture.resolver.currentMapper)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
        XCTAssertEqual(fixture.recorder.returnCount, 1)
        fixture.send(.down, at: 1)
        fixture.application.handleDeviceMatched()
        fixture.send(.move, at: 2)
        fixture.send(.up, at: 3)
        XCTAssertEqual(fixture.provider.readCount, readsBeforeBegin)
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])

        fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
        XCTAssertEqual(fixture.provider.readCount, readsBeforeBegin + 1)
        XCTAssertEqual(fixture.resolver.currentBounds?.origin, movedOrigin)
        fixture.send(.down, at: 4)
        fixture.send(.up, at: 5)
        XCTAssertEqual(fixture.recorder.input.suffix(2), [.down(movedOrigin), .up(movedOrigin)])
    }

    func testFirstPostChangeCallbackSettlesUnequalBeginAndEndCounts() {
        // CoreGraphics reports each online display, so callback counts need not balance.
        for (beginCount, endCount) in [(3, 1), (1, 3)] {
            let fixture = RoutingFixture()
            fixture.send(.down)
            fixture.provider.displays = [display(at: movedOrigin)]
            let readsBeforeBegin = fixture.provider.readCount
            for _ in 0..<beginCount {
                fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
            }
            XCTAssertEqual(fixture.provider.readCount, readsBeforeBegin)
            XCTAssertEqual(fixture.recorder.returnCount, 1)

            fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
            fixture.send(.down, at: 1)
            let afterRecovery = fixture.recorder.calls
            for _ in 1..<endCount {
                fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
            }

            XCTAssertEqual(fixture.recorder.calls, afterRecovery)
            XCTAssertEqual(fixture.provider.readCount, readsBeforeBegin + endCount + 1)
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin)])
            fixture.send(.up, at: 2)
            XCTAssertEqual(fixture.recorder.returnCount, 2)
        }
    }

    func testPostChangeLossRemainsUnavailableUntilAValidNewDownSnapshot() {
        let fixture = RoutingFixture()
        fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
        fixture.provider.displays = []
        fixture.application.handleDisplayReconfiguration(flags: .removeFlag)
        fixture.send(.down)
        fixture.send(.up)
        XCTAssertNil(fixture.resolver.currentMapper)
        XCTAssertTrue(fixture.recorder.input.isEmpty)

        fixture.provider.displays = [display(at: movedOrigin)]
        fixture.send(.down, at: 1)
        fixture.send(.up, at: 2)
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
    }

    func testMappingChangeCancelsEveryDelayedPhaseBeforeReplacementInput() {
        for phase in RoutingPhase.allCases {
            assertRecovery(from: phase, throughLoss: false)
        }
    }

    func testMappingLossCancelsEveryDelayedPhaseAndCleansUpWithoutAMapper() {
        for phase in RoutingPhase.allCases {
            assertRecovery(from: phase, throughLoss: true)
        }
    }

    private func assertRecovery(
        from phase: RoutingPhase,
        throughLoss: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fixture = RoutingFixture(
            warpDelay: phase == .pendingDown ? 40 : 0,
            upDelay: phase == .delayedUp ? 40 : 0,
            returnDelay: 80
        )
        fixture.send(.down)
        if phase == .heldDrag {
            fixture.send(.move, at: 1, far: true)
        } else if phase == .delayedUp || phase == .cursorReturn {
            fixture.send(.up, at: 1)
        }
        fixture.clock.advance(toMilliseconds: 10)
        let replacement = display(at: movedOrigin)
        fixture.provider.displays = throughLoss ? [] : [replacement]

        fixture.application.handleDisplayReconfiguration(flags: .movedFlag)

        let oldPoint = phase == .heldDrag ? farPoint : origin
        let oldInput: [RoutingCall] = phase == .pendingDown ? [] : (
            phase == .heldDrag ? [.down(origin), .drag(oldPoint), .up(oldPoint)] : [.down(origin), .up(origin)]
        )
        XCTAssertEqual(fixture.recorder.input, oldInput, "Phase: \(phase)", file: file, line: line)
        XCTAssertEqual(fixture.recorder.returnCount, 1, "Phase: \(phase)", file: file, line: line)
        XCTAssertEqual(fixture.recorder.restoreCount, 1, "Phase: \(phase)", file: file, line: line)

        if throughLoss {
            XCTAssertNil(fixture.resolver.currentMapper, file: file, line: line)
            fixture.send(.up)
            fixture.application.handleDeviceRemoval()
            XCTAssertEqual(fixture.recorder.input, oldInput, file: file, line: line)
            XCTAssertEqual(fixture.recorder.returnCount, 1, file: file, line: line)
            fixture.provider.displays = [replacement]
            fixture.application.handleDeviceMatched()
        }

        fixture.send(.down, at: 11)
        fixture.clock.advance(toMilliseconds: 40)
        let beforeNewPress = phase == .pendingDown ? oldInput : oldInput + [.down(movedOrigin)]
        XCTAssertEqual(fixture.recorder.input, beforeNewPress, file: file, line: line)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.recorder.input, oldInput + [.down(movedOrigin)], file: file, line: line)
        XCTAssertEqual(fixture.recorder.returnCount, 1, "Stale cleanup must not return the new cursor", file: file, line: line)
        XCTAssertEqual(fixture.recorder.restoreCount, 1, file: file, line: line)
        fixture.send(.up, at: 101)
        fixture.clock.advance(toMilliseconds: 221)
        XCTAssertEqual(fixture.recorder.input, oldInput + [.down(movedOrigin), .up(movedOrigin)], file: file, line: line)
        XCTAssertEqual(fixture.recorder.returnCount, 2, file: file, line: line)
        XCTAssertEqual(fixture.recorder.restoreCount, 2, file: file, line: line)
    }
}

private enum RoutingPhase: CaseIterable {
    case pendingDown
    case heldDrag
    case delayedUp
    case cursorReturn
}

private let origin = CGPoint(x: 100, y: 200)
private let farPoint = CGPoint(x: 2_660, y: 920)
private let movedOrigin = CGPoint(x: -2_560, y: 500)

private func display(id: CGDirectDisplayID = 42, at point: CGPoint = origin) -> DisplaySnapshot {
    display(id: id, bounds: CGRect(origin: point, size: CGSize(width: 2_560, height: 720)))
}

private func display(id: CGDirectDisplayID = 42, bounds: CGRect) -> DisplaySnapshot {
    DisplaySnapshot(
        displayID: id,
        vendorNumber: CapturedXeneonDisplay.vendorNumber,
        modelNumber: CapturedXeneonDisplay.modelNumber,
        serialNumber: CapturedXeneonDisplay.observedSerialNumber,
        bounds: bounds,
        pixelsWide: CapturedXeneonDisplay.expectedWidth,
        pixelsHigh: CapturedXeneonDisplay.expectedHeight
    )
}

private final class RoutingDisplayProvider {
    var displays = [display()]
    var scriptedReads: [[DisplaySnapshot]] = []
    var onRead: (() -> Void)?
    var readCount = 0

    func read() -> [DisplaySnapshot] {
        readCount += 1
        onRead?()
        return scriptedReads.isEmpty ? displays : scriptedReads.removeFirst()
    }
}

private struct RoutingFixture {
    let application: MacXeneonEdgeTouchDriverApplication
    let resolver: DisplayResolver
    let provider: RoutingDisplayProvider
    let clock: TestGestureScheduler
    let recorder: RoutingRecorder

    init(
        warpDelay: Int = 0,
        upDelay: Int = 0,
        returnDelay: Int = 0,
        timeout: Int = 1_000,
        initiallyResolved: Bool = false,
        displaysBeforeFirstMatch: [DisplaySnapshot]? = nil,
        gestureQueue: DispatchQueue? = nil
    ) {
        var configuration = DriverConfiguration.defaults
        configuration.timing.warpToClickDelayMs = warpDelay
        configuration.timing.downToUpDelayMs = upDelay
        configuration.timing.clickToWarpBackDelayMs = returnDelay
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = timeout
        let provider = RoutingDisplayProvider()
        let resolver = DisplayResolver(activeDisplayProvider: provider.read)
        if initiallyResolved {
            resolver.refresh()
        }
        if let displaysBeforeFirstMatch {
            provider.displays = displaysBeforeFirstMatch
        }
        let clock = TestGestureScheduler(executeCancelledActions: true)
        let recorder = RoutingRecorder()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration,
            displayResolver: resolver,
            inputSink: recorder,
            cursorController: recorder,
            focusRestorer: recorder,
            scheduler: clock,
            gestureQueue: gestureQueue
        )
        application.handleDeviceMatched()
        recorder.calls.removeAll()
        provider.readCount = 0
        self.application = application
        self.resolver = resolver
        self.provider = provider
        self.clock = clock
        self.recorder = recorder
    }

    func send(_ kind: TouchEvent.Kind, at milliseconds: UInt64? = nil, far: Bool = false) {
        if let milliseconds {
            clock.advance(toMilliseconds: milliseconds)
        }
        application.handleTouchEvent(TouchEvent(
            kind: kind,
            contactID: 0,
            rawX: far ? XeneonEdgeDevice.rawXRange.upperBound : XeneonEdgeDevice.rawXRange.lowerBound,
            rawY: far ? XeneonEdgeDevice.rawYRange.upperBound : XeneonEdgeDevice.rawYRange.lowerBound,
            timestamp: clock.now
        ))
    }
}

private enum RoutingCall: Equatable {
    case down(CGPoint)
    case up(CGPoint)
    case drag(CGPoint)
    case capture
    case restore
    case discard
    case borrow(CGPoint)
    case update(CGPoint)
    case returned
    case forceShow
}

private final class RoutingRecorder: SyntheticInputSink, CursorController, FocusRestorer {
    var calls: [RoutingCall] = []

    var input: [RoutingCall] {
        calls.filter {
            switch $0 {
            case .down, .up, .drag: return true
            default: return false
            }
        }
    }

    var gestureCalls: [RoutingCall] {
        calls.filter { $0 != .forceShow && $0 != .discard }
    }

    var returnCount: Int { calls.filter { $0 == .returned }.count }
    var restoreCount: Int { calls.filter { $0 == .restore }.count }

    func postMouseDown(at point: CGPoint) { calls.append(.down(point)) }
    func postMouseUp(at point: CGPoint) { calls.append(.up(point)) }
    func postMouseDragged(to point: CGPoint) { calls.append(.drag(point)) }
    func captureFocusedWindow() { calls.append(.capture) }
    func restoreCapturedWindow() { calls.append(.restore) }
    func discardCapturedWindow() { calls.append(.discard) }
    func borrow(warpingTo point: CGPoint) -> Bool {
        calls.append(.borrow(point))
        return true
    }
    func updatePosition(_ point: CGPoint) { calls.append(.update(point)) }
    func returnToOrigin() { calls.append(.returned) }
    func forceShow() { calls.append(.forceShow) }
}
