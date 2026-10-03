import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DisplayRoutingTests: XCTestCase {
    func testFarCornerTapBorrowsAndClicksInsideTheSelectedDisplay() {
        let fixture = RoutingFixture(displaysBeforeFirstMatch: [display(bounds: leftDisplayBounds)])

        fixture.send(.down, far: true)
        fixture.send(.up, at: 1, far: true)

        XCTAssertEqual(fixture.recorder.calls, [
            .capture, .borrow(leftDisplayFarPoint), .down(leftDisplayFarPoint),
            .up(leftDisplayFarPoint), .returned, .restore,
        ])
        assertFarCornerCallsAreContained(fixture.recorder)
    }

    func testFarCornerDragUsesTheBorrowedPointAndReturnsAfterMouseUp() {
        let fixture = RoutingFixture(
            returnDelay: 80,
            displaysBeforeFirstMatch: [display(bounds: leftDisplayBounds)]
        )

        fixture.send(.down, far: true)
        fixture.send(.move, at: 1, far: true)
        fixture.send(.up, at: 2, far: true)

        let beforeReturn: [RoutingCall] = [
            .capture, .borrow(leftDisplayFarPoint), .down(leftDisplayFarPoint),
            .update(leftDisplayFarPoint), .drag(leftDisplayFarPoint), .up(leftDisplayFarPoint),
        ]
        XCTAssertEqual(fixture.recorder.calls, beforeReturn)
        fixture.clock.advance(toMilliseconds: 81)
        XCTAssertEqual(fixture.recorder.calls, beforeReturn)
        fixture.clock.advance(toMilliseconds: 82)
        XCTAssertEqual(fixture.recorder.calls, beforeReturn + [.returned, .restore])
        assertFarCornerCallsAreContained(fixture.recorder)
    }

    func testFarCornerDeviceRemovalReleasesTheContainedPointOnceBeforeReturning() {
        for phase in [RoutingPhase.heldDrag, .delayedUp] {
            let fixture = RoutingFixture(
                upDelay: 40,
                returnDelay: 80,
                displaysBeforeFirstMatch: [display(bounds: leftDisplayBounds)]
            )
            fixture.send(.down, far: true)
            if phase == .heldDrag {
                fixture.send(.move, at: 1, far: true)
            } else {
                fixture.send(.up, at: 1, far: true)
            }

            fixture.application.handleDeviceRemoval()

            let dragCalls: [RoutingCall] = phase == .heldDrag
                ? [.update(leftDisplayFarPoint), .drag(leftDisplayFarPoint)] : []
            let expected: [RoutingCall] = [
                .capture, .borrow(leftDisplayFarPoint), .down(leftDisplayFarPoint),
            ] + dragCalls + [.discard, .up(leftDisplayFarPoint), .returned, .restore]
            XCTAssertEqual(fixture.recorder.calls, expected, "Phase: \(phase)")
            // Cancelled mouse-up, cursor-return, and watchdog work must not repeat cleanup.
            fixture.clock.advance(toMilliseconds: 2_000)
            fixture.send(.up, far: true)
            XCTAssertEqual(fixture.recorder.calls, expected, "Phase: \(phase)")
            assertFarCornerCallsAreContained(fixture.recorder)
        }
    }

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

    func testAmbiguousTargetDropsNewInputWithoutReusingThePreviousMappingAndCanRecover() {
        let first = display()
        let second = display(id: 99, at: movedOrigin)
        let fixture = RoutingFixture()

        for candidates in [[first, second], [second, first]] {
            fixture.provider.displays = candidates
            fixture.send(.down)
            fixture.send(.move, far: true)
            fixture.send(.up, far: true)

            XCTAssertNil(fixture.resolver.currentSnapshot)
            XCTAssertNil(fixture.resolver.currentBounds)
            XCTAssertNil(fixture.resolver.currentMapper)
            XCTAssertTrue(fixture.recorder.input.isEmpty)
        }

        fixture.provider.displays = [second]
        fixture.send(.down, at: 1)
        fixture.send(.up, at: 2)

        XCTAssertEqual(fixture.resolver.currentSnapshot, second)
        XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
        XCTAssertEqual(fixture.provider.readCount, 3)
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
            let point = CGPoint(x: (movedOrigin.x + 2_560).nextDown, y: (movedOrigin.y + 720).nextDown)
            XCTAssertEqual(fixture.recorder.input.suffix(2), [.drag(point), .up(point)])
        }
    }

    func testBeginArrivalBlocksAnOlderQueuedDownBeforeBeginHandlerRuns() throws {
        let queue = DispatchQueue(label: "display-routing-queued-down-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        queue.sync { fixture.provider.displays = [display(at: movedOrigin)] }

        try withBlockedQueue(queue) {
            queue.async { fixture.send(.down) }
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        try waitForQueue(queue)

        queue.sync {
            XCTAssertEqual(fixture.provider.readCount, 0, "Queued down must not read transient geometry")
            XCTAssertTrue(fixture.recorder.input.isEmpty)
            XCTAssertFalse(fixture.recorder.calls.contains(.borrow(movedOrigin)))
            XCTAssertNil(fixture.resolver.currentMapper)
        }

        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.up)
            fixture.send(.down, at: 1)
            fixture.send(.up, at: 2)
        }
        try waitForQueue(queue)

        queue.sync {
            XCTAssertEqual(fixture.provider.readCount, 2)
            XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
        }
    }

    func testBeginArrivalBlocksPendingMouseDownAheadOfBeginHandler() throws {
        let queue = DispatchQueue(label: "display-routing-pending-down-test")
        let fixture = RoutingFixture(warpDelay: 40, gestureQueue: queue)
        queue.async { fixture.send(.down) }
        try waitForQueue(queue)
        queue.sync { fixture.provider.displays = [display(at: movedOrigin)] }

        try withBlockedQueue(queue) {
            queue.async { fixture.clock.advance(toMilliseconds: 40) }
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        try waitForQueue(queue)

        queue.sync {
            XCTAssertTrue(fixture.recorder.input.isEmpty, "Due mouse-down must observe the begin arrival immediately")
            XCTAssertEqual(fixture.recorder.returnCount, 1)
            assertFocusDiscardedBeforeCursorReturn(fixture.recorder)
        }

        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.down, at: 41)
            // Deliver the cancelled old watchdog while the recovered contact remains held.
            fixture.clock.advance(toMilliseconds: 1_000)
        }
        try waitForQueue(queue)
        queue.sync {
            XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin)])
            XCTAssertEqual(fixture.recorder.returnCount, 1)
            XCTAssertEqual(fixture.recorder.restoreCount, 0)
        }

        queue.async {
            fixture.send(.up, at: 1_001)
            fixture.clock.advance(toMilliseconds: 2_000)
        }
        try waitForQueue(queue)
        queue.sync {
            XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
            XCTAssertEqual(fixture.recorder.returnCount, 2)
            XCTAssertEqual(fixture.recorder.restoreCount, 1)
        }
    }

    func testOlderQueuedEndCannotResolveDuringANewerBegin() throws {
        let queue = DispatchQueue(label: "display-routing-stale-end-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        queue.async {
            fixture.send(.down)
            fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        try waitForQueue(queue)
        let readsBeforeQueuedEnd = queue.sync { () -> Int in
            fixture.provider.displays = [display(at: CGPoint(x: 900, y: -800))]
            return fixture.provider.readCount
        }

        try withBlockedQueue(queue) {
            fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
            queue.async { fixture.send(.down) }
            fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
        }
        try waitForQueue(queue)

        queue.sync {
            XCTAssertEqual(fixture.provider.readCount, readsBeforeQueuedEnd)
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
            XCTAssertNil(fixture.resolver.currentMapper)
            assertFocusDiscardedBeforeCursorReturn(fixture.recorder)
            fixture.provider.displays = [display(at: movedOrigin)]
        }

        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.up)
            fixture.send(.down, at: 1)
            fixture.clock.advance(toMilliseconds: 1_000)
        }
        try waitForQueue(queue)

        queue.sync {
            XCTAssertEqual(fixture.provider.readCount, readsBeforeQueuedEnd + 2)
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin)])
            XCTAssertEqual(fixture.recorder.returnCount, 1)
            XCTAssertEqual(fixture.recorder.restoreCount, 0)
        }
        queue.async { fixture.send(.up) }
        try waitForQueue(queue)
        queue.sync {
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin), .up(movedOrigin)])
            XCTAssertEqual(fixture.recorder.returnCount, 2)
            XCTAssertEqual(fixture.recorder.restoreCount, 1)
        }
    }

    func testBeginArrivalDuringResolutionPreventsCommittingThatSnapshot() throws {
        let queue = DispatchQueue(label: "display-routing-resolve-race-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        queue.sync {
            fixture.provider.displays = [display(at: CGPoint(x: 900, y: -800))]
            fixture.provider.onRead = {
                fixture.provider.onRead = nil
                fixture.application.enqueueDisplayReconfiguration(flags: .beginConfigurationFlag)
            }
        }

        queue.async { fixture.send(.down) }
        // The provider enqueues a begin while the down is running; drain that nested work too.
        try waitForQueue(queue)
        try waitForQueue(queue)

        queue.sync {
            XCTAssertEqual(fixture.provider.readCount, 1)
            XCTAssertNil(fixture.resolver.currentSnapshot)
            XCTAssertTrue(fixture.recorder.input.isEmpty)
            fixture.provider.displays = [display(at: movedOrigin)]
        }

        fixture.application.enqueueDisplayReconfiguration(flags: .movedFlag)
        queue.async {
            fixture.send(.up)
            fixture.send(.down, at: 1)
            fixture.send(.up, at: 2)
        }
        try waitForQueue(queue)

        queue.sync {
            XCTAssertEqual(fixture.provider.readCount, 3)
            XCTAssertEqual(fixture.resolver.currentBounds?.origin, movedOrigin)
            XCTAssertEqual(fixture.recorder.input, [.down(movedOrigin), .up(movedOrigin)])
        }
    }

    func testQueueDrainTimeoutStopsTheDependentPhase() throws {
        let queue = DispatchQueue(label: "display-routing-drain-timeout-test")
        let fixture = RoutingFixture(gestureQueue: queue)
        var reachedDependentPhase = false

        try withBlockedQueue(queue) {
            queue.async { fixture.send(.down) }
            do {
                try waitForQueue(queue, timeout: 0.01)
                // This phase would read or mutate the fixture in the routing tests.
                // Use only a local marker here so a regressed helper cannot race it.
                reachedDependentPhase = true
            } catch {
                XCTAssertEqual(error as? QueueWaitFailure, .drainDidNotComplete)
            }
            XCTAssertFalse(reachedDependentPhase, "A failed drain must stop dependent fixture access")
        }

        // The barrier must be released even after the deliberately failed wait.
        try waitForQueue(queue)
        queue.sync {
            XCTAssertEqual(fixture.recorder.input, [.down(origin)])
            fixture.send(.up)
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin)])
        }
    }

    func testBlockedQueueTimeoutSkipsEnqueueAndReleasesItsBarrier() throws {
        let queue = DispatchQueue(label: "display-routing-barrier-timeout-test")
        var didEnqueue = false

        try withBlockedQueue(queue) {
            XCTAssertThrowsError(try withBlockedQueue(queue, timeout: 0.01) {
                didEnqueue = true
            }) { error in
                XCTAssertEqual(error as? QueueWaitFailure, .barrierDidNotStart)
            }
            XCTAssertFalse(didEnqueue, "A failed barrier must not execute its dependent phase")
        }

        // The inner barrier was enqueued before it timed out. Its release must
        // already be signalled when the outer barrier lets it reach the queue.
        try waitForQueue(queue)
    }

    private enum QueueWaitFailure: Error, Equatable {
        case barrierDidNotStart
        case drainDidNotComplete
    }

    private func withBlockedQueue(
        _ queue: DispatchQueue,
        timeout: TimeInterval = 2,
        enqueue: () throws -> Void
    ) throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // The body can enqueue work but must not synchronously wait for this queue.
        // Always release, including when the queued barrier starts only after
        // the entry wait times out or the dependent phase throws.
        defer { release.signal() }
        queue.async {
            entered.signal()
            release.wait()
        }
        guard entered.wait(timeout: .now() + timeout) == .success else {
            throw QueueWaitFailure.barrierDidNotStart
        }
        try enqueue()
    }

    private func waitForQueue(_ queue: DispatchQueue, timeout: TimeInterval = 2) throws {
        let drained = XCTestExpectation(description: "Gesture queue drained")
        queue.async { drained.fulfill() }
        // XCTestCase.wait records a failure and normally keeps executing. A
        // checked result must instead stop the caller's dependent phase.
        guard XCTWaiter.wait(for: [drained], timeout: timeout) == .completed else {
            throw QueueWaitFailure.drainDidNotComplete
        }
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
        assertFocusDiscardedBeforeCursorReturn(fixture.recorder)
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
        XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin), .up(movedOrigin)])
        XCTAssertEqual(fixture.recorder.restoreCount, 1)
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
            assertFocusDiscardedBeforeCursorReturn(fixture.recorder)

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
            XCTAssertEqual(fixture.recorder.input, [.down(origin), .up(origin), .down(movedOrigin), .up(movedOrigin)])
            XCTAssertEqual(fixture.recorder.restoreCount, 1)
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

    func testAmbiguityCancelsEveryOwnedPhaseBeforeUniqueRecoveryInEitherOrder() {
        let first = display()
        let second = display(id: 99, at: movedOrigin)
        for candidates in [[first, second], [second, first]] {
            for phase in RoutingPhase.allCases {
                assertRecovery(from: phase, throughLoss: true, unavailableDisplays: candidates)
            }
        }
    }

    private func assertFarCornerCallsAreContained(
        _ recorder: RoutingRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let adjacentPrimary = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let adjacentBelow = CGRect(x: -2_560, y: 720, width: 2_560, height: 720)
        let points = recorder.calls.compactMap { call -> CGPoint? in
            switch call {
            case .borrow(let point), .update(let point), .down(let point), .drag(let point), .up(let point):
                return point
            default:
                return nil
            }
        }
        XCTAssertFalse(points.isEmpty, file: file, line: line)
        for point in points {
            XCTAssertEqual(point, leftDisplayFarPoint, file: file, line: line)
            XCTAssertTrue(leftDisplayBounds.contains(point), "Point: \(point)", file: file, line: line)
            XCTAssertFalse(adjacentPrimary.contains(point), "Point: \(point)", file: file, line: line)
            XCTAssertFalse(adjacentBelow.contains(point), "Point: \(point)", file: file, line: line)
        }
    }

    private func assertFocusDiscardedBeforeCursorReturn(
        _ recorder: RoutingRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(recorder.restoreCount, 0, "Invalid geometry must not restore focus", file: file, line: line)
        guard let discard = recorder.calls.firstIndex(of: .discard),
              let returned = recorder.calls.firstIndex(of: .returned) else {
            XCTFail("Expected focus invalidation and cursor cleanup", file: file, line: line)
            return
        }
        XCTAssertLessThan(discard, returned, "Discard captured focus before required cursor cleanup", file: file, line: line)
    }

    private func assertRecovery(
        from phase: RoutingPhase,
        throughLoss: Bool,
        unavailableDisplays: [DisplaySnapshot] = [],
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
        fixture.provider.displays = throughLoss ? unavailableDisplays : [replacement]

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
            fixture.application.handleDisplayReconfiguration(flags: .movedFlag)
            fixture.send(.down)
            fixture.send(.move, far: true)
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
private let farPoint = CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)
private let movedOrigin = CGPoint(x: -2_560, y: 500)
private let leftDisplayBounds = CGRect(x: -2_560, y: 0, width: 2_560, height: 720)
private let leftDisplayFarPoint = CGPoint(x: leftDisplayBounds.maxX.nextDown, y: leftDisplayBounds.maxY.nextDown)

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
